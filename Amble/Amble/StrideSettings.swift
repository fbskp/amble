import Foundation
import Observation
import AmbleCore

/// Where the step length comes from, and its saved value.
/// Order of preference on first launch: average walking step length from Apple Health, otherwise height-based.
@MainActor @Observable
final class StrideSettings {
    enum Source: String, CaseIterable, Identifiable {
        case health, height, manual
        var id: String { rawValue }
        var title: String {
            switch self {
            case .health: String(localized: "Apple Health")
            case .height: String(localized: "My height")
            case .manual: String(localized: "Enter step length")
            }
        }
    }

    var source: Source
    var heightCm: Double
    var manualStrideCm: Double
    private(set) var healthStrideMeters: Double?
    private(set) var healthHeightCm: Double?
    private(set) var healthChecked = false
    private(set) var isConfirmed: Bool

    private let defaults = UserDefaults.standard
    private let health = HealthWriter()

    static let defaultHeightCm = 170.0
    static let heightRange: ClosedRange<Double> = 120...220
    static let strideRange: ClosedRange<Double> = 30...100

    init() {
        source = Source(rawValue: defaults.string(forKey: "strideSource") ?? "") ?? .height
        heightCm = defaults.object(forKey: "heightCm") as? Double ?? Self.defaultHeightCm
        manualStrideCm = defaults.object(forKey: "manualStrideCm") as? Double ?? 70
        isConfirmed = defaults.bool(forKey: "strideConfirmed")
    }

    /// Typical walking step length is about 41% of body height.
    var heightBasedStrideMeters: Double { StepModel(heightMeters: heightCm / 100).referenceStepLength }

    /// Step length at a normal walking pace. The step model shortens it for slower belt speeds.
    var strideMeters: Double {
        switch source {
        case .health: healthStrideMeters ?? heightBasedStrideMeters
        case .height: heightBasedStrideMeters
        case .manual: manualStrideCm / 100
        }
    }

    /// True once Health has been checked and the user still has to confirm a value.
    var needsSetup: Bool { healthChecked && !isConfirmed }

    func persist() {
        defaults.set(source.rawValue, forKey: "strideSource")
        defaults.set(heightCm, forKey: "heightCm")
        defaults.set(manualStrideCm, forKey: "manualStrideCm")
        defaults.set(isConfirmed, forKey: "strideConfirmed")
    }

    func confirm() {
        isConfirmed = true
        persist()
    }

    /// Reads step length and height from Health. On the first run, picks the best available source.
    func refreshFromHealth() async {
        let body = await health.readBodyData()
        healthStrideMeters = body.stepLengthMeters
        healthHeightCm = body.heightCm
        healthChecked = true
        if !isConfirmed {
            if body.stepLengthMeters != nil {
                source = .health
                isConfirmed = true   // good data found, no questions needed
            } else {
                source = .height
                if let h = body.heightCm { heightCm = h }
            }
            persist()
        }
    }
}
