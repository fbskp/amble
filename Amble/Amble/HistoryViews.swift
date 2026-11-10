import Charts
import SwiftUI
import AmbleCore

/// A walk in the history: saved in Health, or still waiting to be saved there.
struct HistoryEntry: Identifiable {
    let walk: WalkSession
    let isPending: Bool
    var id: Date { walk.start }
}

/// How the history writes durations. Distances and speeds come from `Units`.
enum WalkFormat {
    /// "32 min, 10 s" style, for lists.
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    /// "0:32:10" style, for the detail.
    static func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .hourMinuteSecond))
    }
}

/// One walk in a list: when on the left, how far and how long on the right.
struct WalkRow: View {
    let entry: HistoryEntry
    @Environment(\.units) private var units
    /// In a `List` the row gets its padding and chevron from the list.
    var inList = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.walk.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Text(entry.walk.start, format: .dateTime.hour().minute())
                    if entry.isPending {
                        Image(systemName: "clock.arrow.circlepath").accessibilityLabel("Waiting for Apple Health")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(units.distance(entry.walk.distanceMeters))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(WalkFormat.duration(entry.walk.activeSeconds))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if !inList {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, inList ? 2 : 10)
        .padding(.horizontal, inList ? 0 : 14)
        .contentShape(Rectangle())
    }
}

/// The newest walks on the Goals tab, with a link to all of them.
struct RecentWalks: View {
    let entries: [HistoryEntry]
    static let shown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Walks").font(.headline)
                Spacer()
                if entries.count > Self.shown {
                    NavigationLink("All walks") { AllWalksView(entries: entries) }
                        .font(.subheadline)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(entries.prefix(Self.shown).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 14) }
                    NavigationLink { WalkDetailView(entry: entry) } label: { WalkRow(entry: entry) }
                        .buttonStyle(.plain)
                }
            }
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Every walk, grouped by month, newest first.
struct AllWalksView: View {
    let entries: [HistoryEntry]

    private struct Month: Identifiable {
        let start: Date
        let entries: [HistoryEntry]
        var id: Date { start }
    }

    private var months: [Month] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.dateInterval(of: .month, for: entry.walk.start)?.start ?? entry.walk.start
        }
        return grouped
            .map { Month(start: $0.key, entries: $0.value.sorted { $0.walk.start > $1.walk.start }) }
            .sorted { $0.start > $1.start }
    }

    var body: some View {
        List {
            ForEach(months) { month in
                Section {
                    ForEach(month.entries) { entry in
                        NavigationLink { WalkDetailView(entry: entry) } label: { WalkRow(entry: entry, inList: true) }
                    }
                } header: {
                    Text(month.start, format: .dateTime.month(.wide).year())
                }
            }
        }
        .navigationTitle("All walks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One walk: its numbers and how the speed changed along the way.
struct WalkDetailView: View {
    let entry: HistoryEntry
    @State private var segments: [WalkSegment]?
    @Environment(\.units) private var units

    private var walk: WalkSession { entry.walk }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: timeRange).font(.subheadline).foregroundStyle(.secondary)
                speedCard
                Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        tile("Time", WalkFormat.clock(walk.activeSeconds))
                        tile("Distance", units.distance(walk.distanceMeters))
                    }
                    GridRow {
                        tile("Steps (est.)", walk.steps.formatted())
                        tile("Energy", "\(Int(walk.energyKcal.rounded())) kcal")
                    }
                    GridRow {
                        tile("Average speed", units.speedText(walk.averageSpeedKmh))
                        tile("Pauses", pausesText)
                    }
                }
                if entry.isPending {
                    Label("Waiting for Apple Health", systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(Text(walk.start, format: .dateTime.weekday(.wide).day().month(.wide)))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var timeRange: String {
        "\(walk.start.formatted(date: .omitted, time: .shortened)) – \(walk.end.formatted(date: .omitted, time: .shortened))"
    }

    private var pausesText: String {
        let pauses = walk.pauses ?? []
        guard !pauses.isEmpty else { return "–" }
        let total = pauses.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        return "\(pauses.count) · \(WalkFormat.duration(total))"
    }

    private func load() async {
        guard segments == nil else { return }
        if let own = walk.segments {   // not in Health yet: the walk carries its own minutes
            segments = own
        } else {
            segments = await HealthWriter().readSegments(for: walk)
        }
    }

    // MARK: Speed curve

    private struct SpeedPoint: Identifiable {
        let time: Date
        let kmh: Double
        /// Stretches between pauses are drawn apart, so the line does not bridge a pause.
        let stretch: Int
        var id: Date { time }
    }

    private static func points(_ segments: [WalkSegment]) -> [SpeedPoint] {
        var stretch = 0
        var previousEnd: Date?
        var points: [SpeedPoint] = []
        for segment in segments where segment.seconds >= 10 {   // a few seconds at the end say little about the pace
            if let previousEnd, segment.start.timeIntervalSince(previousEnd) > 1 { stretch += 1 }
            previousEnd = segment.end
            points.append(SpeedPoint(time: segment.start.addingTimeInterval(segment.seconds / 2),
                                     kmh: segment.speedKmh, stretch: stretch))
        }
        return points
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speed").font(.headline)
            if let segments {
                let points = Self.points(segments)
                if points.count >= 2 {
                    chart(points)
                } else {
                    Text("The speed curve is shown for walks recorded with this version of Amble or later.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func chart(_ points: [SpeedPoint]) -> some View {
        let top = max(units.speed(4), (points.map { units.speed($0.kmh) }.max() ?? 0) + 0.5)
        return Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.time), y: .value("Speed", units.speed(point.kmh)),
                         series: .value("Stretch", point.stretch), stacking: .unstacked)
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Theme.green.opacity(0.35), Theme.green.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.time), y: .value("Speed", units.speed(point.kmh)),
                         series: .value("Stretch", point.stretch))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(Theme.accent)
            }
            RuleMark(y: .value("Average speed", units.speed(walk.averageSpeedKmh)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary)
        }
        .chartYScale(domain: 0...top)
        .chartYAxisLabel { Text(verbatim: units.speedSymbol) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(height: 170)
    }

    private func tile(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
}
