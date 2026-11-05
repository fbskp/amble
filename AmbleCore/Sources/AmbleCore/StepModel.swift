import Foundation

/// Estimates steps from distance and belt speed. The pad reports no steps.
///
/// Walking is not one fixed stride: the slower you walk, the shorter and the more frequent your steps are.
/// The model uses the usual linear relation between walking speed and cadence (steps per minute) and
/// anchors it to the user's own step length at a normal walking pace, so it follows body size.
/// The slope is an average from gait studies, so counts stay approximate.
public struct StepModel: Equatable, Sendable {
    /// Pace at which `referenceStepLength` applies.
    public static let referenceSpeedKmh = 4.7
    /// Steps per minute gained for each extra m/s of walking speed (about 13 per km/h).
    public static let cadenceSlope = 48.0
    /// Below this speed the model stops shortening the step further.
    public static let slowestModelledSpeedKmh = 0.5
    public static let lowestCadence = 30.0
    public static let stepLengthRange = 0.4...1.0

    /// Step length in metres at a normal walking pace.
    public let referenceStepLength: Double

    public init(referenceStepLength: Double = 0.70) {
        self.referenceStepLength = min(max(referenceStepLength, Self.stepLengthRange.lowerBound), Self.stepLengthRange.upperBound)
    }

    /// Common rule of thumb: step length at a normal pace is about 0.413 x body height.
    public init(heightMeters: Double) {
        self.init(referenceStepLength: (0.413 * heightMeters * 1000).rounded() / 1000)
    }

    /// Steps per minute at the given belt speed.
    public func cadence(atSpeedKmh speed: Double) -> Double {
        let reference = Self.referenceSpeedKmh / 3.6
        let referenceCadence = reference / referenceStepLength * 60
        let intercept = referenceCadence - Self.cadenceSlope * reference
        let metresPerSecond = max(speed, Self.slowestModelledSpeedKmh) / 3.6
        return max(Self.lowestCadence, intercept + Self.cadenceSlope * metresPerSecond)
    }

    /// Step length in metres at the given belt speed.
    public func stepLength(atSpeedKmh speed: Double) -> Double {
        let metresPerSecond = max(speed, Self.slowestModelledSpeedKmh) / 3.6
        return metresPerSecond * 60 / cadence(atSpeedKmh: speed)
    }

    public func steps(forDistance meters: Double, atSpeedKmh speed: Double) -> Double {
        guard meters > 0 else { return 0 }
        return meters / stepLength(atSpeedKmh: speed)
    }
}

/// Adds up steps while the distance grows, using the speed at the time, so speed changes during a walk are handled.
public struct StepCounter: Codable, Equatable, Sendable {
    public private(set) var steps = 0.0
    private var lastDistance: Int?
    private var lastSpeed: Double?

    public init() {}

    /// Starts counting from the pad's current counters.
    public init(startingAtDistance distance: Int?, speedKmh: Double?) {
        lastDistance = distance
        lastSpeed = speedKmh
    }

    public mutating func add(distanceMeters: Int?, speedKmh: Double?, model: StepModel) {
        let previousSpeed = lastSpeed
        defer {
            if let distanceMeters { lastDistance = distanceMeters }
            if let speedKmh { lastSpeed = speedKmh }
        }
        guard let distanceMeters, let lastDistance else { return }
        let gained = distanceMeters - lastDistance
        guard gained > 0 else { return }   // no progress, or the pad's counter was reset
        let speed: Double
        switch (previousSpeed, speedKmh) {
        case let (a?, b?): speed = (a + b) / 2
        case let (a?, nil): speed = a
        case let (nil, b?): speed = b
        case (nil, nil): speed = StepModel.referenceSpeedKmh
        }
        steps += model.steps(forDistance: Double(gained), atSpeedKmh: speed)
    }
}
