import Foundation
import Testing
@testable import AmbleCore

/// A clock the tests move by hand.
@MainActor private final class Clock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

@MainActor @Suite struct WalkRecorderTests {
    private let clock = Clock()
    private let defaults = UserDefaults(suiteName: "WalkRecorderTests-\(UUID().uuidString)")!
    private let model = StepModel(referenceStepLength: 0.70)

    private func recorder() -> WalkRecorder {
        let clock = clock
        return WalkRecorder(defaults: defaults, now: { clock.now })
    }

    /// The pad's counters, which carry on between walks.
    private func pad(distance: Int, seconds: Int, kcal: Int = 0, speed: Double = 3.0) -> TreadmillData {
        var d = TreadmillData()
        d.totalDistanceMeters = distance
        d.elapsedSeconds = seconds
        d.energyTotalKcal = kcal
        d.speedKmh = speed
        return d
    }

    /// Walks for `seconds` at a steady pace, one packet every 5 s. Returns the pad's last counters.
    @discardableResult
    private func walk(_ r: WalkRecorder, from start: TreadmillData, seconds: Int) -> TreadmillData {
        var d = start
        for _ in 0..<(seconds / 5) {
            clock.advance(5)
            d.totalDistanceMeters! += 4
            d.elapsedSeconds! += 5
            d.energyTotalKcal! += 1
            r.ingest(d, model: model)
        }
        return d
    }

    private func finished(_ outcome: WalkRecorder.Outcome?) throws -> WalkSession {
        guard case .walk(let walk) = outcome else { throw Failure(outcome: outcome) }
        return walk
    }
    private struct Failure: Error { let outcome: WalkRecorder.Outcome? }

    @Test func aWalkIsMeasuredFromThePadsCountersAtItsStart() throws {
        let r = recorder()
        let start = pad(distance: 1200, seconds: 900, kcal: 70)
        r.ingest(start, model: model)
        r.begin(with: start)
        let began = clock.now
        let end = walk(r, from: start, seconds: 60)

        #expect(r.hasWalk)
        #expect(r.distanceMeters(in: end) == 48)
        #expect(r.seconds(in: end) == 60)
        #expect(r.energyKcal(in: end) == 12)
        #expect(r.steps > 0)

        let saved = try finished(r.finish(data: end, model: model))
        #expect(saved.start == began)
        #expect(saved.end == clock.now)
        #expect(saved.distanceMeters == 48)
        #expect(saved.energyKcal == 12)
        #expect(saved.steps == r.steps)
        #expect(saved.pauses == nil)
        #expect(!r.hasWalk)
    }

    @Test func valuesBeforeAWalkCountFromTheFirstPacket() {
        let r = recorder()
        r.ingest(pad(distance: 500, seconds: 300, kcal: 20), model: model)
        let later = pad(distance: 510, seconds: 312, kcal: 21)
        r.ingest(later, model: model)
        #expect(r.distanceMeters(in: later) == 10)
        #expect(r.seconds(in: later) == 12)
        #expect(r.energyKcal(in: later) == 1)
        #expect(!r.hasWalk)
    }

    @Test func aWalkUnderThirtySecondsIsTooShort() {
        let r = recorder()
        let start = pad(distance: 0, seconds: 0)
        r.begin(with: start)
        let end = walk(r, from: start, seconds: 25)
        #expect(r.finish(data: end, model: model) == .tooShort)
        #expect(!r.hasWalk)
    }

    @Test func finishingWithoutAWalkGivesNothing() {
        #expect(recorder().finish(data: pad(distance: 10, seconds: 10), model: model) == nil)
    }

    @Test func pausedTimeIsRecordedAndNotCountedAsWalking() throws {
        let r = recorder()
        let start = pad(distance: 100, seconds: 100)
        r.begin(with: start)
        let middle = walk(r, from: start, seconds: 60)

        #expect(r.pause())
        #expect(!r.pause())           // a second "paused" from the pad changes nothing
        #expect(r.isPaused)
        let pausedAt = clock.now
        clock.advance(120)
        #expect(r.resume())
        #expect(!r.resume())
        #expect(!r.isPaused)
        let resumedAt = clock.now

        let end = walk(r, from: middle, seconds: 60)
        let saved = try finished(r.finish(data: end, model: model))
        #expect(saved.pauses == [WalkPause(start: pausedAt, end: resumedAt)])
        #expect(saved.activeSeconds == 120)
        #expect(saved.end.timeIntervalSince(saved.start) == 240)
    }

    @Test func aWalkFinishedWhilePausedEndsWhereThePauseBegan() throws {
        let r = recorder()
        let start = pad(distance: 0, seconds: 0)
        r.begin(with: start)
        let end = walk(r, from: start, seconds: 90)
        _ = r.pause()
        let pausedAt = clock.now
        clock.advance(600)

        let saved = try finished(r.finish(data: end, model: model))
        #expect(saved.end == pausedAt)
        #expect(saved.activeSeconds == 90)
        #expect(saved.pauses == nil)
    }

    @Test func aPauseIsForgottenAfterHalfAnHour() {
        let r = recorder()
        r.begin(with: pad(distance: 0, seconds: 0))
        #expect(!r.pauseIsForgotten)
        _ = r.pause()
        clock.advance(29 * 60)
        #expect(!r.pauseIsForgotten)
        clock.advance(2 * 60)
        #expect(r.pauseIsForgotten)
    }

    @Test func aCounterResetDuringTheWalkCountsFromZero() throws {
        let r = recorder()
        let start = pad(distance: 5000, seconds: 3000, kcal: 300)
        r.begin(with: start)
        walk(r, from: start, seconds: 30)
        // The pad was switched off and on: its counters start again.
        let end = walk(r, from: pad(distance: 0, seconds: 0, kcal: 0), seconds: 30)

        #expect(r.distanceMeters(in: end) == 24)
        #expect(r.seconds(in: end) == 30)
        #expect(r.energyKcal(in: end) == 6)
        let saved = try finished(r.finish(data: end, model: model))
        #expect(saved.distanceMeters == 24)
        #expect(saved.energyKcal == 6)
    }

    @Test func anAppRestartCarriesOnWithTheSameWalk() throws {
        let first = recorder()
        let start = pad(distance: 200, seconds: 100, kcal: 10)
        first.begin(with: start)
        let began = clock.now
        let middle = walk(first, from: start, seconds: 60)
        let stepsSoFar = first.steps

        // The app is killed and relaunched five minutes later; the belt kept running.
        clock.advance(300)
        let second = recorder()
        #expect(!second.hasWalk)
        #expect(second.restore())
        #expect(second.walkStart == began)
        #expect(second.steps == stepsSoFar)
        #expect(second.distanceMeters(in: middle) == 48)

        let end = walk(second, from: middle, seconds: 30)
        let saved = try finished(second.finish(data: end, model: model))
        #expect(saved.start == began)
        #expect(saved.distanceMeters == 72)
        #expect(saved.steps > stepsSoFar)
    }

    @Test func onlyAPausedWalkIsRestoredWhenAskedForOne() {
        let first = recorder()
        let start = pad(distance: 0, seconds: 0)
        first.begin(with: start)
        walk(first, from: start, seconds: 40)
        #expect(!recorder().restore(onlyIfPaused: true))

        _ = first.pause()
        let second = recorder()
        #expect(second.restore(onlyIfPaused: true))
        #expect(second.isPaused)
    }

    @Test func anOldWalkIsNotRestoredButStillSavedWithItsLastValues() throws {
        let first = recorder()
        let start = pad(distance: 1000, seconds: 500, kcal: 40)
        first.begin(with: start)
        let began = clock.now
        walk(first, from: start, seconds: 120)
        let lastSeen = clock.now

        // Killed mid-walk and opened again the next day, with the pad's counters far ahead.
        clock.advance(20 * 3600)
        let second = recorder()
        #expect(!second.restore())
        let saved = try finished(second.finish(data: pad(distance: 9000, seconds: 4000, kcal: 500), model: model))
        #expect(saved.start == began)
        #expect(saved.end == lastSeen)
        #expect(saved.distanceMeters == 96)
        #expect(saved.energyKcal == 24)

        // It is saved once only.
        #expect(recorder().finish(data: pad(distance: 9000, seconds: 4000), model: model) == nil)
    }

    @Test func aDemoWalkIsNeitherKeptOnDiskNorHandedOn() {
        let r = recorder()
        r.isDemo = true
        let start = pad(distance: 0, seconds: 0)
        r.begin(with: start)
        let end = walk(r, from: start, seconds: 120)
        #expect(r.hasWalk)
        #expect(!recorder().restore())
        #expect(r.finish(data: end, model: model) == nil)
        #expect(!r.hasWalk)
    }

    @Test func resettingTheCountersKeepsTheOpenWalk() {
        let r = recorder()
        let start = pad(distance: 300, seconds: 200)
        r.begin(with: start)
        let end = walk(r, from: start, seconds: 30)
        r.resetCounters()
        #expect(r.hasWalk)
        #expect(r.steps == 0)
        #expect(r.distanceMeters(in: end) == 0)
    }

    @Test func quickSpeedsFollowThePadsRange() {
        #expect(SpeedRange.sportstechPad.quickSpeeds() == [1, 2, 3, 4, 5, 6])
        #expect(SpeedRange(min: 0.5, max: 3.5, step: 0.5).quickSpeeds() == [1, 1.5, 2, 2.5, 3, 3.5])
        #expect(SpeedRange(min: 1, max: 12, step: 0.1).quickSpeeds() == [1, 3, 5, 7, 9, 11])
        #expect(SpeedRange(min: 0.4, max: 0.8, step: 0.1).quickSpeeds() == [0.4])
    }
}

@MainActor @Suite struct WalkSegmentTests {
    private let clock = Clock()
    private let defaults = UserDefaults(suiteName: "WalkSegmentTests-\(UUID().uuidString)")!
    private let model = StepModel(referenceStepLength: 0.70)

    private func recorder() -> WalkRecorder {
        let clock = clock
        return WalkRecorder(defaults: defaults, now: { clock.now })
    }

    private func pad(distance: Int, seconds: Int, kcal: Int = 0) -> TreadmillData {
        var d = TreadmillData()
        d.totalDistanceMeters = distance
        d.elapsedSeconds = seconds
        d.energyTotalKcal = kcal
        d.speedKmh = 3.0
        return d
    }

    @discardableResult
    private func walk(_ r: WalkRecorder, from start: TreadmillData, seconds: Int) -> TreadmillData {
        var d = start
        for _ in 0..<(seconds / 5) {
            clock.advance(5)
            d.totalDistanceMeters! += 4
            d.elapsedSeconds! += 5
            d.energyTotalKcal! += 1
            r.ingest(d, model: model)
        }
        return d
    }

    private func finished(_ r: WalkRecorder, _ data: TreadmillData) -> WalkSession? {
        if case .walk(let w) = r.finish(data: data, model: model) { return w }
        return nil
    }

    @Test func aWalkIsSplitIntoMinutesThatAddUpToTheTotals() throws {
        let r = recorder()
        let start = pad(distance: 1000, seconds: 100, kcal: 50)
        r.begin(with: start)
        let end = walk(r, from: start, seconds: 150)
        let w = try #require(finished(r, end))
        let segments = try #require(w.segments)

        #expect(segments.map(\.seconds) == [60, 60, 30])
        #expect(segments.map(\.distanceMeters) == [48, 48, 24])
        #expect(segments.reduce(0) { $0 + $1.distanceMeters } == w.distanceMeters)
        #expect(segments.reduce(0) { $0 + $1.energyKcal } == w.energyKcal)
        #expect(segments.first?.start == w.start)
        #expect(segments.last?.end == w.end)
        #expect(abs(segments[0].speedKmh - 2.88) < 0.001)
        #expect(w.segmentStepCounts.reduce(0, +) == w.steps)
    }

    @Test func noSegmentCoversAPause() throws {
        let r = recorder()
        let start = pad(distance: 0, seconds: 0)
        r.begin(with: start)
        let middle = walk(r, from: start, seconds: 90)
        _ = r.pause()
        let pausedAt = clock.now
        clock.advance(300)
        _ = r.resume()
        let resumedAt = clock.now
        let end = walk(r, from: middle, seconds: 40)
        let w = try #require(finished(r, end))
        let segments = try #require(w.segments)

        #expect(segments.map(\.seconds) == [60, 30, 40])
        #expect(segments[1].end == pausedAt)
        #expect(segments[2].start == resumedAt)
        #expect(!segments.contains { $0.start < resumedAt && $0.end > pausedAt })
        #expect(segments.reduce(0) { $0 + $1.distanceMeters } == w.distanceMeters)
    }

    @Test func theBeltRunningOnAfterStopGoesToTheLastSegment() throws {
        let r = recorder()
        let start = pad(distance: 0, seconds: 0)
        r.begin(with: start)
        var end = walk(r, from: start, seconds: 60)
        _ = r.pause()
        end.totalDistanceMeters! += 3   // ramping down after the pause began
        let w = try #require(finished(r, end))
        let segments = try #require(w.segments)
        #expect(w.distanceMeters == 51)
        #expect(segments.reduce(0) { $0 + $1.distanceMeters } == 51)
    }

    @Test func segmentsSurviveAnAppRestart() throws {
        let first = recorder()
        let start = pad(distance: 0, seconds: 0)
        first.begin(with: start)
        let middle = walk(first, from: start, seconds: 70)
        let second = recorder()
        #expect(second.restore())
        let end = walk(second, from: middle, seconds: 60)
        let w = try #require(finished(second, end))
        let segments = try #require(w.segments)
        #expect(segments.count == 3)
        #expect(segments.reduce(0) { $0 + $1.distanceMeters } == w.distanceMeters)
        #expect(segments.first?.start == w.start)
    }

    @Test func wholeStepsAddUpEvenWhenEachMinuteIsFractional() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let segments = (0..<7).map { i in
            WalkSegment(start: t + Double(i) * 60, end: t + Double(i + 1) * 60, distanceMeters: 50, energyKcal: 2, steps: 71.43)
        }
        let w = WalkSession(start: t, end: t + 420, distanceMeters: 350, energyKcal: 14, steps: 500, segments: segments)
        #expect(w.segmentStepCounts.reduce(0, +) == 500)
        #expect(w.segmentStepCounts.allSatisfy { (71...72).contains($0) })
        #expect(WalkSession(start: t, end: t + 60, distanceMeters: 1, energyKcal: 0, steps: 3).segmentStepCounts.isEmpty)
    }
}

@Suite struct MilesPerHourTests {
    private let mile = SpeedRange.kmPerMile

    @Test func quickSpeedsInMphAreHalvesOnASlowPad() {
        #expect(SpeedRange.sportstechPad.quickSpeeds(kmPerUnit: mile) == [1, 1.5, 2, 2.5, 3, 3.5])
        #expect(SpeedRange(min: 1, max: 12, step: 0.1).quickSpeeds(kmPerUnit: mile) == [1, 3, 5, 7])
    }

    @Test func plusAndMinusLandOnRoundTenthsOfAMile() {
        let pad = SpeedRange.sportstechPad
        // 3.0 km/h is 1.86 mph, shown as 1.9; one step up is 2.0 mph, which the pad can do as 3.2 km/h.
        #expect(pad.stepped(from: 3.0, by: 0.1, kmPerUnit: mile) == 3.2)
        #expect(pad.stepped(from: 3.2, by: 0.1, kmPerUnit: mile) == 3.4)
        #expect(pad.stepped(from: 3.0, by: -0.1, kmPerUnit: mile) == 2.9)
        #expect(pad.stepped(from: 6.0, by: 0.1, kmPerUnit: mile) == 6.0)
        #expect(pad.stepped(from: 3.0, by: 0.1, kmPerUnit: 1) == pad.stepped(from: 3.0, by: 0.1))
    }

    @Test func aCoarsePadStillMovesOneOfItsSteps() {
        let coarse = SpeedRange(min: 1, max: 6, step: 0.5)
        #expect(coarse.stepped(from: 2.0, by: 0.1, kmPerUnit: mile) == 2.5)
        #expect(coarse.stepped(from: 2.0, by: -0.1, kmPerUnit: mile) == 1.5)
    }
}
