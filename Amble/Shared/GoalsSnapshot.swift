import Foundation

/// This week's goal progress. The app saves it into the shared App Group container so the home screen widget
/// can show it without reading Apple Health, which is locked whenever the phone is.
struct GoalsSnapshot: Codable, Equatable {
    var weekStart: Date
    var weekEnd: Date
    var walks: Int
    var minutes: Int
    var goalWalks: Int
    var goalMinutes: Int
    var streak: Int

    var isComplete: Bool { walks >= goalWalks && minutes >= goalMinutes }
    var walkProgress: Double { goalWalks > 0 ? min(1, Double(walks) / Double(goalWalks)) : 1 }
    var minuteProgress: Double { goalMinutes > 0 ? min(1, Double(minutes) / Double(goalMinutes)) : 1 }

    /// What this data means at `date`. Walks are only saved by the app, so once the saved week has ended
    /// the new week is empty until the app saves something.
    func adjusted(to date: Date, calendar: Calendar = .current) -> GoalsSnapshot {
        guard date >= weekEnd, let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return self }
        var next = self
        next.weekStart = week.start
        next.weekEnd = week.end
        next.walks = 0
        next.minutes = 0
        // The streak carries on only if the week that just ended was complete and directly precedes this one.
        let followsDirectly = abs(week.start.timeIntervalSince(weekEnd)) < 1
        next.streak = (isComplete && followsDirectly) ? streak : 0
        return next
    }

    /// Shown in the widget gallery and as a placeholder.
    static var sample: GoalsSnapshot {
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())
        return GoalsSnapshot(weekStart: week?.start ?? Date(), weekEnd: week?.end ?? Date().addingTimeInterval(7 * 86_400),
                             walks: 2, minutes: 55, goalWalks: 3, goalMinutes: 90, streak: 2)
    }
}

enum GoalsSnapshotStore {
    static let appGroup = "group.org.biskup.amble"
    static let widgetKind = "GoalsWidget"
    private static let key = "goalsSnapshot"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func save(_ snapshot: GoalsSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> GoalsSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GoalsSnapshot.self, from: data)
    }
}

/// The short encouragement under the rings, worded separately for each count so every language
/// can apply its own plural rules.
enum GoalMessage {
    static func text(walks: Int, minutes: Int, goalWalks: Int, goalMinutes: Int) -> String {
        if walks >= goalWalks && minutes >= goalMinutes { return String(localized: "Goal reached. The sloth is proud of you.") }
        let walksLeft = max(0, goalWalks - walks)
        let minutesLeft = max(0, goalMinutes - minutes)
        switch (walksLeft, minutesLeft) {
        case (0, let m): return String(localized: "\(String(localized: "\(m) more minutes")) to go. No rush.")
        case (let w, 0): return String(localized: "\(String(localized: "\(w) more walks")) to go. No rush.")
        case (let w, let m): return String(localized: "\(String(localized: "\(w) more walks")) and \(String(localized: "\(m) more minutes")) to go. No rush.")
        }
    }
}
