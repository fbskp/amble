import SwiftUI
import AmbleCore

struct SettingsView: View {
    @Bindable var stride: StrideSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showNotice = false
    @Bindable private var goalsStore = GoalsStore.shared
    @Bindable private var pad = PadConnection.shared
    @AppStorage(Units.choiceKey, store: Units.store) private var unitChoice: UnitChoice = .automatic
    private var units: Units { Units(choice: unitChoice) }

    var body: some View {
        NavigationStack {
            Form {
                // Every group has a heading. Things to set first, most used at the top; things to read last.
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

                Section {
                    Picker("Units", selection: $unitChoice) {
                        Text("Automatic").tag(UnitChoice.automatic)
                        Text("Metric (km, km/h)").tag(UnitChoice.metric)
                        Text("Imperial (mi, mph)").tag(UnitChoice.imperial)
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Automatic follows your region. The pad itself always works in km/h; Amble only converts what it shows.")
                }

                Section {
                    Toggle("Disconnect automatically", isOn: $pad.disconnectsWhenIdle)
                    NavigationLink("Pad compatibility") { CompatibilityView(pad: PadConnection.shared) }
                } header: {
                    Text("Pad")
                } footer: {
                    Text("Some pads accept only one Bluetooth connection. With this option, Amble disconnects from the pad automatically while in the background, as soon as the pad is switched off or nothing has happened for 10 minutes. Then another device can connect. Opening Amble reconnects.")
                }

                Section {
                    Button("Read the safety notice") { showNotice = true }
                    Link("Privacy policy", destination: Links.privacyPolicy)
                } header: {
                    Text("About")
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
            LabeledContent("Average in Health", value: units.stepLength(cm: s * 100))
        } else {
            Text("No walking step length found in Apple Health. It needs an iPhone or Apple Watch that has recorded walks, and read access for Amble. Until then your height is used.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Button("Read from Apple Health again") { Task { await stride.refreshFromHealth() } }
        if stride.healthStrideMeters == nil { heightRows }
    }

    @ViewBuilder private var heightRows: some View {
        Stepper(value: $stride.heightCm, in: StrideSettings.heightRange, step: units.lengthStepCm) {
            Text("Height: \(units.height(cm: stride.heightCm))")
        }
        if let h = stride.healthHeightCm {
            Button("Use height from Health (\(units.height(cm: h)))") { stride.heightCm = h.rounded() }
        }
        Text("Suggested: about 41% of your height.").font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var manualRows: some View {
        Stepper(value: $stride.manualStrideCm, in: StrideSettings.strideRange, step: units.lengthStepCm) {
            Text("Step length: \(units.stepLength(cm: stride.manualStrideCm))")
        }
        Group {
            if units.isMetric {
                Text("Typical adults: 60 to 80 cm at normal walking pace. Walk a known distance at that pace and divide it by your steps.")
            } else {
                Text("Typical adults: 24 to 31 inches at normal walking pace. Walk a known distance at that pace and divide it by your steps.")
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
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
