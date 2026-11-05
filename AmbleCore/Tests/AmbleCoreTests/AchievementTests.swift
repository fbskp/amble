import Foundation
import Testing
@testable import AmbleCore

@Suite struct AchievementTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func walk(_ iso: String, minutes: Double = 20, km: Double = 1) -> WalkRecord {
        WalkRecord(start: date(iso), durationSeconds: minutes * 60, distanceMeters: km * 1000, steps: 0)
    }

    private let easy = WeeklyGoals(walks: 1, minutes: 10)

    @Test func nothingWithoutWalks() {
        let r = AchievementEngine.evaluate(walks: [], goals: easy, calendar: calendar)
        #expect(r.unlocked.isEmpty)
        #expect(r.progress(.firstSteps) == 0)
    }

    @Test func singleWalkAchievements() {
        let r = AchievementEngine.evaluate(walks: [walk("2026-11-03T22:15:00Z", minutes: 65)], goals: easy, calendar: calendar)
        #expect(r.unlocked[.firstSteps] == date("2026-11-03T22:15:00Z"))
        #expect(r.unlocked[.slowAndSteady] != nil)
        #expect(r.unlocked[.branchToBranch] != nil)
        #expect(r.unlocked[.nightShift] != nil)
        #expect(r.unlocked[.earlySloth] == nil)
        #expect(r.unlocked[.leafEater] != nil)   // easy goals reached by this one walk
    }

    @Test func earlyAchievementEndsAtNine() {
        func early(_ time: String) -> Bool {
            AchievementEngine.evaluate(walks: [walk("2026-11-03T\(time)Z")], goals: easy, calendar: calendar).unlocked[.earlySloth] != nil
        }
        #expect(early("08:59:00"))
        #expect(!early("09:00:00"))
    }

    @Test func earlyWalk() {
        let r = AchievementEngine.evaluate(walks: [walk("2026-11-03T06:30:00Z")], goals: easy, calendar: calendar)
        #expect(r.unlocked[.earlySloth] != nil)
        #expect(r.unlocked[.nightShift] == nil)
    }

    @Test func cumulativeDistanceAndTimeUnlockWhenCrossed() {
        let walks = (0..<11).map { walk("2026-10-\(String(format: "%02d", 1 + $0 * 2))T12:00:00Z", minutes: 60, km: 1) }
        let r = AchievementEngine.evaluate(walks: walks, goals: easy, calendar: calendar)
        // 10 km is reached by the tenth walk (index 9), 10 hours as well.
        #expect(r.unlocked[.aroundTheTree] == walks[9].start)
        #expect(r.unlocked[.unhurried] == walks[9].start)
        #expect(r.unlocked[.slothMarathon] == nil)
        #expect(r.progress(.slothMarathon) > 0.25 && r.progress(.slothMarathon) < 0.27)
    }

    @Test func threeWalksInOneWeek() {
        let walks = [walk("2026-11-02T10:00:00Z"), walk("2026-11-03T10:00:00Z"), walk("2026-11-05T10:00:00Z")]
        let r = AchievementEngine.evaluate(walks: walks, goals: WeeklyGoals(walks: 9, minutes: 999), calendar: calendar)
        #expect(r.unlocked[.threeToed] == date("2026-11-05T10:00:00Z"))
        #expect(r.unlocked[.leafEater] == nil)
    }

    @Test func weekRunsNeedConsecutiveWeeks() {
        // Weeks of 10-12, 10-19, 10-26, 11-02: four in a row.
        let four = ["2026-10-13", "2026-10-20", "2026-10-27", "2026-11-03"].map { walk("\($0)T10:00:00Z") }
        let r = AchievementEngine.evaluate(walks: four, goals: easy, calendar: calendar)
        #expect(r.unlocked[.hangingOn] == date("2026-11-03T10:00:00Z"))
        #expect(r.unlocked[.treetopHabit] == date("2026-10-27T10:00:00Z"))   // third week in a row reaching the goals
        #expect(r.totals.longestWeekRun == 4)

        // A gap week breaks the run.
        let gap = ["2026-10-13", "2026-10-20", "2026-11-03", "2026-11-10"].map { walk("\($0)T10:00:00Z") }
        let g = AchievementEngine.evaluate(walks: gap, goals: easy, calendar: calendar)
        #expect(g.unlocked[.hangingOn] == nil)
        #expect(g.totals.longestWeekRun == 2)
        #expect(abs(g.progress(.hangingOn) - 0.5) < 0.001)
    }
}
