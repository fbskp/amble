import Foundation
import SwiftUI

/// Which units Amble shows. The pad itself always works in km/h; only the display changes.
enum UnitChoice: String, CaseIterable, Identifiable {
    case automatic, metric, imperial
    var id: String { rawValue }
}

/// Metric (m, km, km/h, cm) or imperial (ft, mi, mph, in), from the user's choice or, by default, the region.
/// Shared by the app and the Live Activity, which therefore read the choice from the App Group.
struct Units: Equatable {
    let isMetric: Bool

    static let choiceKey = "units"
    /// UserDefaults is thread-safe, so sharing one instance is fine even though the type is not marked Sendable.
    nonisolated(unsafe) static let store = UserDefaults(suiteName: GoalsSnapshotStore.appGroup) ?? .standard
    /// Same value as `SpeedRange.kmPerMile` in AmbleCore, which the widgets do not link.
    static let kmPerMile = 1.609344

    init(isMetric: Bool) { self.isMetric = isMetric }

    init(choice: UnitChoice, locale: Locale = .current) {
        switch choice {
        case .metric: isMetric = true
        case .imperial: isMetric = false
        case .automatic: isMetric = locale.measurementSystem == .metric
        }
    }

    static var current: Units {
        Units(choice: UnitChoice(rawValue: store.string(forKey: choiceKey) ?? "") ?? .automatic)
    }

    // MARK: Speed

    /// Kilometres per unit of speed shown: 1 for km/h, a mile for mph.
    var kmPerSpeedUnit: Double { isMetric ? 1 : Self.kmPerMile }
    var speedSymbol: String { isMetric ? "km/h" : "mph" }
    func speed(_ kmh: Double) -> Double { kmh / kmPerSpeedUnit }
    /// One decimal, in the user's number format (3,5 in German).
    func speedValue(_ kmh: Double) -> String { speed(kmh).formatted(.number.precision(.fractionLength(1))) }
    func speedText(_ kmh: Double) -> String { "\(speedValue(kmh)) \(speedSymbol)" }

    // MARK: Lengths

    /// Whole metres below 1 km and kilometres with two decimals above; in imperial, whole feet below
    /// a tenth of a mile and miles with two decimals above.
    func distance(_ meters: Double) -> String {
        if isMetric {
            return meters < 1000 ? "\(Int(meters.rounded())) m"
                : "\((meters / 1000).formatted(.number.precision(.fractionLength(2)))) km"
        }
        let miles = meters / (Self.kmPerMile * 1000)
        return miles < 0.1 ? "\(Int((meters / 0.3048).rounded())) ft"
            : "\(miles.formatted(.number.precision(.fractionLength(2)))) mi"
    }

    /// A step length: centimetres, or inches.
    func stepLength(cm: Double) -> String {
        isMetric ? "\(Int(cm.rounded())) cm" : "\(Int((cm / 2.54).rounded())) in"
    }

    /// A body height: centimetres, or feet and inches.
    func height(cm: Double) -> String {
        guard !isMetric else { return "\(Int(cm.rounded())) cm" }
        let inches = Int((cm / 2.54).rounded())
        return "\(inches / 12) ft \(inches % 12) in"
    }

    /// What one press of a length stepper adds: a centimetre, or an inch.
    var lengthStepCm: Double { isMetric ? 1 : 2.54 }
}

extension EnvironmentValues {
    @Entry var units: Units = .current
}
