import Charts
import SwiftUI
import AmbleCore

struct GoalsView: View {
    @State private var store = GoalsStore.shared
    @Environment(\.scenePhase) private var scenePhase
    private let pad = PadConnection.shared
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    ScreenHeader(title: "Goals") {
                        Spacer()
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Settings")
                    }
                    WeekCard(week: store.currentWeek, goals: store.goals, streak: store.streak, loaded: store.hasLoaded)
                    history
                }
                .padding([.horizontal, .bottom])   // no top inset: the header supplies it, as on the other tabs
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView(stride: pad.stride) }
            .task { await store.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.refresh() } }
            }
            // A walk was just written to Health: reload the numbers.
            .onChange(of: pad.savedWalkCount) { _, _ in Task { await store.refresh() } }
        }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Minutes per week").font(.headline)
            Chart {
                ForEach(store.weeks) { week in
                    BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Minutes", week.minutes))
                        .foregroundStyle(store.goals.isMet(by: week) ? Theme.gradient : LinearGradient(colors: [Theme.accent.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                        .cornerRadius(5)
                }
                RuleMark(y: .value("Goal", store.goals.minutes))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .frame(height: 150)
            if store.hasLoaded, !store.healthAvailable || store.weeks.allSatisfy({ $0.walks == 0 }) {
                Text("No walks found yet. Amble reads the walks it saved to Apple Health. If you have walked before, allow Amble to read workouts in Settings > Health > Data Access & Devices > Amble.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
