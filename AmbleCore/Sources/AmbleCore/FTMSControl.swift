import Foundation

/// Standard Bluetooth SIG UUIDs used by the pad.
public enum FTMSUUID {
    public static let service = "1826"
    public static let treadmillData = "2ACD"
    public static let feature = "2ACC"
    public static let supportedSpeedRange = "2AD4"
    public static let trainingStatus = "2AD3"
    public static let machineStatus = "2ADA"
    public static let controlPoint = "2AD9"
}

/// Commands written to the Fitness Machine Control Point (0x2AD9).
public enum FTMSCommand: Equatable, Sendable {
    case requestControl
    case reset
    case setTargetSpeed(kmh: Double)
    case start
    case stop
    case pause

    public var encoded: Data {
        switch self {
        case .requestControl: return Data([0x00])
        case .reset: return Data([0x01])
        case .setTargetSpeed(let kmh):
            // uint16, resolution 0.01 km/h, little-endian.
            let raw = UInt16(max(0, min((kmh * 100).rounded(), Double(UInt16.max))))
            return Data([0x02, UInt8(raw & 0xFF), UInt8(raw >> 8)])
        case .start: return Data([0x07])
        case .stop: return Data([0x08, 0x01])
        case .pause: return Data([0x08, 0x02])
        }
    }

    /// The opcode byte, used to match a response to its request.
    public var opcode: UInt8 { encoded[0] }
}

/// Indication received on the Control Point after a write: `80 <request opcode> <result>`.
public struct ControlPointResponse: Equatable, Sendable {
    public enum Result: UInt8, Sendable {
        case success = 0x01, notSupported = 0x02, invalidParameter = 0x03
        case operationFailed = 0x04, controlNotPermitted = 0x05
    }
    public let requestOpcode: UInt8
    public let result: Result?
    public let rawResult: UInt8

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == 0x80 else { return nil }
        requestOpcode = b[1]
        rawResult = b[2]
        result = Result(rawValue: b[2])
    }
}

/// Supported Speed Range (0x2AD4): min, max, increment in km/h.
public struct SpeedRange: Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var step: Double

    /// The range reported by the Sportstech pad (1.0 to 6.0 km/h in 0.1 steps).
    public static let sportstechPad = SpeedRange(min: 1.0, max: 6.0, step: 0.1)

    public init(min: Double, max: Double, step: Double) {
        self.min = min; self.max = max; self.step = step
    }

    public init?(data: Data) {
        var r = ByteReader(data)
        guard let lo = r.u16(), let hi = r.u16(), let inc = r.u16(), inc > 0 else { return nil }
        self.init(min: Double(lo) / 100, max: Double(hi) / 100, step: Double(inc) / 100)
    }

    /// One press of a speed button: at least the pad's own step, so a pad with coarser steps still moves.
    public func stepped(from base: Double, by delta: Double) -> Double {
        let size = Swift.max(abs(delta), step)
        return normalized(base + (delta < 0 ? -size : size))
    }

    /// Kilometres in one mile, for showing speeds in mph.
    public static let kmPerMile = 1.609344

    /// Round speeds inside the range for quick-pick buttons, in the unit shown (`kmPerUnit` 1 for km/h,
    /// `kmPerMile` for mph). Whole values, or halves when there would be fewer than four whole ones;
    /// thinned out evenly when there are more than `limit`.
    public func quickSpeeds(limit: Int = 6, kmPerUnit: Double = 1) -> [Double] {
        let low = min / kmPerUnit, high = max / kmPerUnit
        func values(every size: Double) -> [Double] {
            var result: [Double] = []
            var v = Swift.max(1, (low / size).rounded(.up) * size)
            while v <= high + 1e-9 { result.append(v); v += size }
            return result
        }
        var all = values(every: 1)
        if all.count < 4 { all = values(every: 0.5) }
        guard !all.isEmpty else { return [(normalized(min) / kmPerUnit * 10).rounded() / 10] }
        let every = Swift.max(1, Int((Double(all.count) / Double(Swift.max(1, limit))).rounded(.up)))
        return Swift.stride(from: 0, to: all.count, by: every).map { all[$0] }
    }

    /// One press of a speed button in the unit shown. In mph the target is the next round tenth of a mile per
    /// hour, as close as the pad's own steps allow; the pad always moves at least one of its steps.
    public func stepped(from base: Double, by delta: Double, kmPerUnit: Double) -> Double {
        guard kmPerUnit != 1, delta != 0 else { return stepped(from: base, by: delta) }
        let grid = abs(delta)
        let shown = (base / kmPerUnit / grid).rounded() * grid
        let target = normalized((shown + delta) * kmPerUnit)
        return target == normalized(base) ? stepped(from: base, by: delta) : target
    }

    /// Clamps to the range and snaps to the step size.
    public func normalized(_ kmh: Double) -> Double {
        let clamped = Swift.max(min, Swift.min(max, kmh))
        let snapped = min + ((clamped - min) / step).rounded() * step
        return (snapped * 100).rounded() / 100
    }
}
