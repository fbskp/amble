import Foundation
import Testing
@testable import AmbleCore

@Suite struct WeeklyProgressTests {
    // Monday-first calendar in UTC so results do not depend on the machine's settings.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func walk(_ iso: String, minutes: Double) -> WalkRecord {
        WalkRecord(start: date(iso), durationSeconds: minutes * 60, distanceMeters: minutes * 50, steps: Int(minutes * 100))
    }

    @Test func groupsWalksIntoCalendarWeeks() {
        // 2026-11-04 is a Wednesday; its week starts Monday 2026-11-02.
        let now = date("2026-11-04T12:00:00Z")
        let walks = [
            walk("2026-11-02T08:00:00Z", minutes: 30),   // Monday, current week
            walk("2026-11-04T07:00:00Z", minutes: 20),   // Wednesday, current week
            walk("2026-10-30T18:00:00Z", minutes: 45),   // previous week (Friday)
            walk("2026-10-25T23:30:00Z", minutes: 10),   // Sunday, belongs to the week of 10-19
        ]
        let weeks = WeeklyProgress.summaries(for: walks, weeks: 3, endingAt: now, calendar: calendar)
        #expect(weeks.count == 3)
        #expect(weeks[2].start == date("2026-11-02T00:00:00Z"))
        #expect(weeks[2].walks == 2)
        #expect(weeks[2].minutes == 50)
        #expect(weeks[1].walks == 1)
        #expect(weeks[1].minutes == 45)
        #expect(weeks[0].walks == 1)
        #expect(weeks[0].start == date("2026-10-19T00:00:00Z"))
    }

    @Test func ignoresWalksOutsideTheWindowAndKeepsEmptyWeeks() {
        let now = date("2026-11-04T12:00:00Z")
        let weeks = WeeklyProgress.summaries(for: [walk("2026-01-05T10:00:00Z", minutes: 60)], weeks: 4, endingAt: now, calendar: calendar)
        #expect(weeks.count == 4)
        #expect(weeks.allSatisfy { $0.walks == 0 })
    }

    @Test func goalsNeedBothTargets() {
        let goals = WeeklyGoals(walks: 3, minutes: 90)
        #expect(goals.isMet(by: WeekSummary(start: .now, walks: 3, seconds: 90 * 60)))
        #expect(!goals.isMet(by: WeekSummary(start: .now, walks: 2, seconds: 120 * 60)))
        #expect(!goals.isMet(by: WeekSummary(start: .now, walks: 5, seconds: 80 * 60)))
        #expect(goals.walkProgress(WeekSummary(start: .now, walks: 1)) == 1.0 / 3.0)
        #expect(goals.minuteProgress(WeekSummary(start: .now, seconds: 200 * 60)) == 1)
    }

    @Test func streakCountsCompletedWeeks() {
        let goals = WeeklyGoals(walks: 2, minutes: 60)
        func week(_ n: Int, ok: Bool) -> WeekSummary {
            WeekSummary(start: Date(timeIntervalSince1970: Double(n) * 604_800), walks: ok ? 2 : 1, seconds: ok ? 3600 : 600)
        }
        // Current week incomplete: it does not break the streak of the two completed weeks before it.
        #expect(WeeklyProgress.streak(summaries: [week(1, ok: false), week(2, ok: true), week(3, ok: true), week(4, ok: false)], goals: goals) == 2)
        // Current week complete: it counts too.
        #expect(WeeklyProgress.streak(summaries: [week(1, ok: false), week(2, ok: true), week(3, ok: true), week(4, ok: true)], goals: goals) == 3)
        // A missed week in the middle ends the streak.
        #expect(WeeklyProgress.streak(summaries: [week(1, ok: true), week(2, ok: false), week(3, ok: true), week(4, ok: false)], goals: goals) == 1)
        #expect(WeeklyProgress.streak(summaries: [], goals: goals) == 0)
    }

    @Test func streakIsNotLimitedToTheWeeksShown() {
        let now = date("2026-11-04T12:00:00Z")
        let walks = (0..<12).map { back in
            WalkRecord(start: calendar.date(byAdding: .weekOfYear, value: -back, to: now)!, durationSeconds: 3600)
        }
        let summaries = WeeklyProgress.summariesForAllHistory(of: walks, minimumWeeks: 8, endingAt: now, calendar: calendar)
        #expect(summaries.count == 12)
        #expect(WeeklyProgress.streak(summaries: summaries, goals: WeeklyGoals(walks: 1, minutes: 30)) == 12)
        // Little or no history still gives the weeks the chart shows.
        #expect(WeeklyProgress.summariesForAllHistory(of: [], minimumWeeks: 8, endingAt: now, calendar: calendar).count == 8)
    }
}
