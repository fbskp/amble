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

    /// Clamps to the range and snaps to the step size.
    public func normalized(_ kmh: Double) -> Double {
        let clamped = Swift.max(min, Swift.min(max, kmh))
        let snapped = min + ((clamped - min) / step).rounded() * step
        return (snapped * 100).rounded() / 100
    }
}
