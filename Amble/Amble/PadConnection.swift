import Foundation
@preconcurrency import CoreBluetooth
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
    private(set) var isDemo = false { didSet { recorder.isDemo = isDemo } }
    /// Whether Amble has let go of the pad, on purpose by the user or automatically in share mode.
    /// No automatic reconnect in the background until the user taps Connect or the app is opened (auto only).
    enum ReleaseReason { case user, auto }
    /// Nil: Amble holds or seeks the pad. .user: disconnected on purpose, waits for Connect.
    /// .auto: let go for other phones (share mode); reconnects when the app is opened.
    private(set) var releaseReason: ReleaseReason?
    var isReleased: Bool { releaseReason != nil }

    // Battery: the pad streams about two data packets per second whenever it is connected, even when idle, and each
    // one wakes the app in the background. So live data is only requested while it is needed; the status
    // notifications (a few per walk) stay on, and they tell us when a walk starts.
    private var dataCharacteristic: CBCharacteristic?
    private var dataSubscribed = false
    private var isForeground = UIApplication.shared.applicationState != .background
    // Share mode keeps data on while connected, so the idle check in ingest() can run in the background.
    private var wantsLiveData: Bool { isForeground || isBeltActive || isStopping || recorder.hasWalk || disconnectsWhenIdle }

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
        // The connection was lost in the foreground and a reconnect is pending: do not let it grab the pad later.
        if disconnectsWhenIdle, state != .connected, peripheral != nil, releaseReason == nil {
            releaseForOthers("pending reconnect on entering background")
        }
        updateDataSubscription()
    }
    private var demo: DemoPad?

    let stride = StrideSettings()
    /// Steps are estimated from distance and belt speed; the user's step length at normal pace anchors the model.
    var stepModel: StepModel { StepModel(referenceStepLength: stride.strideMeters) }

    // Session values, measured from the connection or the start of the walk.
    var sessionDistanceMeters: Int { recorder.distanceMeters(in: data) }
    var sessionSeconds: Int { recorder.seconds(in: data) }
    var sessionSteps: Int { recorder.steps }
    var sessionEnergyKcal: Int { recorder.energyKcal(in: data) }

    private let log = Logger(subsystem: "org.biskup.amble", category: "ble")
    private static let savedIDKey = "padPeripheralID"
    private static let savedNameKey = "padPeripheralName"
    private static let disconnectWhenIdleKey = "disconnectWhenIdle"
    /// For pads used by more than one phone: Amble lets go of an idle pad while in the background, so another phone can connect.
    var disconnectsWhenIdle = UserDefaults.standard.bool(forKey: PadConnection.disconnectWhenIdleKey) {
        didSet {
            UserDefaults.standard.set(disconnectsWhenIdle, forKey: Self.disconnectWhenIdleKey)
            updateDataSubscription()
        }
    }
    private static let idleReleaseDelay: TimeInterval = 10 * 60
    /// Last moment the pad was in use (belt moving or a walk open). Nil while not connected.
    private var idleSince: Date?
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

    // Walks: one belt session = from the pad reporting "running" until it stops or the link drops.
    // The recorder keeps the walk, the queue writes it to Health, the activity shows it on the lock screen.
    private let recorder = WalkRecorder()
    let healthQueue = HealthQueue()
    private let activity = WalkActivityController()

    /// The walk is paused: the belt has stopped but the walk is not over and not yet saved.
    var isPaused: Bool { recorder.isPaused }

    private func trainingStatusChanged(_ status: TrainingStatus?) {
        switch status {
        case .manualMode:
            if !recorder.hasWalk {
                // The app was restarted during this walk: carry on with the saved start and counters.
                if !recorder.restore() {
                    // A new walk: close an older one the app never got to finish, so the two are not merged.
                    finishSession()
                    // Measure the displayed values from here, not from when the app connected.
                    recorder.begin(with: data)
                }
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

    private func closePause() {
        if recorder.resume() { updateLiveActivity(force: true) }
    }

    private func machineStatusChanged(_ status: MachineStatus?) {
        switch status {
        case .paused:
            if recorder.hasWalk {
                if recorder.pause() { updateLiveActivity(force: true) }
            } else if recorder.restore(onlyIfPaused: true) {
                // The app was restarted while the walk was paused: pick it up again.
                startLiveActivity()
            }
        case .started:
            closePause()
        case .stopped, .safetyKeyStop:
            if recorder.hasWalk { finishSession() }   // e.g. stopped at the pad while paused
        default: break
        }
        updateDataSubscription()
    }

    // MARK: Live Activity (lock screen / Dynamic Island)

    private func activityState() -> WalkActivityAttributes.ContentState {
        // The on-screen timer counts up from `timerStart` and freezes at `pausedAt`. The pad's own elapsed
        // time excludes paused periods, so deriving the start from it keeps the timer right across pauses.
        let reference = recorder.pausedAt ?? Date()
        let timerStart = Date(timeIntervalSinceReferenceDate: floor(reference.timeIntervalSinceReferenceDate - Double(sessionSeconds)))
        return .init(speedKmh: data.speedKmh ?? 0, distanceMeters: sessionDistanceMeters, steps: sessionSteps,
                     energyKcal: sessionEnergyKcal, timerStart: timerStart, pausedAt: recorder.pausedAt)
    }

    private func startLiveActivity() {
        guard let start = recorder.walkStart else { return }
        activity.start(padName: deviceName ?? String(localized: "Walking pad"), startDate: start,
                       state: activityState())
    }

    private func updateLiveActivity(force: Bool = false) {
        activity.update(activityState(), force: force)
    }

    /// Called when the app comes to the foreground.
    private func appBecameActive() {
        isForeground = true
        if releaseReason == .auto { reconnect() }
        updateDataSubscription()
        healthQueue.flush()
        startLiveActivity()
    }

    /// Ends the open walk, if any, and hands it to Health.
    private func finishSession() {
        defer { updateDataSubscription() }
        activity.end(activityState())
        switch recorder.finish(data: data, model: stepModel) {
        case .walk(let walk):
            healthQueue.enqueue(walk)
        case .tooShort:
            healthQueue.show(HealthAlert(title: String(localized: "Walk too short"),
                                         message: String(localized: "That walk lasted less than \(Int(WalkRecorder.minimumWalkSeconds)) seconds, so it was not saved to Health.")))
        case nil: break
        }
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

    /// Speeds offered when the speed is tapped, taken from what the pad supports.
    /// In the unit shown (`kmPerUnit` 1 for km/h); multiply by it before `setSpeed`.
    func quickSpeeds(kmPerUnit: Double) -> [Double] { (speedRange ?? .sportstechPad).quickSpeeds(kmPerUnit: kmPerUnit) }

    func setSpeed(_ kmh: Double) {
        guard canControl, !queue.contains(.stop), inFlight != .stop else { return }
        let v = (speedRange ?? .sportstechPad).normalized(kmh)
        lastSpeedCommand = (v, Date())
        lastError = nil
        // While a button is held, newer speed targets replace older queued ones instead of piling up.
        queue.removeAll { if case .setTargetSpeed = $0 { true } else { false } }
        enqueue(controlGranted ? [.setTargetSpeed(kmh: v)] : [.requestControl, .setTargetSpeed(kmh: v)], replacing: false)
    }

    /// `delta` is in the unit shown: 0.1 is a tenth of a km/h, or of a mph with `kmPerUnit` a mile.
    func changeSpeed(by delta: Double, kmPerUnit: Double = 1) {
        // Base on a very recent command so quick repeated taps add up before the belt catches up.
        let base: Double
        if let last = lastSpeedCommand, Date().timeIntervalSince(last.at) < 2 { base = last.kmh }
        else { base = data.speedKmh ?? 0 }
        setSpeed((speedRange ?? .sportstechPad).stepped(from: base, by: delta, kmPerUnit: kmPerUnit))
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
            await healthQueue.requestAuthorization()
            await stride.refreshFromHealth()
            healthQueue.flush()
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
        releaseReason = nil
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
        release(.user)
    }

    /// Share mode: lets go of the pad so another phone can take it. Reconnects when the app is opened.
    private func releaseForOthers(_ why: String) {
        guard disconnectsWhenIdle, !isDemo, !isWalkInProgress, releaseReason == nil else { return }
        log.notice("released pad for other phones: \(why)")
        release(.auto)
    }

    private func release(_ reason: ReleaseReason) {
        userDisconnected = true
        releaseReason = reason
        finishSession()
        if let p = peripheral { central.cancelPeripheralConnection(p) }   // also cancels a pending connect
        resetSession()
        connectionError = nil
        state = .idle
    }

    /// Connects to the saved pad again after `disconnect()`.
    func reconnect() {
        guard isReleased else { return }
        releaseReason = nil
        connectSaved()
    }

    /// Disconnects and forgets the saved pad.
    func forgetDevice() {
        guard !isWalkInProgress else { return }
        userDisconnected = true
        releaseReason = nil
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
        recorder.resetCounters()
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
        idleSince = nil
    }

    private func ingest(_ packet: TreadmillData) {
        let d = packet.merged(over: data)
        data = d
        recorder.ingest(d, model: stepModel)
        updateLiveActivity()
        // Forgotten pause: close the walk after 30 minutes, ending where the pause began.
        if recorder.pauseIsForgotten { finishSession() }
        // Share mode: an idle pad is let go in the background so another phone can use it.
        let inUse = recorder.hasWalk || (d.speedKmh ?? 0) > 0.1
        if inUse || idleSince == nil { idleSince = Date() }
        if disconnectsWhenIdle, !isForeground, let since = idleSince, Date().timeIntervalSince(since) > Self.idleReleaseDelay {
            releaseForOthers("idle in background")
        }
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
                } else if disconnectsWhenIdle, UIApplication.shared.applicationState == .background {
                    // Share mode: never grab the pad from the background; reconnect when the app is opened.
                    releaseReason = .auto
                    state = .idle
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
            let wasWalking = isWalkInProgress   // read before anything changes: it depends on state == .connected
            finishSession()
            guard !userDisconnected, peripheral?.identifier == p.identifier else { return }
            // Share mode: a pad switched off while we are in the background must not be grabbed again when it comes back.
            if disconnectsWhenIdle, !isForeground, !wasWalking {
                releaseForOthers("pad gone while in background")
                return
            }
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
            idleSince = Date()
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
