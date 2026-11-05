import SwiftUI
import AmbleCore

/// The "this week" card: two rings (walks, minutes), the sloth, a short message and the streak.
struct WeekCard: View {
    let week: WeekSummary
    let goals: WeeklyGoals
    let streak: Int
    let loaded: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                GoalRings(walkProgress: goals.walkProgress(week), minuteProgress: goals.minuteProgress(week), diameter: 150)
                VStack(alignment: .leading, spacing: 14) {
                    legend("Walks", "\(week.walks) / \(goals.walks)", Theme.green)
                    legend("Minutes", "\(week.minutes) / \(goals.minutes)", Theme.mint)
                }
            }
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if streak > 0 {
                Label("\(streak) weeks in a row", systemImage: "leaf.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }

    private var message: String {
        guard loaded else { return String(localized: "Loading...") }
        return GoalMessage.text(walks: week.walks, minutes: week.minutes, goalWalks: goals.walks, goalMinutes: goals.minutes)
    }

    private func legend(_ title: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
