import SwiftUI
import AmbleCore

struct SettingsView: View {
    @Bindable var stride: StrideSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showNotice = false
    @Bindable private var goalsStore = GoalsStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source", selection: $stride.source) {
                        ForEach(StrideSettings.Source.allCases) { Text($0.title).tag($0) }
                    }
                    switch stride.source {
                    case .health: healthRows
                    case .height: heightRows
                    case .manual: manualRows
                    }
                } header: {
                    Text("Step length")
                } footer: {
                    Text("The pad does not count steps, so Amble estimates them from distance and belt speed: the slower you walk, the shorter and more frequent your steps are. Enter your step length at normal walking pace. Counts stay approximate.")
                }

                Section("Result") {
                    LabeledContent("Step length at normal pace", value: "\(stride.strideMeters.formatted(.number.precision(.fractionLength(2)))) m")
                    LabeledContent("Step length at 3 km/h", value: "\(slowStepLength.formatted(.number.precision(.fractionLength(2)))) m")
                    LabeledContent("Steps per km at 3 km/h", value: "\(Int((1000 / slowStepLength).rounded()))")
                }

                Section {
                    Stepper(value: $goalsStore.goals.walks, in: GoalsStore.walkRange) {
                        Text("Walks per week: \(goalsStore.goals.walks)")
                    }
                    Stepper(value: $goalsStore.goals.minutes, in: GoalsStore.minuteRange, step: 10) {
                        Text("Minutes per week: \(goalsStore.goals.minutes)")
                    }
                } header: {
                    Text("Weekly goals")
                } footer: {
                    Text("A week runs from \(weekdayName) to \(lastWeekdayName). Both goals must be reached to complete it.")
                }

                // Last on purpose: references to read, not things to set.
                Section {
                    NavigationLink("Pad compatibility") { CompatibilityView(pad: PadConnection.shared) }
                    Button("Read the safety notice") { showNotice = true }
                    Link("Privacy policy", destination: Links.privacyPolicy)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: stride.source) { _, _ in stride.persist() }
            .onChange(of: stride.heightCm) { _, _ in stride.persist() }
            .onChange(of: stride.manualStrideCm) { _, _ in stride.persist() }
            .onChange(of: goalsStore.goals) { _, _ in goalsStore.persist() }
            .onDisappear { stride.confirm() }
            .sheet(isPresented: $showNotice) {
                NavigationStack {
                    ScrollView { SafetyNoticeCard().padding() }
                        .navigationTitle("Safety")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showNotice = false } } }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder private var healthRows: some View {
        if let s = stride.healthStrideMeters {
            LabeledContent("Average in Health", value: "\(s.formatted(.number.precision(.fractionLength(2)))) m")
        } else {
            Text("No walking step length found in Apple Health. It needs an iPhone or Apple Watch that has recorded walks, and read access for Amble. Until then your height is used.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Button("Read from Apple Health again") { Task { await stride.refreshFromHealth() } }
        if stride.healthStrideMeters == nil { heightRows }
    }

    @ViewBuilder private var heightRows: some View {
        Stepper(value: $stride.heightCm, in: StrideSettings.heightRange, step: 1) {
            Text("Height: \(Int(stride.heightCm)) cm")
        }
        if let h = stride.healthHeightCm {
            Button("Use height from Health (\(Int(h)) cm)") { stride.heightCm = h.rounded() }
        }
        Text("Suggested: about 41% of your height.").font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var manualRows: some View {
        Stepper(value: $stride.manualStrideCm, in: StrideSettings.strideRange, step: 1) {
            Text("Step length: \(Int(stride.manualStrideCm)) cm")
        }
        Text("Typical adults: 60 to 80 cm at normal walking pace. Walk a known distance at that pace and divide it by your steps.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private var slowStepLength: Double {
        StepModel(referenceStepLength: stride.strideMeters).stepLength(atSpeedKmh: 3)
    }

    private var weekdayName: String {
        let c = Calendar.current
        return c.weekdaySymbols[c.firstWeekday - 1]
    }

    private var lastWeekdayName: String {
        let c = Calendar.current
        return c.weekdaySymbols[(c.firstWeekday + 5) % 7]
    }
}
