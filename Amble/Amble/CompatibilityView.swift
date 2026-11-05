import SwiftUI
import AmbleCore

/// Shows what the connected pad supports, and lets users copy a report to share compatibility results.
struct CompatibilityView: View {
    let pad: PadConnection
    @State private var copied = false

    var body: some View {
        Form {
            if pad.isDemo {
                Section {
                    Text("Demo mode uses a simulated pad, so there is nothing to report. Connect a real pad to see what it supports.")
                }
            } else if pad.state == .connected {
                Section("Pad") {
                    LabeledContent("Name", value: pad.deviceName ?? "Unknown")
                    if let range = pad.speedRange {
                        LabeledContent("Speed range", value: String(localized: "\(Self.number(range.min)) to \(Self.number(range.max)) km/h, step \(Self.number(range.step))"))
                    }
                }
                Section {
                    row("Set speed", pad.features?.canSetSpeed)
                    row("Pause", pad.pauseSupported ? (pad.pauseConfirmed ? true : nil) : false, unknown: "Not tried yet")
                    row("Distance", pad.features?.reportsTotalDistance)
                    row("Energy", pad.features?.reportsEnergy)
                    row("Elapsed time", pad.features?.reportsElapsedTime)
                    row("Step count", pad.features?.reportsStepCount)
                } header: {
                    Text("What this pad reports")
                } footer: {
                    Text("Amble works with pads that follow the standard Bluetooth fitness protocol (FTMS). It has only been verified with one pad model, so others may work only partly. Pads without a step count are normal: Amble estimates steps from distance.")
                }
                Section {
                    Button(copied ? "Copied" : "Copy report") {
                        UIPasteboard.general.string = pad.compatibilityReport
                        copied = true
                    }
                    if let url = Compatibility.reportURL {
                        Link("Share your result on GitHub", destination: url)
                    }
                } footer: {
                    Text("The report contains the pad's name and capabilities, your iOS version and the app version. Nothing else.")
                }
            } else {
                ContentUnavailableView("No pad connected", systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text("Connect a pad to see what it supports."))
            }
        }
        .navigationTitle("Pad compatibility")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// `value` nil means unknown; `unknown` is the text shown then.
    private static func number(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }

    private func row(_ title: LocalizedStringKey, _ value: Bool?, unknown: LocalizedStringKey = "Not reported") -> some View {
        LabeledContent(title) {
            // A plain icon and text, not a Label: a Label in this spot made the rows too tall and broke the separators.
            switch value {
            case true?: result("checkmark.circle.fill", "Yes", .green)
            case false?: result("xmark.circle.fill", "No", .red)
            case nil: Text(unknown).foregroundStyle(.secondary)
            }
        }
    }

    private func result(_ symbol: String, _ text: LocalizedStringKey, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

enum Compatibility {
    static let repositoryURL: String? = Links.repository

    static var reportURL: URL? {
        repositoryURL.flatMap { URL(string: $0 + "/issues/new?template=compatibility.md") }
    }
}

extension PadConnection {
    /// Markdown for a GitHub issue or COMPATIBILITY.md row. Contains no identifiers.
    var compatibilityReport: String {
        func yesNo(_ v: Bool?) -> String { v.map { $0 ? "yes" : "no" } ?? "not reported" }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "Pad: \(deviceName ?? "unknown")",
            "Amble: \(version) (\(build))",
            "iOS: \(UIDevice.current.systemVersion)",
            "Set speed: \(yesNo(features?.canSetSpeed))",
            "Pause: \(pauseSupported ? (pauseConfirmed ? "works" : "not tried") : "rejected by the pad")",
            "Distance: \(yesNo(features?.reportsTotalDistance))",
            "Energy: \(yesNo(features?.reportsEnergy))",
            "Elapsed time: \(yesNo(features?.reportsElapsedTime))",
            "Step count: \(yesNo(features?.reportsStepCount))",
        ]
        if let r = speedRange {
            lines.append(String(format: "Speed range: %.1f to %.1f km/h, step %.1f", r.min, r.max, r.step))
        }
        return lines.joined(separator: "\n")
    }
}
