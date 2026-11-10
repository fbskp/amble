import Foundation
import Observation
import os

/// Records one walk from the pad's counters: its start, pauses, steps and the last values seen. It knows nothing
/// about Bluetooth; the app's pad connection tells it what the pad reported. The open walk is kept on disk, so it can be
/// carried on after an app restart or still be saved if the app is killed before the belt stops.
@MainActor @Observable
public final class WalkRecorder {
    /// What became of a walk that ended.
    public enum Outcome: Equatable, Sendable {
        case walk(WalkSession)
        case tooShort
    }

    public static let minimumWalkSeconds: TimeInterval = 30
    /// A saved walk counts as the one still running only if it was seen recently; an older one is a different walk.
    private static let sameWalkGap: TimeInterval = 30 * 60
    private static let forgottenPauseDelay: TimeInterval = 30 * 60
    private static let activeKey = "activeSession"
    /// Length of one segment of the walk (see `WalkSegment`).
    public static let segmentSeconds: TimeInterval = 60

    /// Where the open segment began: the time and the pad's counters at that moment.
    private struct SegmentMark: Codable {
        var start: Date
        var distance: Int?
        var kcal: Int?
        var steps: Double
    }

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
        // Minute by minute: the closed segments and where the open one began. Nil while paused.
        var segments: [WalkSegment]?
        var mark: SegmentMark?
    }

    private var active: ActiveSession?
    private var lastActivePersist = Date.distantPast
    /// Pad counters at the first packet of this connection, or at the start of the walk; session values are measured from here.
    private var baselineDistance: Int?
    private var baselineSeconds: Int?
    private var baselineKcal: Int?
    /// Steps since the session baseline (connection or start of the walk).
    public private(set) var stepCounter = StepCounter()
    /// Demo walks are neither kept on disk nor handed on when they end.
    public var isDemo = false
    private let log = Logger(subsystem: "org.biskup.amble", category: "walk")
    private let defaults: UserDefaults
    private let now: () -> Date

    /// `defaults` holds the open walk; `now` is the clock. Tests pass their own.
    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    public var hasWalk: Bool { active != nil }
    /// The walk is paused: the belt has stopped but the walk is not over and not yet saved.
    public var isPaused: Bool { active?.pausedAt != nil }
    public var pausedAt: Date? { active?.pausedAt }
    public var walkStart: Date? { active?.start }
    /// A pause nobody ended: the walk should be closed, ending where the pause began.
    public var pauseIsForgotten: Bool {
        guard let pausedAt = active?.pausedAt else { return false }
        return now().timeIntervalSince(pausedAt) > Self.forgottenPauseDelay
    }

    public var steps: Int { Int(stepCounter.steps.rounded()) }

    public func distanceMeters(in data: TreadmillData) -> Int {
        guard let d = data.totalDistanceMeters, let b = baselineDistance else { return 0 }
        return max(0, d - b)
    }

    public func seconds(in data: TreadmillData) -> Int {
        guard let t = data.elapsedSeconds, let b = baselineSeconds else { return 0 }
        return max(0, t - b)
    }

    public func energyKcal(in data: TreadmillData) -> Int {
        guard let e = data.energyTotalKcal, let b = baselineKcal else { return 0 }
        return max(0, e - b)
    }

    // MARK: Disk

    private func loadActive() -> ActiveSession? {
        guard let data = defaults.data(forKey: Self.activeKey) else { return nil }
        return try? JSONDecoder().decode(ActiveSession.self, from: data)
    }

    private func restorableSession() -> ActiveSession? {
        guard let saved = loadActive(), now().timeIntervalSince(saved.lastSeen ?? saved.start) < Self.sameWalkGap else { return nil }
        return saved
    }

    private func persistActive() {
        lastActivePersist = now()
        if let active, !isDemo { defaults.set(try? JSONEncoder().encode(active), forKey: Self.activeKey) }
        else { defaults.removeObject(forKey: Self.activeKey) }
    }

    // MARK: Walk

    /// Starts a new walk, measured from the pad's current counters.
    public func begin(with data: TreadmillData) {
        active = ActiveSession(start: now(), startDistance: data.totalDistanceMeters,
                               startKcal: data.energyTotalKcal, startSeconds: data.elapsedSeconds)
        baselineDistance = data.totalDistanceMeters
        baselineSeconds = data.elapsedSeconds
        baselineKcal = data.energyTotalKcal
        stepCounter = StepCounter(startingAtDistance: data.totalDistanceMeters, speedKmh: data.speedKmh)
        active?.stepCounter = stepCounter
        active?.mark = SegmentMark(start: now(), distance: data.totalDistanceMeters, kcal: data.energyTotalKcal, steps: 0)
        persistActive()
    }

    /// Closes the open segment at `end`, measured against the pad's counters at that moment.
    private func closeSegment(_ a: inout ActiveSession, at end: Date, distance: Int?, kcal: Int?, steps: Double) {
        guard let mark = a.mark else { return }
        a.mark = nil
        guard end > mark.start else { return }
        func gained(_ value: Int?, since: Int?) -> Double {
            guard let value, let since else { return 0 }
            return Double(value >= since ? value - since : value)   // a lower counter was reset: count from zero
        }
        a.segments = (a.segments ?? []) + [WalkSegment(start: mark.start, end: end,
                                                       distanceMeters: gained(distance, since: mark.distance),
                                                       energyKcal: gained(kcal, since: mark.kcal),
                                                       steps: max(0, steps - mark.steps))]
    }

    /// Carries on with a walk saved before the app was restarted, including the steps counted so far.
    /// Returns false when there is none (or, with `onlyIfPaused`, none that was paused).
    public func restore(onlyIfPaused: Bool = false) -> Bool {
        guard let saved = restorableSession(), !onlyIfPaused || saved.pausedAt != nil else { return false }
        log.notice("restored walk from \(saved.start)")
        active = saved
        baselineDistance = saved.startDistance
        baselineSeconds = saved.startSeconds
        baselineKcal = saved.startKcal
        stepCounter = saved.stepCounter ?? StepCounter(startingAtDistance: saved.lastDistance ?? saved.startDistance, speedKmh: nil)
        persistActive()
        return true
    }

    /// The belt was paused. Returns whether anything changed.
    public func pause() -> Bool {
        guard var a = active, a.pausedAt == nil else { return false }
        closeSegment(&a, at: now(), distance: a.lastDistance, kcal: a.lastKcal, steps: stepCounter.steps)
        a.pausedAt = now()
        active = a
        persistActive()
        return true
    }

    /// The belt runs again after a pause. Returns whether anything changed.
    public func resume() -> Bool {
        guard var a = active, let pausedAt = a.pausedAt else { return false }
        a.pauses = (a.pauses ?? []) + [WalkPause(start: pausedAt, end: now())]
        a.pausedAt = nil
        // The next segment starts where the pause ends, so no walking time falls between segments.
        a.mark = SegmentMark(start: now(), distance: a.lastDistance, kcal: a.lastKcal, steps: stepCounter.steps)
        active = a
        persistActive()
        return true
    }

    /// Takes in the pad's latest counters (already merged with what was known before).
    public func ingest(_ d: TreadmillData, model: StepModel) {
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
        if let e = d.energyTotalKcal {
            if let b = baselineKcal, e < b { baselineKcal = 0 } else if baselineKcal == nil { baselineKcal = e }
        }
        stepCounter.add(distanceMeters: d.totalDistanceMeters, speedKmh: d.speedKmh, model: model)
        // A walk already in progress when we connected has no counter baseline until the first packet.
        if var a = active {
            if a.startDistance == nil { a.startDistance = d.totalDistanceMeters }
            if a.startKcal == nil { a.startKcal = d.energyTotalKcal }
            if a.startSeconds == nil { a.startSeconds = d.elapsedSeconds }
            a.lastSeen = now()
            a.lastDistance = d.totalDistanceMeters
            a.lastKcal = d.energyTotalKcal
            a.stepCounter = stepCounter
            if a.pausedAt == nil {
                // A segment starts with the walk, after a pause, or with the first packet of a restored walk.
                if a.mark == nil {
                    a.mark = SegmentMark(start: now(), distance: d.totalDistanceMeters, kcal: d.energyTotalKcal, steps: stepCounter.steps)
                }
                if a.mark?.distance == nil { a.mark?.distance = d.totalDistanceMeters }
                if a.mark?.kcal == nil { a.mark?.kcal = d.energyTotalKcal }
                if let mark = a.mark, now().timeIntervalSince(mark.start) >= Self.segmentSeconds {
                    closeSegment(&a, at: now(), distance: d.totalDistanceMeters, kcal: d.energyTotalKcal, steps: stepCounter.steps)
                    a.mark = SegmentMark(start: now(), distance: d.totalDistanceMeters, kcal: d.energyTotalKcal, steps: stepCounter.steps)
                }
            }
            active = a
            if now().timeIntervalSince(lastActivePersist) >= 10 { persistActive() }
        }
    }

    /// Forgets the counters of a connection that ended. An open walk is kept.
    public func resetCounters() {
        stepCounter = StepCounter()
        baselineDistance = nil
        baselineSeconds = nil
        baselineKcal = nil
    }

    /// Ends the open walk and returns it. Nil when there was none (or it was a demo walk).
    public func finish(data: TreadmillData, model: StepModel) -> Outcome? {
        // No walk in memory but one on disk: the app was killed mid-walk; close it with the last values it saw.
        let recovered = active == nil
        guard var a = active ?? loadActive() else { return nil }
        active = nil
        persistActive()
        if isDemo { return nil }   // simulated walks stay out of Health and the awards
        // A walk finished while paused ended when the pause began; the waiting time is not part of it.
        // A recovered walk ends when it was last seen, but never before its last pause ended: Health rejects later events.
        let end = a.pausedAt ?? (recovered ? max(a.lastSeen ?? a.start, a.pauses?.last?.end ?? a.start) : now())
        let endDistance = recovered ? (a.lastDistance ?? 0) : (data.totalDistanceMeters ?? a.lastDistance ?? 0)
        let endKcalSeen = recovered ? a.lastKcal : (data.energyTotalKcal ?? a.lastKcal)
        if a.pausedAt == nil {
            closeSegment(&a, at: end, distance: endDistance, kcal: endKcalSeen, steps: a.stepCounter?.steps ?? stepCounter.steps)
        }
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
            walk.steps = Int(model.steps(forDistance: distance, atSpeedKmh: distance / walk.activeSeconds * 3.6).rounded())
        }
        if let segments = a.segments, !segments.isEmpty {
            walk.segments = Self.matched(segments, to: walk)
        }
        return walk.activeSeconds >= Self.minimumWalkSeconds ? .walk(walk) : .tooShort
    }

    /// Makes the segments add up to the walk's totals. The belt still moves a little after a pause or stop
    /// begins, outside any segment; that rest goes to the last segment. If the segments counted more than the
    /// totals (a counter reset), they are scaled down.
    static func matched(_ segments: [WalkSegment], to walk: WalkSession) -> [WalkSegment] {
        var result = segments
        func match(_ value: WritableKeyPath<WalkSegment, Double>, total: Double) {
            let sum = result.reduce(0) { $0 + $1[keyPath: value] }
            if sum < total {
                result[result.count - 1][keyPath: value] += total - sum
            } else if sum > total {
                let scale = sum > 0 ? total / sum : 0
                for i in result.indices { result[i][keyPath: value] *= scale }
            }
        }
        match(\.distanceMeters, total: walk.distanceMeters)
        match(\.energyKcal, total: walk.energyKcal)
        match(\.steps, total: Double(walk.steps))
        return result
    }
}
