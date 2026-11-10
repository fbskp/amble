import Foundation

/// A stretch of a walk during which the belt was paused.
public struct WalkPause: Sendable, Codable, Equatable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// About one minute of a walk: what was walked between two marks. Pauses fall between segments, never inside one.
public struct WalkSegment: Sendable, Codable, Equatable {
    public var start: Date
    public var end: Date
    public var distanceMeters: Double
    public var energyKcal: Double
    /// Estimated, so fractional; `WalkSession.segmentStepCounts` turns them into whole steps.
    public var steps: Double

    public init(start: Date, end: Date, distanceMeters: Double, energyKcal: Double, steps: Double) {
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.energyKcal = energyKcal
        self.steps = steps
    }

    public var seconds: Double { end.timeIntervalSince(start) }
    public var speedKmh: Double { seconds > 0 ? distanceMeters / seconds * 3.6 : 0 }
}

/// One finished belt session, ready to be written to Apple Health.
public struct WalkSession: Sendable, Codable, Equatable {
    public var start: Date
    public var end: Date
    public var distanceMeters: Double
    public var energyKcal: Double
    public var steps: Int
    /// Optional so walks queued by older versions still decode.
    public var pauses: [WalkPause]?
    /// Failed save attempts while Health was readable. Optional so older queued walks still decode.
    public var saveAttempts: Int?
    /// The walk minute by minute; their sums match the totals above. Nil for walks recorded before segments existed.
    public var segments: [WalkSegment]?

    public init(start: Date, end: Date, distanceMeters: Double, energyKcal: Double, steps: Int,
                pauses: [WalkPause]? = nil, saveAttempts: Int? = nil, segments: [WalkSegment]? = nil) {
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.energyKcal = energyKcal
        self.steps = steps
        self.pauses = pauses
        self.saveAttempts = saveAttempts
        self.segments = segments
    }

    /// Time actually walked: the span minus paused time.
    public var activeSeconds: Double {
        let paused = (pauses ?? []).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        return max(0, end.timeIntervalSince(start) - paused)
    }

    public var averageSpeedKmh: Double { activeSeconds > 0 ? distanceMeters / activeSeconds * 3.6 : 0 }

    /// Whole steps per segment that add up to `steps` exactly (rounded along the running total, not one by one).
    public var segmentStepCounts: [Int] {
        guard let segments, !segments.isEmpty else { return [] }
        let counted = segments.reduce(0) { $0 + $1.steps }
        let scale = counted > 0 ? Double(steps) / counted : 0
        var running = 0.0, previous = 0
        return segments.map { segment in
            running += segment.steps * scale
            let whole = Int(running.rounded())
            defer { previous = whole }
            return whole - previous
        }
    }
}
