import ActivityKit
import Foundation
import os

/// Starts, updates and ends the walk's Live Activity (lock screen / Dynamic Island).
@MainActor
final class WalkActivityController {
    typealias ContentState = WalkActivityAttributes.ContentState

    private var liveActivity: Activity<WalkActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastPublishedSpeed = -1.0
    private var lastPublishedState: ContentState?
    private let log = Logger(subsystem: "org.biskup.amble", category: "activity")

    /// Whether two states look the same on screen (the timer runs by itself and is ignored).
    private func sameContent(_ a: ContentState, _ b: ContentState) -> Bool {
        a.speedKmh == b.speedKmh && a.distanceMeters == b.distanceMeters && a.steps == b.steps
            && a.energyKcal == b.energyKcal && a.pausedAt == b.pausedAt
    }

    /// iOS only allows starting a Live Activity while the app is in the foreground; updates and ending work in the background.
    func start(padName: String, startDate: Date, state: ContentState) {
        guard liveActivity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // After an app relaunch a previous activity may still be running: adopt it instead of starting a second one.
        if let existing = Activity<WalkActivityAttributes>.activities.first {
            liveActivity = existing
            nonisolated(unsafe) let extras = Array(Activity<WalkActivityAttributes>.activities.dropFirst())
            Task { @MainActor in
                for extra in extras {
                    nonisolated(unsafe) let handle = extra
                    await handle.end(nil, dismissalPolicy: .immediate)
                }
            }
            return
        }
        let attributes = WalkActivityAttributes(padName: padName, startDate: startDate)
        do {
            liveActivity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            lastUpdate = Date()
            lastPublishedSpeed = state.speedKmh
            lastPublishedState = state
        } catch {
            log.notice("live activity not started: \(error.localizedDescription)")
        }
    }

    func update(_ state: ContentState, force: Bool = false) {
        guard let activity = liveActivity else { return }
        // Every update re-renders the island and can make small views flicker, and iOS rate limits updates.
        // So: at once when the speed changes, otherwise at most every 10 s, and never with identical content.
        let speedChanged = abs(state.speedKmh - lastPublishedSpeed) >= 0.05
        guard force || speedChanged || Date().timeIntervalSince(lastUpdate) >= 10 else { return }
        if !force, let last = lastPublishedState, sameContent(state, last) { return }
        lastUpdate = Date()
        lastPublishedSpeed = state.speedKmh
        lastPublishedState = state
        // Activity is only ever used from the main actor here, so handing it to a main-actor task is safe.
        nonisolated(unsafe) let handle = activity
        Task { @MainActor in await handle.update(.init(state: state, staleDate: nil)) }
    }

    /// Ends every Walk activity, not only the one this process started: after an app relaunch (update, crash)
    /// the old activity would otherwise stay on the lock screen with its timer still counting.
    func end(_ state: ContentState) {
        let all = Activity<WalkActivityAttributes>.activities
        liveActivity = nil
        lastPublishedState = nil
        guard !all.isEmpty else { return }
        nonisolated(unsafe) let handles = all
        // .immediate: a finished activity must not linger, because its timer keeps running.
        Task { @MainActor in
            for activity in handles {
                nonisolated(unsafe) let handle = activity
                await handle.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
}
