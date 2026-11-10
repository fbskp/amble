import Foundation
import HealthKit
import Observation
import UIKit
import os
import AmbleCore

/// Something the user needs to know about Health. Successful saves are silent.
struct HealthAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Finished walks waiting to be written to Apple Health. Health refuses writes while the phone is locked, so a
/// walk that ends in the background stays queued (also across app restarts) and is saved when the phone unlocks.
@MainActor @Observable
final class HealthQueue {
    private(set) var alert: HealthAlert?
    /// Counts walks written to Health, so other screens know when to reload.
    private(set) var savedWalkCount = 0

    private static let pendingKey = "pendingWalks"
    private static let maximumSaveAttempts = 3
    private var pendingWalks: [WalkSession] = HealthQueue.loadPending()
    private var isFlushing = false
    private var alertedAboutAccess = false
    private let health = HealthWriter()
    private let log = Logger(subsystem: "org.biskup.amble", category: "health")

    init() {
        // Health data becomes writable again after the phone is unlocked.
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.protectedDataDidBecomeAvailableNotification) {
                self?.flush()
            }
        }
    }

    static func loadPending() -> [WalkSession] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([WalkSession].self, from: data)) ?? []
    }

    private static func persist(_ walks: [WalkSession]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(walks), forKey: pendingKey)
    }

    func show(_ alert: HealthAlert) { self.alert = alert }
    func dismissAlert() { alert = nil }

    func requestAuthorization() async {
        do { try await health.requestAuthorization() }
        catch { alertAboutAccess(error) }
    }

    /// Only for problems the user can fix (no access, no Health on this device), and only once per run.
    private func alertAboutAccess(_ error: Error) {
        guard !alertedAboutAccess else { return }
        alertedAboutAccess = true
        alert = HealthAlert(title: "Apple Health", message: error.localizedDescription)
    }

    /// Queue first, then try to write, so the walk survives a locked phone or an app restart.
    func enqueue(_ walk: WalkSession) {
        pendingWalks.append(walk)
        Self.persist(pendingWalks)
        flush()
    }

    /// Writes queued walks to Health, oldest first. Called after a walk, on unlock and when the app becomes active.
    func flush() {
        guard !isFlushing, !pendingWalks.isEmpty else { return }
        isFlushing = true
        Task { @MainActor in
            defer { isFlushing = false }
            var failedThisRound = Set<Date>()   // a walk Health refuses must not hold up the ones behind it
            while let walk = pendingWalks.first(where: { !failedThisRound.contains($0.start) }) {
                do {
                    try await health.save(walk)
                    pendingWalks.removeAll { $0.start == walk.start }
                    Self.persist(pendingWalks)
                    savedWalkCount += 1
                    Task { await GoalsStore.shared.refresh() }   // also updates the widget when no screen is open
                } catch {
                    log.notice("health save failed: \(error.localizedDescription)")
                    if error is HealthError { alertAboutAccess(error); return }
                    // The phone is locked, so Health is unreadable: nothing is wrong, retry on unlock.
                    if (error as? HKError)?.code == .errorDatabaseInaccessible || !UIApplication.shared.isProtectedDataAvailable { return }
                    failedThisRound.insert(walk.start)
                    recordFailedSave(of: walk)
                }
            }
        }
    }

    /// Health refused a walk while it was readable. Retry later, but after a few tries give up and say so.
    private func recordFailedSave(of walk: WalkSession) {
        guard let i = pendingWalks.firstIndex(where: { $0.start == walk.start }) else { return }
        let attempts = (pendingWalks[i].saveAttempts ?? 0) + 1
        if attempts >= Self.maximumSaveAttempts {
            pendingWalks.remove(at: i)
            let date = walk.start.formatted(date: .abbreviated, time: .shortened)
            alert = HealthAlert(title: String(localized: "Walk not saved"),
                                message: String(localized: "Apple Health did not accept your walk from \(date), even after several tries, so it was not saved."))
        } else {
            pendingWalks[i].saveAttempts = attempts
        }
        Self.persist(pendingWalks)
    }
}
