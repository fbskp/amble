import Foundation

public enum AchievementID: String, CaseIterable, Codable, Sendable {
    case firstSteps, slowAndSteady, branchToBranch, threeToed, leafEater, hangingOn, treetopHabit
    case aroundTheTree, slothMarathon, canopyCrossing, unhurried, nightShift, earlySloth
}

public extension AchievementID {
    /// SF Symbol name. The title and description live in the app, where they are translated.
    var symbol: String {
        switch self {
        case .firstSteps: "shoeprints.fill"
        case .slowAndSteady: "tortoise.fill"
        case .branchToBranch: "clock.fill"
        case .threeToed: "3.circle.fill"
        case .leafEater: "leaf.fill"
        case .hangingOn: "calendar"
        case .treetopHabit: "star.fill"
        case .aroundTheTree: "map.fill"
        case .slothMarathon: "trophy.fill"
        case .canopyCrossing: "globe.europe.africa.fill"
        case .unhurried: "hourglass"
        case .nightShift: "moon.stars.fill"
        case .earlySloth: "sunrise.fill"
        }
    }
}

/// Running totals across all walks, used for progress bars on locked achievements.
public struct AchievementTotals: Equatable, Sendable {
    public var walks = 0
    public var distanceMeters = 0.0
    public var seconds = 0.0
    public var longestWalkSeconds = 0.0
    public var mostWalksInWeek = 0
    /// Longest run of consecutive weeks with at least one walk.
    public var longestWeekRun = 0
    /// Longest run of consecutive weeks in which the weekly goals were reached.
    public var longestGoalRun = 0

    public init() {}
}

public struct AchievementReport: Equatable, Sendable {
    /// Unlocked achievements and the date of the walk that earned each.
    public var unlocked: [AchievementID: Date]
    public var totals: AchievementTotals

    public init(unlocked: [AchievementID: Date], totals: AchievementTotals) {
        self.unlocked = unlocked
        self.totals = totals
    }

    /// 0...1 progress towards an achievement (1 when unlocked).
    public func progress(_ id: AchievementID) -> Double {
        if unlocked[id] != nil { return 1 }
        let t = totals
        let value: Double, target: Double
        switch id {
        case .firstSteps: (value, target) = (Double(t.walks), 1)
        case .slowAndSteady: (value, target) = (t.longestWalkSeconds, 30 * 60)
        case .branchToBranch: (value, target) = (t.longestWalkSeconds, 60 * 60)
        case .threeToed: (value, target) = (Double(t.mostWalksInWeek), 3)
        case .hangingOn: (value, target) = (Double(t.longestWeekRun), 4)
        case .treetopHabit: (value, target) = (Double(t.longestGoalRun), 3)
        case .aroundTheTree: (value, target) = (t.distanceMeters, 10_000)
        case .slothMarathon: (value, target) = (t.distanceMeters, 42_195)
        case .canopyCrossing: (value, target) = (t.distanceMeters, 100_000)
        case .unhurried: (value, target) = (t.seconds, 10 * 3600)
        case .leafEater, .nightShift, .earlySloth: return 0
        }
        return min(1, max(0, value / target))
    }
}

public enum AchievementEngine {
    /// Works through all walks in order and reports what is unlocked, and when.
    /// Streak-based achievements use the current weekly goals.
    public static func evaluate(walks: [WalkRecord], goals: WeeklyGoals, calendar: Calendar) -> AchievementReport {
        var unlocked: [AchievementID: Date] = [:]
        var totals = AchievementTotals()
        func unlock(_ id: AchievementID, _ date: Date) { if unlocked[id] == nil { unlocked[id] = date } }

        struct Week { var walks = 0; var seconds = 0.0; var firstWalk: Date; var metDate: Date? }
        var weeks: [Date: Week] = [:]

        for walk in walks.sorted(by: { $0.start < $1.start }) {
            totals.walks += 1
            totals.distanceMeters += walk.distanceMeters
            totals.seconds += walk.durationSeconds
            totals.longestWalkSeconds = max(totals.longestWalkSeconds, walk.durationSeconds)

            unlock(.firstSteps, walk.start)
            if walk.durationSeconds >= 30 * 60 { unlock(.slowAndSteady, walk.start) }
            if walk.durationSeconds >= 60 * 60 { unlock(.branchToBranch, walk.start) }
            if totals.distanceMeters >= 10_000 { unlock(.aroundTheTree, walk.start) }
            if totals.distanceMeters >= 42_195 { unlock(.slothMarathon, walk.start) }
            if totals.distanceMeters >= 100_000 { unlock(.canopyCrossing, walk.start) }
            if totals.seconds >= 10 * 3600 { unlock(.unhurried, walk.start) }
            let hour = calendar.component(.hour, from: walk.start)
            if hour >= 21 { unlock(.nightShift, walk.start) }
            if hour < 9 { unlock(.earlySloth, walk.start) }

            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: walk.start)?.start else { continue }
            var week = weeks[weekStart] ?? Week(firstWalk: walk.start)
            week.walks += 1
            week.seconds += walk.durationSeconds
            totals.mostWalksInWeek = max(totals.mostWalksInWeek, week.walks)
            if week.walks >= 3 { unlock(.threeToed, walk.start) }
            if week.metDate == nil, goals.isMet(by: WeekSummary(start: weekStart, walks: week.walks, seconds: week.seconds)) {
                week.metDate = walk.start
                unlock(.leafEater, walk.start)
            }
            weeks[weekStart] = week
        }

        // Runs of consecutive weeks, oldest first, so the earliest qualifying date wins.
        var previous: Date?
        var previousMet = false
        var weekRun = 0, goalRun = 0
        for key in weeks.keys.sorted() {
            guard let week = weeks[key] else { continue }
            let consecutive = previous.flatMap { calendar.date(byAdding: .weekOfYear, value: 1, to: $0) } == key
            weekRun = consecutive ? weekRun + 1 : 1
            totals.longestWeekRun = max(totals.longestWeekRun, weekRun)
            if weekRun >= 4 { unlock(.hangingOn, week.firstWalk) }

            if let met = week.metDate {
                goalRun = (consecutive && previousMet) ? goalRun + 1 : 1
                totals.longestGoalRun = max(totals.longestGoalRun, goalRun)
                if goalRun >= 3 { unlock(.treetopHabit, met) }
                previousMet = true
            } else {
                goalRun = 0
                previousMet = false
            }
            previous = key
        }

        return AchievementReport(unlocked: unlocked, totals: totals)
    }
}
