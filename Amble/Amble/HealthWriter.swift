import Foundation
import HealthKit
import AmbleCore

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

    /// Read access: the user's step length and height (for the step estimate), and the walks Amble saved itself
    /// with their distance, energy and steps (for the history). Queries for those are limited to Amble's own data.
    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.walkingStepLength), HKQuantityType(.height), HKObjectType.workoutType(),
         HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned), HKQuantityType(.stepCount)]
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
            // Pauses come back from the workout's pause and resume events.
            var pauses: [WalkPause] = []
            var pausedAt: Date?
            for event in w.workoutEvents ?? [] {
                switch event.type {
                case .pause: pausedAt = event.dateInterval.start
                case .resume:
                    if let start = pausedAt { pauses.append(WalkPause(start: start, end: event.dateInterval.start)) }
                    pausedAt = nil
                default: break
                }
            }
            var walk = WalkSession(start: w.startDate, end: w.endDate,
                                   distanceMeters: sum(.distanceWalkingRunning, .meter()),
                                   energyKcal: sum(.activeEnergyBurned, .kilocalorie()),
                                   steps: Int(sum(.stepCount, .count())),
                                   pauses: pauses.isEmpty ? nil : pauses)
            // `duration` excludes paused time. If the events do not explain the difference, shorten `end`
            // instead, so `activeSeconds` stays right for goals.
            if abs(walk.activeSeconds - w.duration) > 1 {
                walk.end = w.startDate.addingTimeInterval(w.duration)
                walk.pauses = nil
            }
            return walk
        }
    }

    /// The walk minute by minute, from the samples Amble saved with it. Walks saved before Amble wrote
    /// minutes come back as one segment. Empty when Health is unavailable or not readable.
    func readSegments(for walk: WalkSession) async -> [WalkSegment] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let mine = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: walk.start, end: walk.end, options: [.strictStartDate, .strictEndDate]),
        ])
        let distance = HKQuantityType(.distanceWalkingRunning)
        let energy = HKQuantityType(.activeEnergyBurned)
        let steps = HKQuantityType(.stepCount)
        let query = HKSampleQueryDescriptor(
            predicates: [distance, energy, steps].map { HKSamplePredicate.quantitySample(type: $0, predicate: mine) },
            sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await query.result(for: store) else { return [] }
        // The three kinds of sample of one minute share its start and end.
        var byStart: [Date: WalkSegment] = [:]
        for sample in samples {
            var segment = byStart[sample.startDate]
                ?? WalkSegment(start: sample.startDate, end: sample.endDate, distanceMeters: 0, energyKcal: 0, steps: 0)
            switch sample.quantityType {
            case distance: segment.distanceMeters += sample.quantity.doubleValue(for: .meter())
            case energy: segment.energyKcal += sample.quantity.doubleValue(for: .kilocalorie())
            case steps: segment.steps += sample.quantity.doubleValue(for: .count())
            default: break
            }
            byStart[sample.startDate] = segment
        }
        return byStart.values.sorted { $0.start < $1.start }
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
            func add(_ type: HKQuantityType, _ unit: HKUnit, _ value: Double, from start: Date, to end: Date) {
                guard value > 0 else { return }
                samples.append(HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                                                start: start, end: end))
            }
            if let segments = walk.segments, !segments.isEmpty {
                // Minute by minute, so Health (and Amble's history) can show how the pace changed.
                for (segment, steps) in zip(segments, walk.segmentStepCounts) {
                    add(HKQuantityType(.distanceWalkingRunning), .meter(), segment.distanceMeters, from: segment.start, to: segment.end)
                    add(HKQuantityType(.activeEnergyBurned), .kilocalorie(), segment.energyKcal, from: segment.start, to: segment.end)
                    if writeSteps { add(HKQuantityType(.stepCount), .count(), Double(steps), from: segment.start, to: segment.end) }
                }
            } else {
                add(HKQuantityType(.distanceWalkingRunning), .meter(), walk.distanceMeters, from: walk.start, to: walk.end)
                add(HKQuantityType(.activeEnergyBurned), .kilocalorie(), walk.energyKcal, from: walk.start, to: walk.end)
                if writeSteps { add(HKQuantityType(.stepCount), .count(), Double(walk.steps), from: walk.start, to: walk.end) }
            }

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
