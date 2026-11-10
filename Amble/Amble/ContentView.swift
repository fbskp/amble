import SwiftUI

/// Root: the welcome page on first launch, then the walking screen and the weekly goals.
struct ContentView: View {
    @AppStorage(Onboarding.storageKey) private var onboardingVersion = 0
    @State private var asking = false

    var body: some View {
        if onboardingVersion < Onboarding.currentVersion {
            // Nothing else is created yet, so no Bluetooth or Health prompts appear before the notice is accepted.
            OnboardingView(isBusy: asking) { demo in proceed(demo: demo) }
        } else {
            MainTabs()
        }
    }
}

extension ContentView {
    /// Apple Health is asked first and on its own; only then is the pad connection created, which asks for Bluetooth.
    /// This way the two iOS prompts do not appear on top of each other.
    private func proceed(demo: Bool) {
        guard !asking else { return }
        asking = true
        Task { @MainActor in
            try? await HealthWriter().requestAuthorization()
            onboardingVersion = Onboarding.currentVersion
            if demo { PadConnection.shared.startDemo() }
            asking = false
        }
    }
}

private struct MainTabs: View {
    @State private var store = GoalsStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Units.choiceKey, store: Units.store) private var unitChoice: UnitChoice = .automatic
    private let pad = PadConnection.shared

    var body: some View {
        TabView {
            Tab("Walk", systemImage: "figure.walk") { NavigationStack { WalkView() } }
            Tab("Goals", systemImage: "target") { GoalsView() }
            Tab("Awards", systemImage: "trophy.fill") { NavigationStack { AchievementsView() } }
        }
        .tint(Theme.accent)
        // Keep the history (goals, achievements) current whichever tab is open.
        .task { await store.refresh() }
        .onChange(of: pad.healthQueue.savedWalkCount) { _, _ in Task { await store.refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        .sheet(isPresented: Binding(get: { !store.celebrate.isEmpty || !store.celebrateAnimals.isEmpty }, set: { if !$0 { store.clearCelebration() } })) {
            UnlockSheet(ids: store.celebrate, animals: store.celebrateAnimals) { store.clearCelebration() }
        }
        // Last, so every screen and sheet inside shows the same units.
        .environment(\.units, Units(choice: unitChoice))
    }
}
