import Foundation

/// Companions that walk on the belt. The sloth is always available; the others are unlocked by lifetime distance.
public enum AnimalID: String, CaseIterable, Codable, Sendable {
    case sloth, snail, tortoise

    /// Lifetime distance at which the animal joins.
    public var unlockDistanceMeters: Double {
        switch self {
        case .sloth: 0
        case .snail: 10_000
        case .tortoise: 25_000
        }
    }

    /// Animals earned with `distanceMeters` walked in total, in their usual order.
    public static func unlocked(distanceMeters: Double) -> [AnimalID] {
        allCases.filter { distanceMeters >= $0.unlockDistanceMeters }
    }

    /// 0...1 progress towards unlocking (1 when unlocked).
    public func progress(distanceMeters: Double) -> Double {
        guard unlockDistanceMeters > 0 else { return 1 }
        return min(1, max(0, distanceMeters / unlockDistanceMeters))
    }
}
