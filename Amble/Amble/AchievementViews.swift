import SwiftUI
import AmbleCore

/// A round badge: filled with the theme gradient when earned, grey with a progress ring while locked.
struct AchievementBadge: View {
    let id: AchievementID
    let progress: Double
    var size: CGFloat = 64

    private var earned: Bool { progress >= 1 }

    var body: some View {
        ZStack {
            Circle()
                .fill(earned ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
            if !earned && progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
            }
            Image(systemName: id.symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(earned ? AnyShapeStyle(.white) : AnyShapeStyle(Color.secondary.opacity(0.7)))
        }
        .frame(width: size, height: size)
        .shadow(color: earned ? Theme.teal.opacity(0.25) : .clear, radius: 6, y: 3)
    }
}

/// One companion in the collection: tap an unlocked animal to let it walk with you; locked ones show a distance bar.
struct AnimalCard: View {
    let animal: AnimalID
    let progress: Double
    let isSelected: Bool
    let distanceMeters: Double

    private var earned: Bool { progress >= 1 }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(earned ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.06))
                SlothFaceView(companion: animal.companion)
                    .padding(10)
                    .saturation(earned ? 1 : 0)
                    .opacity(earned ? 1 : 0.35)
                if !earned {
                    Image(systemName: "lock.fill").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .offset(x: 22, y: 22)
                }
            }
            .frame(width: 64, height: 64)
            .overlay(Circle().stroke(Theme.accent, lineWidth: isSelected ? 3 : 0))
            Text(animal.companion.name).font(.subheadline.weight(.semibold))
            if earned {
                Text(isSelected ? "Walking with you" : "Tap to choose")
                    .font(.caption2.weight(.medium)).foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .multilineTextAlignment(.center)
            } else {
                let left = max(0, animal.unlockDistanceMeters - distanceMeters) / 1000
                Text("\(left, format: .number.precision(.fractionLength(1))) km to go")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
        // Every card is as tall as the tallest one in the row: a caption that wraps (longer in German) must not
        // make its card bigger than its neighbours.
        .frame(width: 104)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 10)
        .background(Theme.accent.opacity(earned ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One achievement as a card in the grid.
struct AchievementCard: View {
    let id: AchievementID
    let progress: Double
    let date: Date?
    /// Every card has the same height, tall enough for the longest titles and descriptions in both languages.
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 176

    var body: some View {
        VStack(spacing: 5) {
            AchievementBadge(id: id, progress: progress, size: 56)
            Text(id.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
            Text(id.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let date {
                Text(date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.caption2.weight(.medium)).foregroundStyle(Theme.accent)
            } else if progress > 0 {
                Text("\(Int(progress * 100)) %").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)   // fixed size; the content sits in the vertical centre
        .background(Theme.accent.opacity(date == nil ? 0.04 : 0.10), in: RoundedRectangle(cornerRadius: 16))
        .opacity(date == nil ? 0.85 : 1)
    }
}

struct AchievementsView: View {
    @State private var store = GoalsStore.shared
    @AppStorage("debugMode") private var debugMode = false
    @State private var counterTaps = 0
    @State private var lastTap = Date.distantPast

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Text("\(store.unlocked.count) of \(AchievementID.allCases.count)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textGradient)
                Text("achievements earned").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
            .onTapGesture(perform: counterTapped)
            if debugMode { DebugPanel(store: store, debugMode: $debugMode) }
            VStack(alignment: .leading, spacing: 8) {
                Text("Companions").font(.headline).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(AnimalID.allCases, id: \.self) { animal in
                            let earned = store.unlockedAnimals.contains(animal)
                            Button { if earned { store.companion = animal.companion } } label: {
                                AnimalCard(animal: animal, progress: store.progress(animal),
                                           isSelected: store.companion == animal.companion,
                                           distanceMeters: store.lifetimeDistanceMeters)
                            }
                            .buttonStyle(.plain)
                            .disabled(!earned)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                }
            }
            .padding(.top, 14)
            Text("Achievements").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 14)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                // Earned first (newest first), then the rest in their usual order.
                ForEach(sorted, id: \.self) { id in
                    AchievementCard(id: id, progress: store.progress(id), date: store.unlocked[id])
                }
            }
            .padding()
        }
        .navigationTitle("Awards")
        .task { await store.refresh() }
    }

    /// Five quick taps on the counter switch debug mode on or off.
    private func counterTapped() {
        #if DEBUG
        counterTaps = Date().timeIntervalSince(lastTap) < 1.5 ? counterTaps + 1 : 1
        lastTap = Date()
        guard counterTaps >= 5 else { return }
        counterTaps = 0
        debugMode.toggle()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    private var sorted: [AchievementID] {
        let earned = AchievementID.allCases.filter { store.unlocked[$0] != nil }
            .sorted { (store.unlocked[$0] ?? .distantPast) > (store.unlocked[$1] ?? .distantPast) }
        return earned + AchievementID.allCases.filter { store.unlocked[$0] == nil }
    }
}

/// Shown after a walk when something new was earned: a companion gets the whole sheet, achievements a short list.
struct UnlockSheet: View {
    let ids: [AchievementID]
    var animals: [AnimalID] = []
    let onDone: () -> Void

    var body: some View {
        if let animal = animals.last {
            NewCompanionView(animal: animal, ids: ids, onDone: onDone)
                .presentationDetents([.large])
        } else {
            achievements
                .presentationDetents([.medium])
        }
    }

    private var title: LocalizedStringKey { ids.count == 1 ? "Achievement unlocked" : "Achievements unlocked" }

    private var achievements: some View {
        VStack(spacing: 18) {
            SlothFaceView(companion: .current).frame(width: 64, height: 64)
            Text(title).font(.title2.bold()).foregroundStyle(Theme.textGradient)
            ForEach(ids, id: \.self) { EarnedRow(id: $0) }
            GradientButton(title: "Nice", action: onDone)
        }
        .padding(24)
    }
}

/// A new animal joins: it walks in on its belt, with its name, why it came, and a button to take it along at once.
private struct NewCompanionView: View {
    let animal: AnimalID
    let ids: [AchievementID]
    let onDone: () -> Void

    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            SlothView(speedKmh: 2.5, isAwake: true, companion: animal.companion)
                .aspectRatio(SlothArt.designSize.width / SlothArt.designSize.height, contentMode: .fit)
                .frame(minHeight: 110, maxHeight: 210)
                .padding(.horizontal, 12)
                .scaleEffect(arrived ? 1 : 0.8)
                .opacity(arrived ? 1 : 0)
                // A soft glow behind the animal instead of confetti: this is a calm app.
                .background {
                    Circle()
                        .fill(RadialGradient(colors: [Theme.green.opacity(0.32), Theme.green.opacity(0)],
                                             center: .center, startRadius: 20, endRadius: 170))
                        .scaleEffect(arrived ? 1.25 : 0.6)
                }
            VStack(spacing: 6) {
                Text("New companion")
                    .font(.footnote.weight(.semibold)).textCase(.uppercase).kerning(1.4)
                    .foregroundStyle(Theme.accent)
                Text(animal.companion.name)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textGradient)
                Text("Your reward for walking \(Int(animal.unlockDistanceMeters / 1000)) km in total.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            if !ids.isEmpty {
                VStack(spacing: 12) { ForEach(ids, id: \.self) { EarnedRow(id: $0, badgeSize: 44) } }
                    .padding(14)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 22)
            }
            Spacer(minLength: 16)
            VStack(spacing: 6) {
                GradientButton(title: "Walk together") {
                    GoalsStore.shared.companion = animal.companion
                    onDone()
                }
                Button("Not now", action: onDone)
                    .font(.body.weight(.medium)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                Text("You can change companions on the Awards tab.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.68).delay(0.15)) { arrived = true }
        }
    }
}

/// One earned achievement: its badge with title and description beside it.
private struct EarnedRow: View {
    let id: AchievementID
    var badgeSize: CGFloat = 56

    var body: some View {
        HStack(spacing: 14) {
            AchievementBadge(id: id, progress: 1, size: badgeSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(id.title).font(.headline)
                Text(id.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct GradientButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// Hidden tools for testing companions without walking 10 km. Shown after five taps on the Awards counter.
struct DebugPanel: View {
    let store: GoalsStore
    @Binding var debugMode: Bool

    private let options: [(label: String, km: Double?)] = [
        ("Real distance", nil), ("9.9 km", 9.9), ("10 km", 10), ("24.9 km", 24.9), ("25 km", 25), ("100 km", 100),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Debug mode").font(.headline)
            HStack {
                Text(verbatim: "Fake lifetime distance")
                Spacer()
                Picker("", selection: Binding(get: { store.debugDistanceKm }, set: { store.setDebugDistance(km: $0) })) {
                    ForEach(options, id: \.label) { Text(verbatim: $0.label).tag($0.km) }
                }
                .labelsHidden()
            }
            HStack(spacing: 10) {
                button("Reset animals") { store.debugResetAnimals() }
                button("Hide") { debugMode = false }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal).padding(.top, 14)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
