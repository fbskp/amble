import ActivityKit
import Foundation

/// Shared by the app (which starts and updates the Live Activity) and the widget extension (which draws it).
struct WalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speedKmh: Double
        var distanceMeters: Int
        var steps: Int
        var energyKcal: Int
        /// The timer counts up from here, so it needs no updates to keep running.
        var timerStart: Date
        /// Set while the walk is paused: the timer freezes at this moment.
        var pausedAt: Date?

        var isPaused: Bool { pausedAt != nil }
    }

    var padName: String
    /// The timer on screen counts from here, so it ticks without any updates from the app.
    var startDate: Date
}
