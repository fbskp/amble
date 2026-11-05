import Foundation

/// One finished walk, reduced to what goals need.
public struct WalkRecord: Equatable, Sendable {
    public var start: Date
    public var durationSeconds: Double
    public var distanceMeters: Double
    public var steps: Int

    public init(start: Date, durationSeconds: Double, distanceMeters: Double = 0, steps: Int = 0) {
        self.start = start
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.steps = steps
    }
}

/// Totals for one calendar week.
public struct WeekSummary: Equatable, Sendable, Identifiable {
    public var start: Date
    public var walks: Int
    public var seconds: Double
    public var distanceMeters: Double
    public var steps: Int

    public var id: Date { start }
    public var minutes: Int { Int(seconds / 60) }

    public init(start: Date, walks: Int = 0, seconds: Double = 0, distanceMeters: Double = 0, steps: Int = 0) {
        self.start = start
        self.walks = walks
        self.seconds = seconds
        self.distanceMeters = distanceMeters
        self.steps = steps
    }
}

/// The user's weekly targets. A week is complete when both are reached.
public struct WeeklyGoals: Equatable, Sendable {
    public var walks: Int
    public var minutes: Int

    public static let `default` = WeeklyGoals(walks: 3, minutes: 90)

    public init(walks: Int, minutes: Int) {
        self.walks = walks
        self.minutes = minutes
    }

    public func isMet(by week: WeekSummary) -> Bool {
        week.walks >= walks && week.minutes >= minutes
    }

    /// Progress 0...1 for each goal, for rings.
    public func walkProgress(_ week: WeekSummary) -> Double { walks > 0 ? min(1, Double(week.walks) / Double(walks)) : 1 }
    public func minuteProgress(_ week: WeekSummary) -> Double { minutes > 0 ? min(1, Double(week.minutes) / Double(minutes)) : 1 }
}

public enum WeeklyProgress {
    /// Summaries for the last `weeks` calendar weeks, oldest first, the week containing `now` last.
    /// Weeks without walks are included as empty summaries.
    public static func summaries(for walks: [WalkRecord], weeks: Int, endingAt now: Date, calendar: Calendar) -> [WeekSummary] {
        guard weeks > 0, let currentStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var result: [WeekSummary] = (0..<weeks).reversed().compactMap { back in
            calendar.date(byAdding: .weekOfYear, value: -back, to: currentStart).map { WeekSummary(start: $0) }
        }
        for walk in walks {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: walk.start)?.start,
                  let i = result.firstIndex(where: { $0.start == start }) else { continue }
            result[i].walks += 1
            result[i].seconds += walk.durationSeconds
            result[i].distanceMeters += walk.distanceMeters
            result[i].steps += walk.steps
        }
        return result
    }

    /// Summaries back to the first walk, but at least `minimumWeeks`. Oldest first, the week containing `now` last.
    public static func summariesForAllHistory(of walks: [WalkRecord], minimumWeeks: Int, endingAt now: Date, calendar: Calendar) -> [WeekSummary] {
        var count = minimumWeeks
        if let first = walks.map(\.start).min(),
           let firstWeek = calendar.dateInterval(of: .weekOfYear, for: first)?.start,
           let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
           let span = calendar.dateComponents([.weekOfYear], from: firstWeek, to: currentWeek).weekOfYear {
            count = max(count, span + 1)
        }
        return summaries(for: walks, weeks: count, endingAt: now, calendar: calendar)
    }

    /// Consecutive completed weeks ending now. The current week counts once it is complete, but while it is
    /// still open and incomplete it neither adds to nor breaks the streak.
    public static func streak(summaries: [WeekSummary], goals: WeeklyGoals) -> Int {
        guard let current = summaries.last else { return 0 }
        var count = goals.isMet(by: current) ? 1 : 0
        for week in summaries.dropLast().reversed() {
            guard goals.isMet(by: week) else { break }
            count += 1
        }
        return count
    }
}
