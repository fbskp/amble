import Foundation
import Observation
import AmbleCore
import WidgetKit

/// Weekly goals, progress and achievements. History is read back from Apple Health (walks saved by Amble), plus
/// walks that are still queued because Health was locked, so there is no separate database. Only the dates of
/// earned achievements are stored on the phone, so they stay earned if a workout is deleted later.
@MainActor @Observable
final class GoalsStore {
    static let shared = GoalsStore()

    static let weeksShown = 8
    static let walkRange = 1...14
    static let minuteRange = 10...600

    var goals: WeeklyGoals
    /// Every week back to the first walk; the streak needs more than the weeks shown.
    private var allWeeks: [WeekSummary] = []
    /// The weeks shown in the chart.
    var weeks: [WeekSummary] { Array(allWeeks.suffix(Self.weeksShown)) }
    private(set) var hasLoaded = false
    private(set) var healthAvailable = true

    /// Earned achievements and when (stored dates merged with what the history shows).
    private(set) var unlocked: [AchievementID: Date] = [:]
    private(set) var report = AchievementReport(unlocked: [:], totals: AchievementTotals())
    /// Achievements earned since the last refresh, to celebrate.
    private(set) var celebrate: [AchievementID] = []
    /// Animals that joined since the last refresh, to celebrate.
    private(set) var celebrateAnimals: [AnimalID] = []
    /// Animals earned through lifetime distance. Stored, so they stay earned if a workout is deleted later.
    private(set) var unlockedAnimals: Set<AnimalID> = [.sloth]
    /// The animal walking on the belt; shared with the widgets.
    var companion: Companion = Companion.current {
        didSet {
            guard companion != oldValue else { return }
            Companion.current = companion
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private let health = HealthWriter()
    private let defaults = UserDefaults.standard
    private var isRefreshing = false
    private static let unlockedKey = "unlockedAchievements"
    private static let initialisedKey = "achievementsInitialised"
    private static let animalsKey = "unlockedAnimals"

    init() {
        let walks = defaults.object(forKey: "goalWalks") as? Int ?? WeeklyGoals.default.walks
        let minutes = defaults.object(forKey: "goalMinutes") as? Int ?? WeeklyGoals.default.minutes
        goals = WeeklyGoals(walks: walks, minutes: minutes)
        unlocked = Self.loadUnlocked()
        unlockedAnimals = Self.loadAnimals()
        if !unlockedAnimals.contains(Companion.current.animal) { companion = .sloth }
    }

    var currentWeek: WeekSummary { weeks.last ?? WeekSummary(start: Date()) }
    var streak: Int { WeeklyProgress.streak(summaries: allWeeks, goals: goals) }
    var isCurrentWeekComplete: Bool { goals.isMet(by: currentWeek) }

    func progress(_ id: AchievementID) -> Double { unlocked[id] != nil ? 1 : report.progress(id) }
    func clearCelebration() { celebrate = []; celebrateAnimals = [] }

    /// 0...1 progress towards an animal, from lifetime distance.
    func progress(_ animal: AnimalID) -> Double {
        unlockedAnimals.contains(animal) ? 1 : animal.progress(distanceMeters: lifetimeDistanceMeters)
    }
    /// Debug mode (tap the counter on the Awards tab five times): pretend this much lifetime distance, in km.
    private(set) var debugDistanceKm: Double? = {
        let v = UserDefaults.standard.double(forKey: "debugDistanceKm")
        return v > 0 ? v : nil
    }()
    /// What the animals are judged by: the real lifetime distance, unless debug mode overrides it.
    var lifetimeDistanceMeters: Double { debugDistanceKm.map { $0 * 1000 } ?? report.totals.distanceMeters }

    func setDebugDistance(km: Double?) {
        debugDistanceKm = km
        defaults.set(km ?? 0, forKey: "debugDistanceKm")
        updateAnimals(historyRead: true)
    }

    /// Back to just the sloth, with the real distance.
    func debugResetAnimals() {
        debugDistanceKm = nil
        defaults.removeObject(forKey: "debugDistanceKm")
        unlockedAnimals = [.sloth]
        defaults.removeObject(forKey: Self.animalsKey)
        companion = .sloth
        updateAnimals(historyRead: true)
    }

    func persist() {
        defaults.set(goals.walks, forKey: "goalWalks")
        defaults.set(goals.minutes, forKey: "goalMinutes")
        if hasLoaded { publishSnapshot() }   // the widget shows the goals too
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let calendar = Calendar.current
        let now = Date()
        // All-time history: achievements need more than the weeks shown.
        let fromHealth = await health.readWalks(since: .distantPast)
        healthAvailable = fromHealth != nil

        func record(_ w: WalkSession) -> WalkRecord {
            WalkRecord(start: w.start, durationSeconds: w.activeSeconds, distanceMeters: w.distanceMeters, steps: w.steps)
        }
        let records = (fromHealth ?? []).map(record) + PadConnection.loadPending().map(record)

        allWeeks = WeeklyProgress.summariesForAllHistory(of: records, minimumWeeks: Self.weeksShown, endingAt: now, calendar: calendar)
        updateAchievements(records: records, calendar: calendar, historyRead: fromHealth != nil)
        hasLoaded = true
        // Only after a successful read: an unreadable Health must not blank the widget.
        if fromHealth != nil { publishSnapshot() }
    }

    /// Hands this week's progress to the home screen widget through the shared App Group container.
    private func publishSnapshot() {
        let calendar = Calendar.current
        let week = currentWeek
        let interval = calendar.dateInterval(of: .weekOfYear, for: Date())
        let snapshot = GoalsSnapshot(weekStart: interval?.start ?? week.start,
                                     weekEnd: interval?.end ?? week.start.addingTimeInterval(7 * 86_400),
                                     walks: week.walks, minutes: week.minutes,
                                     goalWalks: goals.walks, goalMinutes: goals.minutes, streak: streak)
        guard GoalsSnapshotStore.load() != snapshot else { return }
        GoalsSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: GoalsSnapshotStore.widgetKind)
    }

    private func updateAchievements(records: [WalkRecord], calendar: Calendar, historyRead: Bool) {
        report = AchievementEngine.evaluate(walks: records, goals: goals, calendar: calendar)
        updateAnimals(historyRead: historyRead)
        let earnedNow = report.unlocked.filter { unlocked[$0.key] == nil }
        guard !earnedNow.isEmpty else { return }

        let initialised = defaults.bool(forKey: Self.initialisedKey)
        // The first successful read, or a sudden pile of unlocks (history that only became readable, for example
        // after Health access was granted), is taken in silently instead of celebrating a dozen at once.
        let celebrateThem = initialised && earnedNow.count <= 2
        for (id, date) in earnedNow { unlocked[id] = date }
        Self.saveUnlocked(unlocked)
        if celebrateThem {
            celebrate = AchievementID.allCases.filter { earnedNow[$0] != nil }
        }
        if historyRead { defaults.set(true, forKey: Self.initialisedKey) }
    }

    private func updateAnimals(historyRead: Bool) {
        let earned = Set(AnimalID.unlocked(distanceMeters: lifetimeDistanceMeters))
        let new = earned.subtracting(unlockedAnimals)
        guard !new.isEmpty else { return }
        unlockedAnimals.formUnion(new)
        defaults.set(unlockedAnimals.map(\.rawValue), forKey: Self.animalsKey)
        // Same rule as achievements: no celebrating the first read or a sudden pile.
        if debugDistanceKm != nil || (defaults.bool(forKey: Self.initialisedKey) && new.count <= 1) {
            celebrateAnimals = AnimalID.allCases.filter { new.contains($0) }
        }
    }

    private static func loadAnimals() -> Set<AnimalID> {
        let raw = UserDefaults.standard.stringArray(forKey: animalsKey) ?? []
        return Set(raw.compactMap(AnimalID.init(rawValue:))).union([.sloth])
    }

    private static func loadUnlocked() -> [AchievementID: Date] {
        guard let data = UserDefaults.standard.data(forKey: unlockedKey),
              let raw = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, date in AchievementID(rawValue: key).map { ($0, date) } })
    }

    private static func saveUnlocked(_ unlocked: [AchievementID: Date]) {
        let raw = Dictionary(uniqueKeysWithValues: unlocked.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: unlockedKey)
    }
}
