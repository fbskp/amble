import Foundation

/// One decoded FTMS Treadmill Data notification (characteristic 0x2ACD).
/// Fields the pad does not send are nil.
public struct TreadmillData: Equatable, Sendable {
    public var speedKmh: Double?
    public var averageSpeedKmh: Double?
    public var totalDistanceMeters: Int?
    public var inclinationPercent: Double?
    public var rampAngleDegrees: Double?
    public var energyTotalKcal: Int?
    public var energyPerHourKcal: Int?
    public var energyPerMinuteKcal: Int?
    public var heartRateBPM: Int?
    public var elapsedSeconds: Int?
    public var remainingSeconds: Int?

    public init() {}

    /// This packet on top of earlier values. FTMS pads may split their data over several packets
    /// ("More Data" flag), so a field missing from one packet keeps its last known value.
    public func merged(over previous: TreadmillData) -> TreadmillData {
        var m = self
        m.speedKmh = speedKmh ?? previous.speedKmh
        m.averageSpeedKmh = averageSpeedKmh ?? previous.averageSpeedKmh
        m.totalDistanceMeters = totalDistanceMeters ?? previous.totalDistanceMeters
        m.inclinationPercent = inclinationPercent ?? previous.inclinationPercent
        m.rampAngleDegrees = rampAngleDegrees ?? previous.rampAngleDegrees
        m.energyTotalKcal = energyTotalKcal ?? previous.energyTotalKcal
        m.energyPerHourKcal = energyPerHourKcal ?? previous.energyPerHourKcal
        m.energyPerMinuteKcal = energyPerMinuteKcal ?? previous.energyPerMinuteKcal
        m.heartRateBPM = heartRateBPM ?? previous.heartRateBPM
        m.elapsedSeconds = elapsedSeconds ?? previous.elapsedSeconds
        m.remainingSeconds = remainingSeconds ?? previous.remainingSeconds
        return m
    }

    /// Parses a Treadmill Data packet. Returns nil if the packet is truncated.
    public init?(data: Data) {
        var r = ByteReader(data)
        guard let flags = r.u16() else { return nil }
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }

        // Bit 0 is "More Data": speed is present when it is CLEAR.
        if !has(0) {
            guard let v = r.u16() else { return nil }
            speedKmh = Double(v) / 100
        }
        if has(1) {
            guard let v = r.u16() else { return nil }
            averageSpeedKmh = Double(v) / 100
        }
        if has(2) {
            guard let v = r.u24() else { return nil }
            totalDistanceMeters = Int(v)
        }
        if has(3) {
            guard let incl = r.i16(), let ramp = r.i16() else { return nil }
            inclinationPercent = Double(incl) / 10
            rampAngleDegrees = Double(ramp) / 10
        }
        if has(4) { guard r.u16() != nil, r.u16() != nil else { return nil } } // elevation gain: skipped
        if has(5) { guard r.u8() != nil else { return nil } }                  // instantaneous pace: skipped
        if has(6) { guard r.u8() != nil else { return nil } }                  // average pace: skipped
        if has(7) {
            guard let total = r.u16(), let perHour = r.u16(), let perMin = r.u8() else { return nil }
            // 0xFFFF / 0xFF mean "data not available".
            energyTotalKcal = total == 0xFFFF ? nil : Int(total)
            energyPerHourKcal = perHour == 0xFFFF ? nil : Int(perHour)
            energyPerMinuteKcal = perMin == 0xFF ? nil : Int(perMin)
        }
        if has(8) { guard let v = r.u8() else { return nil }; heartRateBPM = v == 0 ? nil : Int(v) }
        if has(9) { guard r.u8() != nil else { return nil } }                  // metabolic equivalent: skipped
        if has(10) { guard let v = r.u16() else { return nil }; elapsedSeconds = Int(v) }
        if has(11) { guard let v = r.u16() else { return nil }; remainingSeconds = Int(v) }
        // Bit 12 (force on belt / power) is last, so there is no need to consume it.
    }
}
