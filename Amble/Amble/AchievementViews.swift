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

    var body: some View {
        ScrollView {
            ScreenHeader("Awards")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            VStack(spacing: 4) {
                Text("\(store.unlocked.count) of \(AchievementID.allCases.count)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textGradient)
                Text("achievements earned").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                // Earned first (newest first), then the rest in their usual order.
                ForEach(sorted, id: \.self) { id in
                    AchievementCard(id: id, progress: store.progress(id), date: store.unlocked[id])
                }
            }
            .padding()
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.refresh() }
    }

    private var sorted: [AchievementID] {
        let earned = AchievementID.allCases.filter { store.unlocked[$0] != nil }
            .sorted { (store.unlocked[$0] ?? .distantPast) > (store.unlocked[$1] ?? .distantPast) }
        return earned + AchievementID.allCases.filter { store.unlocked[$0] == nil }
    }
}

/// Shown after a walk when a new achievement was earned.
struct UnlockSheet: View {
    let ids: [AchievementID]
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            SlothFaceView().frame(width: 64, height: 64)
            Text(ids.count == 1 ? "Achievement unlocked" : "Achievements unlocked")
                .font(.title2.bold()).foregroundStyle(Theme.textGradient)
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 14) {
                    AchievementBadge(id: id, progress: 1, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id.title).font(.headline)
                        Text(id.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            Button(action: onDone) {
                Text("Nice")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
