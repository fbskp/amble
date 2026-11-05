import Foundation

/// Fitness Machine Feature (0x2ACC): what the pad says it can report and what it lets a client set.
/// 8 bytes: machine features (uint32 LE) followed by target setting features (uint32 LE).
public struct FTMSFeatures: Equatable, Sendable {
    public let machine: UInt32
    public let targetSettings: UInt32

    public init(machine: UInt32, targetSettings: UInt32) {
        self.machine = machine
        self.targetSettings = targetSettings
    }

    public init?(data: Data) {
        var r = ByteReader(data)
        guard let m = r.u32(), let t = r.u32() else { return nil }
        self.init(machine: m, targetSettings: t)
    }

    private func machineHas(_ bit: Int) -> Bool { machine & (1 << UInt32(bit)) != 0 }
    private func targetHas(_ bit: Int) -> Bool { targetSettings & (1 << UInt32(bit)) != 0 }

    // Machine features (Bluetooth FTMS spec, table 4.2).
    public var reportsAverageSpeed: Bool { machineHas(0) }
    public var reportsTotalDistance: Bool { machineHas(2) }
    public var reportsStepCount: Bool { machineHas(6) }
    public var reportsEnergy: Bool { machineHas(9) }
    public var reportsHeartRate: Bool { machineHas(10) }
    public var reportsElapsedTime: Bool { machineHas(12) }

    // Target setting features (table 4.4).
    public var canSetSpeed: Bool { targetHas(0) }
    public var canSetInclination: Bool { targetHas(1) }
}
