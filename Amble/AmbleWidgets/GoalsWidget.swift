import SwiftUI
import WidgetKit

/// Home screen widget: this week's walks and minutes against the weekly goals.
struct GoalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GoalsSnapshotStore.widgetKind, provider: GoalsProvider()) { entry in
            GoalsWidgetView(entry: entry)
        }
        .configurationDisplayName("Weekly goals")
        .description("Your walks and minutes this week.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct GoalsEntry: TimelineEntry {
    let date: Date
    let snapshot: GoalsSnapshot
    /// False until the app has saved its first snapshot.
    let isSetUp: Bool
}

struct GoalsProvider: TimelineProvider {
    func placeholder(in context: Context) -> GoalsEntry {
        GoalsEntry(date: Date(), snapshot: .sample, isSetUp: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (GoalsEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalsEntry>) -> Void) {
        let now = Date()
        let first = entry(at: now)
        // A second entry at the start of next week, so the rings reset by themselves even if the app is not opened.
        var entries = [first]
        if first.isSetUp, first.snapshot.weekEnd > now {
            entries.append(GoalsEntry(date: first.snapshot.weekEnd, snapshot: first.snapshot.adjusted(to: first.snapshot.weekEnd), isSetUp: true))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date) -> GoalsEntry {
        guard let saved = GoalsSnapshotStore.load() else {
            var empty = GoalsSnapshot.sample
            empty.walks = 0; empty.minutes = 0; empty.streak = 0
            return GoalsEntry(date: date, snapshot: empty, isSetUp: false)
        }
        return GoalsEntry(date: date, snapshot: saved.adjusted(to: date), isSetUp: true)
    }
}

struct GoalsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GoalsEntry

    private var s: GoalsSnapshot { entry.snapshot }

    var body: some View {
        Group {
            switch family {
            case .systemMedium: medium
            default: small
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color(uiColor: .systemBackground)
                Theme.accent.opacity(0.08)
            }
        }
    }

    private var message: String {
        entry.isSetUp
            ? GoalMessage.text(walks: s.walks, minutes: s.minutes, goalWalks: s.goalWalks, goalMinutes: s.goalMinutes)
            : String(localized: "Open Amble to see your week.")
    }

    // MARK: 2 x 2

    private var small: some View {
        VStack(spacing: 10) {
            GoalRings(walkProgress: s.walkProgress, minuteProgress: s.minuteProgress, diameter: 82)
                .padding(5)   // room for the ring strokes, which extend past the diameter
            if entry.isSetUp {
                HStack(spacing: 14) {
                    compactLegend(Theme.green, "\(s.walks) / \(s.goalWalks)", "Walks")
                    compactLegend(Theme.mint, "\(s.minutes) / \(s.goalMinutes)", "Minutes")
                }
            } else {
                Text(message).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
            }
        }
    }

    private func compactLegend(_ color: Color, _ value: String, _ title: LocalizedStringKey) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    // MARK: 2 x 4

    private var medium: some View {
        HStack(spacing: 18) {
            GoalRings(walkProgress: s.walkProgress, minuteProgress: s.minuteProgress, diameter: 100)
                .padding(8)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("This week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if s.streak > 0 {
                        Label("\(s.streak)", systemImage: "leaf.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel(Text("\(s.streak) weeks in a row"))
                    }
                }
                legend(Theme.green, "\(s.walks) / \(s.goalWalks)", "Walks")
                legend(Theme.mint, "\(s.minutes) / \(s.goalMinutes)", "Minutes")
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
        }
    }

    private func legend(_ color: Color, _ value: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(value).font(.headline).monospacedDigit().lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
