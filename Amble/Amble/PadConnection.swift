import Foundation
@preconcurrency import CoreBluetooth
import ActivityKit
import HealthKit
import Observation
import UIKit
import os
import AmbleCore

/// Scans for the pad, connects, publishes decoded FTMS data, sends commands and records walks.
@MainActor @Observable
final class PadConnection: NSObject {
    enum State: Equatable {
        case bluetoothUnavailable(String)
        case idle            // no pad selected yet
        case connecting
        case connected
        case disconnected    // lost; reconnects automatically while the pad is in range
    }

    /// A nearby Bluetooth device shown in the picker.
    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var advertisesFTMS: Bool
        /// Pads often do not advertise FTMS, so fall back to common name hints.
        var looksLikePad: Bool {
            advertisesFTMS || (!name.lowercased().contains("ipad")   // "pad" would otherwise match every iPad
                && ["walk", "pad", "tread", "run", "fit"].contains { name.lowercased().contains($0) })
        }
    }

    struct SavedDevice: Equatable { let id: UUID; var name: String }

    private(set) var state: State = .idle
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var isScanning = false
    /// The picker is open and wants a scan, also if Bluetooth is not ready yet.
    private var wantsScan = false
    private(set) var savedDevice: SavedDevice?
    private(set) var connectionError: String?
    private(set) var deviceName: String?
    private(set) var data = TreadmillData()
    private(set) var trainingStatus: TrainingStatus?
    private(set) var machineStatus: MachineStatus?
    private(set) var speedRange: SpeedRange?
    /// What the pad says it supports (FTMS Feature characteristic), read after connecting.
    private(set) var features: FTMSFeatures?
    /// Learned at runtime: the pad answered "not supported" to the pause command.
    private(set) var pauseSupported = true
    /// Learned at runtime: the pad accepted a pause on this connection.
    private(set) var pauseConfirmed = false
    /// Demo mode: a simulated pad. Nothing is sent over Bluetooth and walks are not saved to Health.
    private(set) var isDemo = false
    /// The user disconnected on purpose, to free the pad for another phone or app. No automatic reconnect
    /// (also none in the background) until they tap Connect or the app is launched again.
    private(set) var isReleased = false

    // Battery: the pad streams about two data packets per second whenever it is connected, even when idle, and each
    // one wakes the app in the background. So live data is only requested while it is needed; the status
    // notifications (a few per walk) stay on, and they tell us when a walk starts.
    private var dataCharacteristic: CBCharacteristic?
    private var dataSubscribed = false
    private var isForeground = UIApplication.shared.applicationState != .background
    private var wantsLiveData: Bool { isForeground || isBeltActive || isStopping || active != nil }

    private func updateDataSubscription() {
        guard !isDemo, state == .connected, let p = peripheral, let c = dataCharacteristic else { return }
        let want = wantsLiveData
        guard want != dataSubscribed else { return }
        dataSubscribed = want
        log.notice("live data \(want ? "on" : "off")")
        p.setNotifyValue(want, for: c)
    }

    private func appEnteredBackground() {
        isForeground = false
        updateDataSubscription()
    }
    private var demo: DemoPad?

    /// Pad counters at the first packet of this connection; session values are measured from here.
    private var baselineDistance: Int?
    private var baselineSeconds: Int?

    let stride = StrideSettings()
    /// Steps are estimated from distance and belt speed; the user's step length at normal pace anchors the model.
    var stepModel: StepModel { StepModel(referenceStepLength: stride.strideMeters) }
    /// Steps since the session baseline (connection or start of the walk).
    private(set) var stepCounter = StepCounter()

    var sessionDistanceMeters: Int {
        guard let d = data.totalDistanceMeters, let b = baselineDistance else { return 0 }
        return max(0, d - b)
    }
    var sessionSeconds: Int {
        guard let t = data.elapsedSeconds, let b = baselineSeconds else { return 0 }
        return max(0, t - b)
    }
    var sessionSteps: Int { Int(stepCounter.steps.rounded()) }

    private let log = Logger(subsystem: "org.biskup.amble", category: "ble")
    private static let savedIDKey = "padPeripheralID"
    private static let savedNameKey = "padPeripheralName"
    private static let uuidData = CBUUID(string: FTMSUUID.treadmillData)
    private static let uuidTraining = CBUUID(string: FTMSUUID.trainingStatus)
    private static let uuidMachine = CBUUID(string: FTMSUUID.machineStatus)
    private static let uuidRange = CBUUID(string: FTMSUUID.supportedSpeedRange)
    private static let uuidFeature = CBUUID(string: FTMSUUID.feature)
    private static let uuidService = CBUUID(string: FTMSUUID.service)
    private static let uuidControl = CBUUID(string: FTMSUUID.controlPoint)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var userDisconnected = false

    // Health: one belt session = from the pad reporting "running" until it stops or the link drops.
    private struct ActiveSession: Codable {
        var start: Date
        var startDistance: Int?
        var startKcal: Int?
        var startSeconds: Int?
        // Last values seen, so a walk can still be saved if the app is killed before the belt stops.
        var lastSeen: Date?
        var lastDistance: Int?
        var lastKcal: Int?
        /// Optional so walks saved by older versions still decode.
        var stepCounter: StepCounter?
        // Pause: set while the belt is paused; closed pauses are kept for Health.
        var pausedAt: Date?
        var pauses: [WalkPause]?
    }

    /// The walk is paused: the belt has stopped but the walk is not over and not yet saved.
    var isPaused: Bool { active?.pausedAt != nil }
    private var active: ActiveSession?
    private var lastActivePersist = Date.distantPast
    private static let activeKey = "activeSession"

    private static func loadActive() -> ActiveSession? {
        guard let data = UserDefaults.standard.data(forKey: activeKey) else { return nil }
        return try? JSONDecoder().decode(ActiveSession.self, from: data)
    }

    /// A saved walk counts as the one still running only if it was seen recently; an older one is a different walk.
    private static let sameWalkGap: TimeInterval = 30 * 60

    private static func restorableSession() -> ActiveSession? {
        guard let saved = loadActive(), Date().timeIntervalSince(saved.lastSeen ?? saved.start) < sameWalkGap else { return nil }
        return saved
    }

    private func persistActive() {
        lastActivePersist = Date()
        if let active, !isDemo { UserDefaults.standard.set(try? JSONEncoder().encode(active), forKey: Self.activeKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.activeKey) }
    }
    private let health = HealthWriter()
    /// Something the user needs to know about Health. Successful saves are silent.
    struct HealthAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    private(set) var healthAlert: HealthAlert?
    /// Counts walks written to Health, so other screens know when to reload.
    private(set) var savedWalkCount = 0
    private var alertedAboutHealthAccess = false

    func dismissHealthAlert() { healthAlert = nil }
    private static let minimumWalkSeconds: TimeInterval = 30

    private func trainingStatusChanged(_ status: TrainingStatus?) {
        switch status {
        case .manualMode:
            if active == nil {
                if let saved = Self.restorableSession() {
                    // The app was restarted during this walk: carry on with the saved start and counters.
                    log.notice("restored walk from \(saved.start)")
                    adopt(saved)
                } else {
                    // A new walk: close an older one the app never got to finish, so the two are not merged.
                    finishSession()
                    // Measure the displayed values from here, not from when the app connected.
                    active = ActiveSession(start: Date(), startDistance: data.totalDistanceMeters,
                                           startKcal: data.energyTotalKcal, startSeconds: data.elapsedSeconds)
                    baselineDistance = data.totalDistanceMeters
                    baselineSeconds = data.elapsedSeconds
                    stepCounter = StepCounter(startingAtDistance: data.totalDistanceMeters, speedKmh: data.speedKmh)
                    active?.stepCounter = stepCounter
                }
                persistActive()
                startLiveActivity()
            } else {
                closePause()   // not every pad reports "started" when it resumes, but the belt is running again
            }
        case .postWorkout:
            finishSession()   // belt ramping down after Stop
        case .idle:
            // A pause also reports idle, but its Machine Status (paused) arrives at the same moment.
            // Wait a little so a pause is not mistaken for the end of the walk.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                if trainingStatus == .idle, !isPaused { finishSession() }
                updateDataSubscription()
            }
        default: break
        }
        updateDataSubscription()
    }

    /// Carries on with a walk saved before the app was restarted, including the steps counted so far.
    private func adopt(_ saved: ActiveSession) {
        active = saved
        baselineDistance = saved.startDistance
        baselineSeconds = saved.startSeconds
        stepCounter = saved.stepCounter ?? StepCounter(startingAtDistance: saved.lastDistance ?? saved.startDistance, speedKmh: nil)
    }

    private func closePause() {
        guard var a = active, let pausedAt = a.pausedAt else { return }
        a.pauses = (a.pauses ?? []) + [WalkPause(start: pausedAt, end: Date())]
        a.pausedAt = nil
        active = a
        persistActive()
        updateLiveActivity(force: true)
    }

    private func machineStatusChanged(_ status: MachineStatus?) {
        switch status {
        case .paused:
            if var a = active {
                guard a.pausedAt == nil else { return }
                a.pausedAt = Date()
                active = a
                persistActive()
                updateLiveActivity(force: true)
            } else if let saved = Self.restorableSession(), saved.pausedAt != nil {
                // The app was restarted while the walk was paused: pick it up again.
                adopt(saved)
                startLiveActivity()
            }
        case .started:
            closePause()
        case .stopped, .safetyKeyStop:
            if active != nil { finishSession() }   // e.g. stopped at the pad while paused
        default: break
        }
        updateDataSubscription()
    }

    // MARK: Live Activity (lock screen / Dynamic Island)

    private var liveActivity: Activity<WalkActivityAttributes>?
    private var lastActivityUpdate = Date.distantPast
    private var lastPublishedSpeed = -1.0
    private var lastPublishedState: WalkActivityAttributes.ContentState?

    private func activityState() -> WalkActivityAttributes.ContentState {
        let now = data.totalDistanceMeters ?? 0
        var start = active?.startDistance ?? now
        if now < start { start = 0 }
        let distance = max(0, now - start)
        let kcalNow = data.energyTotalKcal ?? 0
        var kcalStart = active?.startKcal ?? kcalNow
        if kcalNow < kcalStart { kcalStart = 0 }
        // The on-screen timer counts up from `timerStart` and freezes at `pausedAt`. The pad's own elapsed
        // time excludes paused periods, so deriving the start from it keeps the timer right across pauses.
        let reference = active?.pausedAt ?? Date()
        let timerStart = Date(timeIntervalSinceReferenceDate: floor(reference.timeIntervalSinceReferenceDate - Double(sessionSeconds)))
        return .init(speedKmh: data.speedKmh ?? 0, distanceMeters: distance,
                     steps: Int(stepCounter.steps.rounded()), energyKcal: max(0, kcalNow - kcalStart),
                     timerStart: timerStart, pausedAt: active?.pausedAt)
    }

    /// Whether two states look the same on screen (the timer runs by itself and is ignored).
    private func sameContent(_ a: WalkActivityAttributes.ContentState, _ b: WalkActivityAttributes.ContentState) -> Bool {
        a.speedKmh == b.speedKmh && a.distanceMeters == b.distanceMeters && a.steps == b.steps
            && a.energyKcal == b.energyKcal && a.pausedAt == b.pausedAt
    }

    /// iOS only allows starting a Live Activity while the app is in the foreground; updates and ending work in the background.
    func startLiveActivity() {
        guard let a = active, liveActivity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // After an app relaunch a previous activity may still be running: adopt it instead of starting a second one.
        if let existing = Activity<WalkActivityAttributes>.activities.first {
            liveActivity = existing
            nonisolated(unsafe) let extras = Array(Activity<WalkActivityAttributes>.activities.dropFirst())
            Task { @MainActor in
                for extra in extras {
                    nonisolated(unsafe) let handle = extra
                    await handle.end(nil, dismissalPolicy: .immediate)
                }
            }
            return
        }
        let attributes = WalkActivityAttributes(padName: deviceName ?? String(localized: "Walking pad"), startDate: a.start)
        do {
            let initial = activityState()
            liveActivity = try Activity.request(attributes: attributes, content: .init(state: initial, staleDate: nil))
            lastActivityUpdate = Date()
            lastPublishedSpeed = initial.speedKmh
            lastPublishedState = initial
        } catch {
            log.notice("live activity not started: \(error.localizedDescription)")
        }
    }

    private func updateLiveActivity(force: Bool = false) {
        guard let activity = liveActivity else { return }
        let speed = data.speedKmh ?? 0
        // Every update re-renders the island and can make small views flicker, and iOS rate limits updates.
        // So: at once when the speed changes, otherwise at most every 10 s, and never with identical content.
        let speedChanged = abs(speed - lastPublishedSpeed) >= 0.05
        guard force || speedChanged || Date().timeIntervalSince(lastActivityUpdate) >= 10 else { return }
        let state = activityState()
        if !force, let last = lastPublishedState, sameContent(state, last) { return }
        lastActivityUpdate = Date()
        lastPublishedSpeed = speed
        lastPublishedState = state
        // Activity is only ever used from the main actor here, so handing it to a main-actor task is safe.
        nonisolated(unsafe) let handle = activity
        Task { @MainActor in await handle.update(.init(state: state, staleDate: nil)) }
    }

    /// Ends every Walk activity, not only the one this process started: after an app relaunch (update, crash)
    /// the old activity would otherwise stay on the lock screen with its timer still counting.
    private func endLiveActivity() {
        let state = activityState()
        let all = Activity<WalkActivityAttributes>.activities
        liveActivity = nil
        lastPublishedState = nil
        guard !all.isEmpty else { return }
        nonisolated(unsafe) let handles = all
        // .immediate: a finished activity must not linger, because its timer keeps running.
        Task { @MainActor in
            for activity in handles {
                nonisolated(unsafe) let handle = activity
                await handle.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }

    /// Called when the app comes to the foreground.
    private func appBecameActive() {
        isForeground = true
        updateDataSubscription()
        flushPendingWalks()
        startLiveActivity()
    }

    private func finishSession() {
        defer { updateDataSubscription() }
        endLiveActivity()
        // No walk in memory but one on disk: the app was killed mid-walk; close it with the last values it saw.
        let recovered = active == nil
        guard let a = active ?? Self.loadActive() else { return }
        active = nil
        persistActive()
        if isDemo { return }   // simulated walks stay out of Health and the awards
        // A walk finished while paused ended when the pause began; the waiting time is not part of it.
        // A recovered walk ends when it was last seen, but never before its last pause ended: Health rejects later events.
        let end = a.pausedAt ?? (recovered ? max(a.lastSeen ?? a.start, a.pauses?.last?.end ?? a.start) : Date())
        let endDistance = recovered ? (a.lastDistance ?? 0) : (data.totalDistanceMeters ?? a.lastDistance ?? 0)
        var startDistance = a.startDistance ?? endDistance
        if endDistance < startDistance { startDistance = 0 } // pad counter reset during the walk
        let endKcal = recovered ? (a.lastKcal ?? 0) : (data.energyTotalKcal ?? a.lastKcal ?? 0)
        var startKcal = a.startKcal ?? endKcal
        if endKcal < startKcal { startKcal = 0 }
        let distance = Double(endDistance - startDistance)
        var walk = WalkSession(start: a.start, end: end, distanceMeters: distance,
                               energyKcal: Double(endKcal - startKcal), steps: 0,
                               pauses: (a.pauses ?? []).isEmpty ? nil : a.pauses)
        // Steps were counted along the way. Without a count (very old saved walk), use the average speed.
        if let counted = a.stepCounter?.steps {
            walk.steps = Int(counted.rounded())
        } else if walk.activeSeconds > 0 {
            walk.steps = Int(stepModel.steps(forDistance: distance, atSpeedKmh: distance / walk.activeSeconds * 3.6).rounded())
        }
        guard walk.activeSeconds >= Self.minimumWalkSeconds else {
            healthAlert = HealthAlert(title: String(localized: "Walk too short"),
                                      message: String(localized: "That walk lasted less than \(Int(Self.minimumWalkSeconds)) seconds, so it was not saved to Health."))
            return
        }
        // Queue first, then try to write: Health refuses writes while the phone is locked, so a walk that
        // ends in the background stays queued (also across app restarts) and is saved when the phone unlocks.
        pendingWalks.append(walk)
        Self.persist(pendingWalks)
        flushPendingWalks()
    }

    // MARK: Pending walks (Health writes can fail while the phone is locked)

    private static let pendingKey = "pendingWalks"
    private static let maximumSaveAttempts = 3
    private var pendingWalks: [WalkSession] = PadConnection.loadPending()
    private var isFlushing = false

    static func loadPending() -> [WalkSession] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([WalkSession].self, from: data)) ?? []
    }

    private static func persist(_ walks: [WalkSession]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(walks), forKey: pendingKey)
    }

    /// Only for problems the user can fix (no access, no Health on this device), and only once per run.
    private func alertAboutHealth(_ error: Error) {
        guard !alertedAboutHealthAccess else { return }
        alertedAboutHealthAccess = true
        healthAlert = HealthAlert(title: "Apple Health", message: error.localizedDescription)
    }

    /// Writes queued walks to Health, oldest first. Called after a walk, on unlock and when the app becomes active.
    func flushPendingWalks() {
        guard !isFlushing, !pendingWalks.isEmpty else { return }
        isFlushing = true
        Task { @MainActor in
            defer { isFlushing = false }
            var failedThisRound = Set<Date>()   // a walk Health refuses must not hold up the ones behind it
            while let walk = pendingWalks.first(where: { !failedThisRound.contains($0.start) }) {
                do {
                    try await health.save(walk)
                    pendingWalks.removeAll { $0.start == walk.start }
                    Self.persist(pendingWalks)
                    savedWalkCount += 1
                    Task { await GoalsStore.shared.refresh() }   // also updates the widget when no screen is open
                } catch {
                    log.notice("health save failed: \(error.localizedDescription)")
                    if error is HealthError { alertAboutHealth(error); return }
                    // The phone is locked, so Health is unreadable: nothing is wrong, retry on unlock.
                    if (error as? HKError)?.code == .errorDatabaseInaccessible || !UIApplication.shared.isProtectedDataAvailable { return }
                    failedThisRound.insert(walk.start)
                    recordFailedSave(of: walk)
                }
            }
        }
    }

    /// Health refused a walk while it was readable. Retry later, but after a few tries give up and say so.
    private func recordFailedSave(of walk: WalkSession) {
        guard let i = pendingWalks.firstIndex(where: { $0.start == walk.start }) else { return }
        let attempts = (pendingWalks[i].saveAttempts ?? 0) + 1
        if attempts >= Self.maximumSaveAttempts {
            pendingWalks.remove(at: i)
            let date = walk.start.formatted(date: .abbreviated, time: .shortened)
            healthAlert = HealthAlert(title: String(localized: "Walk not saved"),
                                      message: String(localized: "Apple Health did not accept your walk from \(date), even after several tries, so it was not saved."))
        } else {
            pendingWalks[i].saveAttempts = attempts
        }
        Self.persist(pendingWalks)
    }

    // Control: commands are sent one at a time; the next goes out when the pad's indication arrives.
    private(set) var lastError: String?
    private var controlPoint: CBCharacteristic?
    private var controlGranted = false
    private var queue: [FTMSCommand] = []
    private var inFlight: FTMSCommand?
    private var commandToken = 0
    private var lastSpeedCommand: (kmh: Double, at: Date)?

    var canControl: Bool { state == .connected && (controlPoint != nil || isDemo) }
    var isBeltActive: Bool {
        trainingStatus == .preWorkout || trainingStatus == .manualMode
            || (trainingStatus == nil && (data.speedKmh ?? 0) > 0.1)   // status not known yet, but the belt is moving
    }
    var isStopping: Bool { trainingStatus == .postWorkout }
    /// A real belt is in use. The link must not be dropped now: the belt would keep running without the app.
    var isWalkInProgress: Bool { !isDemo && state == .connected && (isBeltActive || isStopping || isPaused) }
    /// Only while the belt runs and the link is up; a lost connection must not keep the screen on forever.
    var keepScreenOn: Bool { isBeltActive && state == .connected }

    func start() {
        guard canControl else { return }
        lastError = nil
        enqueue(controlGranted ? [.start] : [.requestControl, .start], replacing: false)
    }

    /// Stop jumps the queue, survives failures of other commands, and only briefly waits for a command in flight.
    func stop() {
        guard canControl else { return }
        lastError = nil
        enqueue(controlGranted ? [.stop] : [.requestControl, .stop], replacing: true)
        expediteStop()
        // While paused the belt is already still and the pad may report nothing, so end the walk here.
        if isPaused { finishSession() }
    }

    /// The pad handles one command at a time, so Stop waits for the answer to the one in flight, but not for long.
    private func expediteStop() {
        guard inFlight != nil, inFlight != .stop else { return }
        let token = commandToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if commandToken == token, inFlight != nil {
                inFlight = nil
                pump()
            }
        }
    }

    /// Pauses the belt without ending the walk.
    func pause() {
        guard canControl, isBeltActive else { return }
        lastError = nil
        enqueue(controlGranted ? [.pause] : [.requestControl, .pause], replacing: true)
    }

    /// Continues a paused walk (the pad counts down for a few seconds first).
    func resume() {
        guard canControl, isPaused else { return }
        lastError = nil
        enqueue(controlGranted ? [.start] : [.requestControl, .start], replacing: false)
    }

    func setSpeed(_ kmh: Double) {
        guard canControl, !queue.contains(.stop), inFlight != .stop else { return }
        let v = (speedRange ?? .sportstechPad).normalized(kmh)
        lastSpeedCommand = (v, Date())
        lastError = nil
        // While a button is held, newer speed targets replace older queued ones instead of piling up.
        queue.removeAll { if case .setTargetSpeed = $0 { true } else { false } }
        enqueue(controlGranted ? [.setTargetSpeed(kmh: v)] : [.requestControl, .setTargetSpeed(kmh: v)], replacing: false)
    }

    func changeSpeed(by delta: Double) {
        // Base on a very recent command so quick repeated taps add up before the belt catches up.
        let base: Double
        if let last = lastSpeedCommand, Date().timeIntervalSince(last.at) < 2 { base = last.kmh }
        else { base = data.speedKmh ?? 0 }
        setSpeed((speedRange ?? .sportstechPad).stepped(from: base, by: delta))
    }

    private func enqueue(_ commands: [FTMSCommand], replacing: Bool) {
        if replacing { queue.removeAll() }
        queue.append(contentsOf: commands)
        pump()
    }

    private func pump() {
        guard inFlight == nil, !queue.isEmpty else { return }
        if isDemo, let demo {
            let cmd = queue.removeFirst()
            inFlight = cmd
            let result = demo.handle(cmd)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if let r = ControlPointResponse(data: Data([0x80, cmd.opcode, result.rawValue])) { self.handleControlResponse(r) }
            }
            return
        }
        guard let p = peripheral, let cp = controlPoint else { return }
        let cmd = queue.removeFirst()
        inFlight = cmd
        commandToken += 1
        let token = commandToken
        log.notice("send \(String(describing: cmd))")
        p.writeValue(cmd.encoded, for: cp, type: .withResponse)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if self.commandToken == token, self.inFlight != nil {
                self.lastError = String(localized: "The pad did not answer.")
                self.inFlight = nil
                self.pump()
            }
        }
    }

    private func handleControlResponse(_ r: ControlPointResponse) {
        guard let cmd = inFlight, cmd.opcode == r.requestOpcode else { return }
        inFlight = nil
        if r.result == .success {
            if cmd == .requestControl { controlGranted = true }
            if cmd == .pause { pauseConfirmed = true }
        } else {
            if cmd == .pause && r.result == .notSupported { pauseSupported = false }
            lastError = cmd == .pause && r.result == .notSupported
                ? String(localized: "This pad does not support pause.")
                : String(localized: "The pad rejected the command (code \(r.rawResult)).")
            if r.result == .controlNotPermitted { controlGranted = false }
            queue.removeAll { $0 != .stop }   // a failed command must never cancel a Stop waiting behind it
        }
        pump()
    }

    /// One connection for the whole app, so the whole app shares one pad link.
    static let shared = PadConnection()

    override init() {
        super.init()
        if let idString = UserDefaults.standard.string(forKey: Self.savedIDKey), let id = UUID(uuidString: idString) {
            savedDevice = SavedDevice(id: id, name: UserDefaults.standard.string(forKey: Self.savedNameKey) ?? String(localized: "Walking pad"))
        }
        // The restore identifier lets iOS relaunch the app in the background and hand the pad connection back.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "org.biskup.amble.central"])
        Task { @MainActor in
            do { try await health.requestAuthorization() }
            catch { alertAboutHealth(error) }
            await stride.refreshFromHealth()
            flushPendingWalks()
        }
        // Health data becomes writable again after the phone is unlocked.
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.protectedDataDidBecomeAvailableNotification) {
                self?.flushPendingWalks()
            }
        }
        // App-wide signals, so they do not depend on which screen happens to be showing.
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                self?.appBecameActive()
            }
        }
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.appEnteredBackground()
            }
        }
    }

    // MARK: Device selection

    /// Scans for nearby devices (the picker calls this while it is open).
    func startScan() {
        wantsScan = true
        guard central.state == .poweredOn else { return }   // starts when Bluetooth is ready
        discovered = []
        isScanning = true
        // Each device is reported once; repeated reports only make signal strength flicker the list.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        wantsScan = false
        isScanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    /// Connects to a device picked from the list. It is saved as the last pad once it proves to be a compatible pad.
    func connect(to device: DiscoveredDevice) {
        guard !isWalkInProgress, let p = knownPeripherals[device.id] else { return }
        leaveDemo(reconnect: false)
        stopScan()
        if let old = peripheral, old.identifier != p.identifier {
            userDisconnected = true
            central.cancelPeripheralConnection(old)
        }
        open(p, name: device.name)
    }

    /// Reconnects to the last pad (iOS keeps the connection pending until the pad is in range).
    private func connectSaved() {
        guard let saved = savedDevice else { state = .idle; return }
        guard let p = central.retrievePeripherals(withIdentifiers: [saved.id]).first else {
            state = .idle
            return
        }
        knownPeripherals[saved.id] = p
        open(p, name: saved.name)
    }

    private func open(_ p: CBPeripheral, name: String) {
        userDisconnected = false
        isReleased = false
        connectionError = nil
        deviceName = name
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p)
    }

    // MARK: Demo mode

    func startDemo() {
        guard !isDemo, !isWalkInProgress else { return }
        finishSession()   // a walk the app never got to close is saved first
        stopScan()
        userDisconnected = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        resetSession()
        isDemo = true
        connectionError = nil
        deviceName = String(localized: "Demo pad")
        // Distance, energy and elapsed time, and setting the speed: what the real pad offers.
        features = FTMSFeatures(machine: 0x1204, targetSettings: 0x1)
        speedRange = .sportstechPad
        pauseSupported = true
        let pad = DemoPad()
        pad.onData = { [weak self] in self?.ingest($0) }
        pad.onTraining = { [weak self] in self?.trainingStatus = $0; self?.trainingStatusChanged($0) }
        pad.onMachine = { [weak self] in self?.machineStatus = $0; self?.machineStatusChanged($0) }
        demo = pad
        state = .connected
        pad.begin()
    }

    /// Leaves demo mode. Unless the caller is about to connect somewhere else, the saved pad is reconnected.
    func leaveDemo(reconnect: Bool = true) {
        guard isDemo else { return }
        finishSession()
        demo?.end()
        demo = nil
        isDemo = false
        resetSession()
        deviceName = nil
        features = nil
        speedRange = nil
        userDisconnected = false
        state = .idle
        if reconnect { centralManagerDidUpdateState(central) }
    }

    /// Lets go of the pad so other phones and apps can connect (a pad accepts only one connection).
    /// The saved pad is kept; Amble stays disconnected until `reconnect()`.
    func disconnect() {
        guard !isDemo, !isWalkInProgress else { return }
        userDisconnected = true
        isReleased = true
        finishSession()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetSession()
        connectionError = nil
        state = .idle
    }

    /// Connects to the saved pad again after `disconnect()`.
    func reconnect() {
        guard isReleased else { return }
        isReleased = false
        connectSaved()
    }

    /// Disconnects and forgets the saved pad.
    func forgetDevice() {
        guard !isWalkInProgress else { return }
        userDisconnected = true
        isReleased = false
        finishSession()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        deviceName = nil
        savedDevice = nil
        UserDefaults.standard.removeObject(forKey: Self.savedIDKey)
        UserDefaults.standard.removeObject(forKey: Self.savedNameKey)
        resetSession()
        state = .idle
    }

    private func save(_ p: CBPeripheral, name: String) {
        savedDevice = SavedDevice(id: p.identifier, name: name)
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedIDKey)
        UserDefaults.standard.set(name, forKey: Self.savedNameKey)
    }

    /// The device connected but does not speak the standard treadmill profile.
    private func reject(_ p: CBPeripheral, _ message: String) {
        userDisconnected = true
        connectionError = message
        central.cancelPeripheralConnection(p)
        peripheral = nil
        deviceName = nil
        // A wrong device was picked: go back to waiting for the saved pad instead of waiting for nothing.
        if let saved = savedDevice, saved.id != p.identifier {
            connectSaved()
            connectionError = message   // connecting clears it
        } else {
            state = savedDevice == nil ? .idle : .disconnected
        }
    }

    private func upsert(_ d: DiscoveredDevice) {
        if let i = discovered.firstIndex(where: { $0.id == d.id }) {
            var merged = d
            merged.advertisesFTMS = d.advertisesFTMS || discovered[i].advertisesFTMS
            guard discovered[i].name != d.name || discovered[i].advertisesFTMS != merged.advertisesFTMS else { return }
            discovered[i] = merged
        } else {
            discovered.append(d)
        }
        // Stable order (likely pads first, then by name) so rows do not jump around while scanning.
        discovered.sort {
            if $0.looksLikePad != $1.looksLikePad { return $0.looksLikePad }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func resetSession() {
        stepCounter = StepCounter()
        baselineDistance = nil
        baselineSeconds = nil
        data = TreadmillData()
        trainingStatus = nil
        machineStatus = nil
        controlPoint = nil
        dataCharacteristic = nil
        dataSubscribed = false
        controlGranted = false
        queue.removeAll()
        inFlight = nil
        lastError = nil
        lastSpeedCommand = nil
    }

    private func ingest(_ packet: TreadmillData) {
        let d = packet.merged(over: data)
        if let dist = d.totalDistanceMeters {
            if let b = baselineDistance, dist < b {
                log.notice("distance counter went backwards: \(b) -> \(dist); re-basing")
                baselineDistance = 0
            } else if baselineDistance == nil { baselineDistance = dist }
        }
        if let t = d.elapsedSeconds {
            if let b = baselineSeconds, t < b {
                log.notice("time counter went backwards: \(b) -> \(t); re-basing")
                baselineSeconds = 0
            } else if baselineSeconds == nil { baselineSeconds = t }
        }
        data = d
        stepCounter.add(distanceMeters: d.totalDistanceMeters, speedKmh: d.speedKmh, model: stepModel)
        // A walk already in progress when we connected has no counter baseline until the first packet.
        if var a = active {
            if a.startDistance == nil { a.startDistance = d.totalDistanceMeters }
            if a.startKcal == nil { a.startKcal = d.energyTotalKcal }
            if a.startSeconds == nil { a.startSeconds = d.elapsedSeconds }
            a.lastSeen = Date()
            a.lastDistance = d.totalDistanceMeters
            a.lastKcal = d.energyTotalKcal
            a.stepCounter = stepCounter
            active = a
            if Date().timeIntervalSince(lastActivePersist) >= 10 { persistActive() }
        }
        updateLiveActivity()
        // Forgotten pause: close the walk after 30 minutes, ending where the pause began.
        if let pausedAt = active?.pausedAt, Date().timeIntervalSince(pausedAt) > 30 * 60 { finishSession() }
    }
}

extension PadConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn {
                if wantsScan { startScan() }
            } else {
                isScanning = false
            }
            if isDemo || isReleased { return }   // a deliberate disconnect must not be undone by a Bluetooth toggle
            switch central.state {
            case .poweredOn:
                if let p = peripheral {
                    // Restored by iOS after a relaunch, or Bluetooth came back on.
                    switch p.state {
                    case .connected:
                        resetSession()
                        state = .connecting
                        p.discoverServices([Self.uuidService])
                    case .disconnected:
                        state = .connecting
                        central.connect(p)
                    default: state = .connecting
                    }
                } else { connectSaved() }
            case .poweredOff: state = .bluetoothUnavailable(String(localized: "Bluetooth is off"))
            case .unauthorized: state = .bluetoothUnavailable(String(localized: "Bluetooth permission denied (Settings > Amble)"))
            case .unsupported: state = .bluetoothUnavailable(String(localized: "Bluetooth not supported"))
            default: state = .bluetoothUnavailable(String(localized: "Bluetooth not ready"))
            }
        }
    }

    /// Called when iOS relaunched the app in the background because of a Bluetooth event from the pad.
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // CoreBluetooth calls this on the main queue we passed in, so handing the peripherals to the main actor is safe.
        nonisolated(unsafe) let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        MainActor.assumeIsolated {
            guard let saved = savedDevice, let p = restored.first(where: { $0.identifier == saved.id }) else { return }
            knownPeripherals[p.identifier] = p
            peripheral = p
            deviceName = saved.name
            p.delegate = self
            userDisconnected = false
            state = .connecting
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let ftms = services.contains(CBUUID(string: FTMSUUID.service))
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            guard !name.isEmpty, rssi != 127 else { return } // ignore unnamed devices and invalid readings
            knownPeripherals[p.identifier] = p
            upsert(DiscoveredDevice(id: p.identifier, name: name, rssi: rssi, advertisesFTMS: ftms))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            log.notice("connected, checking services")
            resetSession()
            p.discoverServices([Self.uuidService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let reason = error?.localizedDescription ?? String(localized: "unknown error")
            connectionError = String(localized: "Could not connect: \(reason)")
            state = .disconnected
            // Try again shortly while the pad is still the selected one.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if !userDisconnected, peripheral?.identifier == p.identifier { central.connect(p) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            log.notice("disconnected: \(error?.localizedDescription ?? "no error")")
            if isDemo { return }   // the real link was dropped on purpose when the demo began
            finishSession()
            guard !userDisconnected, peripheral?.identifier == p.identifier else { return }
            // Connection lost: ask iOS to reconnect as soon as the pad is back in range.
            state = .connecting
            central.connect(p)
        }
    }
}

extension PadConnection: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = p.services?.first(where: { $0.uuid == Self.uuidService }) else {
                reject(p, String(localized: "This device does not offer the standard fitness machine service (FTMS), so Amble cannot control it."))
                return
            }
            p.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard s.characteristics?.contains(where: { $0.uuid == Self.uuidData }) == true else {
                reject(p, String(localized: "This device has no treadmill data, so Amble cannot use it."))
                return
            }
            // Verified: remember it as the last pad.
            save(p, name: deviceName ?? p.name ?? String(localized: "Walking pad"))
            state = .connected
            features = nil
            pauseSupported = true
            pauseConfirmed = false
            for c in s.characteristics ?? [] {
                switch c.uuid {
                case Self.uuidTraining:
                    p.setNotifyValue(true, for: c)
                    p.readValue(for: c) // the pad only notifies on changes, so ask for the current state once
                case Self.uuidData: dataCharacteristic = c   // subscribed by updateDataSubscription()
                case Self.uuidMachine: p.setNotifyValue(true, for: c)
                case Self.uuidRange, Self.uuidFeature: p.readValue(for: c)
                case Self.uuidControl:
                    controlPoint = c
                    p.setNotifyValue(true, for: c) // responses arrive as indications
                default: break
                }
            }
            updateDataSubscription()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            guard let message else { return }
            lastError = String(localized: "Command failed: \(message)")
            inFlight = nil
            queue.removeAll { $0 != .stop }   // a failed command must never cancel a Stop waiting behind it
            pump()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let value = c.value else { return }
        MainActor.assumeIsolated {
            switch c.uuid {
            case Self.uuidData: if let d = TreadmillData(data: value) { ingest(d) }
            case Self.uuidTraining:
                trainingStatus = TrainingStatus(data: value)
                trainingStatusChanged(trainingStatus)
            case Self.uuidMachine:
                machineStatus = MachineStatus(data: value)
                machineStatusChanged(machineStatus)
            case Self.uuidRange: speedRange = SpeedRange(data: value)
            case Self.uuidFeature: features = FTMSFeatures(data: value)
            case Self.uuidControl: if let r = ControlPointResponse(data: value) { handleControlResponse(r) }
            default: break
            }
        }
    }
}
