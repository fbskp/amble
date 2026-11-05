import Foundation
import HealthKit

/// One finished belt session, ready to be written to Apple Health.
/// A stretch of a walk during which the belt was paused.
struct WalkPause: Sendable, Codable, Equatable {
    var start: Date
    var end: Date
}

struct WalkSession: Sendable, Codable {
    var start: Date
    var end: Date
    var distanceMeters: Double
    var energyKcal: Double
    var steps: Int
    /// Optional so walks queued by older versions still decode.
    var pauses: [WalkPause]? = nil
    /// Failed save attempts while Health was readable. Optional so older queued walks still decode.
    var saveAttempts: Int? = nil

    /// Time actually walked: the span minus paused time.
    var activeSeconds: Double {
        let paused = (pauses ?? []).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        return max(0, end.timeIntervalSince(start) - paused)
    }
}

enum HealthError: LocalizedError {
    case unavailable, notAuthorized
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Health data is not available on this device.")
        case .notAuthorized: String(localized: "Amble is not allowed to write workouts. Enable it in Settings > Health > Data Access.")
        }
    }
}

/// Writes an indoor walking workout with distance, active energy and (optionally) estimated steps.
@MainActor
final class HealthWriter {
    private let store = HKHealthStore()
    /// Estimated steps are written by default; Health decides which source wins when the Watch also counts.
    var writeSteps = true

    private var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(),
         HKQuantityType(.stepCount),
         HKQuantityType(.distanceWalkingRunning),
         HKQuantityType(.activeEnergyBurned)]
    }

    /// Read access is only used to find the user's step length and height.
    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.walkingStepLength), HKQuantityType(.height), HKObjectType.workoutType()]
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    /// Walks that Amble itself saved to Health (workouts whose source is this app), newest first.
    /// Returns nil when Health is unavailable. Without read access Health returns an empty list, not an error.
    func readWalks(since: Date) async -> [WalkSession]? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: since, end: nil),
        ])
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: HKObjectQueryNoLimit)
        guard let workouts = try? await query.result(for: store) else { return nil }
        return workouts.map { w in
            func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double {
                w.statistics(for: HKQuantityType(id))?.sumQuantity()?.doubleValue(for: unit) ?? 0
            }
            // `duration` excludes paused time; shortening `end` keeps `activeSeconds` right for goals.
            return WalkSession(start: w.startDate, end: w.startDate.addingTimeInterval(w.duration),
                               distanceMeters: sum(.distanceWalkingRunning, .meter()),
                               energyKcal: sum(.activeEnergyBurned, .kilocalorie()),
                               steps: Int(sum(.stepCount, .count())))
        }
    }

    /// Average walking step length (last 90 days) and the latest height. Nil when Health has no data or access is denied.
    func readBodyData() async -> (stepLengthMeters: Double?, heightCm: Double?) {
        guard HKHealthStore.isHealthDataAvailable() else { return (nil, nil) }

        var stride: Double?
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        let strideQuery = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.walkingStepLength), predicate: predicate),
            options: .discreteAverage)
        if let value = try? await strideQuery.result(for: store)?.averageQuantity()?.doubleValue(for: .meter()),
           (0.3...1.2).contains(value) {
            stride = (value * 1000).rounded() / 1000
        }

        var height: Double?
        let heightQuery = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.height))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        if let sample = try? await heightQuery.result(for: store).first {
            let cm = sample.quantity.doubleValue(for: .meterUnit(with: .centi))
            if (120...230).contains(cm) { height = cm }
        }
        return (stride, height)
    }

    func save(_ walk: WalkSession) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            throw HealthError.notAuthorized
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .walking
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())

        // Samples are written as they are added. If a later step fails, remove them again:
        // the walk stays queued and is retried, which would otherwise count them twice.
        do {
            try await builder.beginCollection(at: walk.start)

            var samples: [HKSample] = []
            func add(_ type: HKQuantityType, _ unit: HKUnit, _ value: Double) {
                guard value > 0 else { return }
                samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                                                start: walk.start, end: walk.end))
            }
            add(HKQuantityType(.distanceWalkingRunning), .meter(), walk.distanceMeters)
            add(HKQuantityType(.activeEnergyBurned), .kilocalorie(), walk.energyKcal)
            if writeSteps { add(HKQuantityType(.stepCount), .count(), Double(walk.steps)) }

            if !samples.isEmpty { try await builder.addSamples(samples) }
            // Paused stretches are recorded as events, so Health excludes them from the workout's duration.
            var events: [HKWorkoutEvent] = []
            for pause in walk.pauses ?? [] {
                events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pause.start, duration: 0), metadata: nil))
                events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: pause.end, duration: 0), metadata: nil))
            }
            if !events.isEmpty { try await builder.addWorkoutEvents(events) }
            try await builder.addMetadata([HKMetadataKeyIndoorWorkout: true, "AmbleStepsEstimated": true])
            try await builder.endCollection(at: walk.end)
            _ = try await builder.finishWorkout()
        } catch {
            builder.discardWorkout()
            throw error
        }
    }
}
