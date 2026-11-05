import Foundation
import Testing
@testable import AmbleCore

private func bytes(_ hex: String) -> Data {
    Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
}

@Suite struct TreadmillDataTests {
    // Captured from the pad with the probe tool, belt running at 3.0 km/h.
    @Test func decodesRunningPacket() throws {
        let d = try #require(TreadmillData(data: bytes("84 05 2c 01 93 00 00 06 00 31 00 00 00 e3 01")))
        #expect(d.speedKmh == 3.0)
        #expect(d.totalDistanceMeters == 147)
        #expect(d.energyTotalKcal == 6)
        #expect(d.energyPerHourKcal == 49)
        #expect(d.energyPerMinuteKcal == 0)
        #expect(d.heartRateBPM == nil) // 0 bpm means no sensor
        #expect(d.elapsedSeconds == 483)
        #expect(d.inclinationPercent == nil)
    }

    @Test func decodesIdlePacket() throws {
        let d = try #require(TreadmillData(data: bytes("84 05 00 00 79 00 00 05 00 2c 00 00 00 b4 01")))
        #expect(d.speedKmh == 0)
        #expect(d.totalDistanceMeters == 121)
        #expect(d.elapsedSeconds == 436)
    }

    @Test func decodesSlowSpeed() throws {
        let d = try #require(TreadmillData(data: bytes("84 05 64 00 1f 00 00 01 00 2a 00 00 00 6e 00")))
        #expect(d.speedKmh == 1.0)
        #expect(d.totalDistanceMeters == 31)
        #expect(d.elapsedSeconds == 110)
    }

    @Test func rejectsTruncatedPacket() {
        #expect(TreadmillData(data: bytes("84 05 2c 01 93 00")) == nil)
        #expect(TreadmillData(data: bytes("84")) == nil)
        #expect(TreadmillData(data: Data()) == nil)
    }

    @Test func decodesInclinationAndMoreDataFlag() throws {
        // flags 0x000B: bit0 (more data, so no speed), bit1 average speed, bit3 inclination.
        let d = try #require(TreadmillData(data: bytes("0b 00 c8 00 0a 00 00 00")))
        #expect(d.speedKmh == nil)
        #expect(d.averageSpeedKmh == 2.0)
        #expect(d.inclinationPercent == 1.0)
    }
}

@Suite struct ControlTests {
    // Encodings verified against the real pad with the probe tool.
    @Test func encodesCommands() {
        #expect(FTMSCommand.requestControl.encoded == bytes("00"))
        #expect(FTMSCommand.start.encoded == bytes("07"))
        #expect(FTMSCommand.stop.encoded == bytes("08 01"))
        #expect(FTMSCommand.pause.encoded == bytes("08 02"))
        #expect(FTMSCommand.reset.encoded == bytes("01"))
        #expect(FTMSCommand.setTargetSpeed(kmh: 2.0).encoded == bytes("02 c8 00"))
        #expect(FTMSCommand.setTargetSpeed(kmh: 1.0).encoded == bytes("02 64 00"))
        #expect(FTMSCommand.setTargetSpeed(kmh: 2.55).encoded == bytes("02 ff 00"))
    }

    @Test func decodesResponses() throws {
        let ok = try #require(ControlPointResponse(data: bytes("80 07 01")))
        #expect(ok.requestOpcode == 0x07)
        #expect(ok.result == .success)
        let denied = try #require(ControlPointResponse(data: bytes("80 02 05")))
        #expect(denied.result == .controlNotPermitted)
        #expect(ControlPointResponse(data: bytes("80 07")) == nil)
        #expect(ControlPointResponse(data: bytes("07 07 01")) == nil)
    }

    @Test func decodesSpeedRange() throws {
        let r = try #require(SpeedRange(data: bytes("64 00 58 02 0a 00")))
        #expect(r == .sportstechPad)
    }

    @Test func normalizesSpeed() {
        let r = SpeedRange.sportstechPad
        #expect(r.normalized(0.2) == 1.0)
        #expect(r.normalized(9.0) == 6.0)
        #expect(r.normalized(2.34) == 2.3)
        #expect(r.normalized(2.36) == 2.4)
    }
}

@Suite struct StatusTests {
    @Test func decodesTrainingStatus() {
        #expect(TrainingStatus(data: bytes("01 01")) == .idle)
        #expect(TrainingStatus(data: bytes("01 0e")) == .preWorkout)
        #expect(TrainingStatus(data: bytes("01 0d")) == .manualMode)
        #expect(TrainingStatus(data: bytes("01 0f")) == .postWorkout)
        #expect(TrainingStatus(data: bytes("01")) == nil)
    }

    @Test func decodesMachineStatus() {
        #expect(MachineStatus(data: bytes("04")) == .started)
        #expect(MachineStatus(data: bytes("02 01")) == .stopped)
        #expect(MachineStatus(data: bytes("02 02")) == .paused)
        #expect(MachineStatus(data: bytes("05 c8 00")) == .targetSpeedChanged(kmh: 2.0))
        #expect(MachineStatus(data: Data()) == nil)
    }
}

@Suite struct FTMSFeaturesTests {
    @Test func decodesFlags() throws {
        // machine: total distance, energy, elapsed time; target: speed.
        let f = try #require(FTMSFeatures(data: bytes("04 12 00 00 01 00 00 00")))
        #expect(f.reportsTotalDistance)
        #expect(f.reportsEnergy)
        #expect(f.reportsElapsedTime)
        #expect(!f.reportsStepCount)
        #expect(!f.reportsHeartRate)
        #expect(f.canSetSpeed)
        #expect(!f.canSetInclination)
    }

    @Test func rejectsShortData() {
        #expect(FTMSFeatures(data: bytes("04 12 00")) == nil)
    }
}

@Suite struct TreadmillDataMergeTests {
    @Test func missingFieldsKeepTheirLastValue() {
        var first = TreadmillData()
        first.speedKmh = 3
        var second = TreadmillData()
        second.totalDistanceMeters = 120
        let merged = second.merged(over: first)
        #expect(merged.speedKmh == 3)
        #expect(merged.totalDistanceMeters == 120)
        var third = TreadmillData()
        third.speedKmh = 4
        #expect(third.merged(over: merged).speedKmh == 4)
        #expect(third.merged(over: merged).totalDistanceMeters == 120)
    }
}

@Suite struct SpeedStepTests {
    @Test func coarsePadStillMoves() {
        let coarse = SpeedRange(min: 1, max: 6, step: 0.5)
        #expect(coarse.stepped(from: 2, by: 0.1) == 2.5)
        #expect(coarse.stepped(from: 2, by: -0.1) == 1.5)
    }

    @Test func finePadUsesTheRequestedStepAndStaysInRange() {
        let fine = SpeedRange.sportstechPad
        #expect(fine.stepped(from: 2, by: 0.1) == 2.1)
        #expect(fine.stepped(from: 6, by: 0.1) == 6)
        #expect(fine.stepped(from: 1, by: -0.1) == 1)
        #expect(fine.stepped(from: 0, by: 0.1) == 1)   // belt still in the countdown
    }
}

@Suite struct StepModelTests {
    private let model = StepModel(heightMeters: 1.73)

    @Test func heightRule() {
        #expect(model.referenceStepLength == 0.714)
    }

    @Test func stepLengthAtNormalPaceIsTheReference() {
        #expect(abs(model.stepLength(atSpeedKmh: StepModel.referenceSpeedKmh) - 0.714) < 1e-9)
    }

    @Test func slowerWalkingMeansShorterAndMoreFrequentSteps() {
        let speeds = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let lengths = speeds.map { model.stepLength(atSpeedKmh: $0) }
        let cadences = speeds.map { model.cadence(atSpeedKmh: $0) }
        #expect(lengths == lengths.sorted())
        #expect(cadences == cadences.sorted())
        // Plausible values for a 1.73 m adult (gait studies: about 70-75 steps/min at 2 km/h, ~100 at 4 km/h).
        #expect((70...78).contains(model.cadence(atSpeedKmh: 2)))
        #expect((97...103).contains(model.cadence(atSpeedKmh: 4)))
        #expect((0.42...0.49).contains(model.stepLength(atSpeedKmh: 2)))
    }

    @Test func stepsPerDistance() {
        // At 2 km/h a metre needs more steps than at 5 km/h.
        #expect(model.steps(forDistance: 1000, atSpeedKmh: 2) > 2000)
        #expect(model.steps(forDistance: 1000, atSpeedKmh: 5) < 1450)
        #expect(model.steps(forDistance: -5, atSpeedKmh: 3) == 0)
    }

    @Test func extremeInputsStaySane() {
        let tiny = StepModel(referenceStepLength: 0.1)
        let huge = StepModel(referenceStepLength: 3)
        #expect(tiny.referenceStepLength == 0.4)
        #expect(huge.referenceStepLength == 1.0)
        #expect(model.stepLength(atSpeedKmh: 0) > 0)
        #expect(model.cadence(atSpeedKmh: 0) >= StepModel.lowestCadence)
    }
}

@Suite struct StepCounterTests {
    private let model = StepModel(heightMeters: 1.73)

    @Test func constantSpeedMatchesTheModel() {
        var counter = StepCounter(startingAtDistance: 0, speedKmh: 3)
        for metre in 1...100 { counter.add(distanceMeters: metre, speedKmh: 3, model: model) }
        #expect(abs(counter.steps - model.steps(forDistance: 100, atSpeedKmh: 3)) < 0.01)
    }

    @Test func speedChangesAreFollowed() {
        var counter = StepCounter(startingAtDistance: 0, speedKmh: 2)
        for metre in 1...50 { counter.add(distanceMeters: metre, speedKmh: 2, model: model) }
        for metre in 51...100 { counter.add(distanceMeters: metre, speedKmh: 4, model: model) }
        let expected = model.steps(forDistance: 50, atSpeedKmh: 2) + model.steps(forDistance: 50, atSpeedKmh: 4)
        // The metre at the change uses the average of both speeds.
        #expect(abs(counter.steps - expected) < 1.0)
    }

    @Test func counterResetAndMissingDataAreIgnored() {
        var counter = StepCounter(startingAtDistance: 100, speedKmh: 3)
        counter.add(distanceMeters: 110, speedKmh: 3, model: model)
        let before = counter.steps
        counter.add(distanceMeters: 5, speedKmh: 3, model: model)     // pad restarted its counter
        counter.add(distanceMeters: nil, speedKmh: 3, model: model)   // packet without distance
        #expect(counter.steps == before)
        counter.add(distanceMeters: 15, speedKmh: 3, model: model)    // counting continues from the new base
        #expect(counter.steps > before)
    }

    @Test func firstPacketOnlySetsTheStart() {
        var counter = StepCounter()
        counter.add(distanceMeters: 500, speedKmh: 3, model: model)
        #expect(counter.steps == 0)
    }

    @Test func survivesSavingAndRestoring() throws {
        var counter = StepCounter(startingAtDistance: 0, speedKmh: 3)
        for metre in 1...20 { counter.add(distanceMeters: metre, speedKmh: 3, model: model) }
        let restored = try JSONDecoder().decode(StepCounter.self, from: JSONEncoder().encode(counter))
        #expect(restored == counter)
    }
}

