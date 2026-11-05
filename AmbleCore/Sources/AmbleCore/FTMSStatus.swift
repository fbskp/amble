import Foundation

/// Training Status (0x2AD3): `<flags> <status>`. The status byte is the second byte.
public enum TrainingStatus: Equatable, Sendable {
    case idle            // 0x01
    case manualMode      // 0x0D, belt running (Quick Start)
    case preWorkout      // 0x0E, countdown after Start
    case postWorkout     // 0x0F, belt ramping down
    case other(UInt8)

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        switch b[1] {
        case 0x01: self = .idle
        case 0x0D: self = .manualMode
        case 0x0E: self = .preWorkout
        case 0x0F: self = .postWorkout
        default: self = .other(b[1])
        }
    }
}

/// Fitness Machine Status (0x2ADA).
public enum MachineStatus: Equatable, Sendable {
    case reset
    case stopped      // by user: `02 01`
    case paused       // by user: `02 02`
    case safetyKeyStop
    case started      // `04`
    case targetSpeedChanged(kmh: Double)
    case other(UInt8)

    public init?(data: Data) {
        let b = [UInt8](data)
        guard let op = b.first else { return nil }
        switch op {
        case 0x01: self = .reset
        case 0x02:
            guard b.count >= 2 else { return nil }
            self = b[1] == 0x02 ? .paused : .stopped
        case 0x03: self = .safetyKeyStop
        case 0x04: self = .started
        case 0x05:
            guard b.count >= 3 else { return nil }
            self = .targetSpeedChanged(kmh: Double(UInt16(b[1]) | UInt16(b[2]) << 8) / 100)
        default: self = .other(op)
        }
    }
}
