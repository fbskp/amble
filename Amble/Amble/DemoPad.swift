import Foundation
import AmbleCore

/// A simulated walking pad for demo mode (App Review, people without a pad, screenshots).
/// It follows the behaviour observed on the real pad: a short countdown after Start, speed that ramps
/// gradually, a ramp-down after Stop, and Pause that reports idle plus "paused". It never touches Bluetooth.
@MainActor
final class DemoPad {
    var onData: (TreadmillData) -> Void = { _ in }
    var onTraining: (TrainingStatus) -> Void = { _ in }
    var onMachine: (MachineStatus) -> Void = { _ in }

    private enum Phase { case idle, countdown(left: Double), running, stopping, paused }
    private var phase = Phase.idle
    private var speed = 0.0
    private var target = DemoPad.startSpeed
    // Counters carry on between walks, like the real pad's.
    private var distance = 120.0
    private var seconds = 436.0
    private var kcal = 0.0
    private var task: Task<Void, Never>?

    private static let startSpeed = 1.0
    private static let tick = 0.5
    private static let countdown = 3.5
    private static let range = SpeedRange.sportstechPad

    func begin() {
        onTraining(.idle)
        emit()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.step()
            }
        }
    }

    func end() {
        task?.cancel()
        task = nil
    }

    /// Handles a Control Point command and returns the result code the pad would answer with.
    func handle(_ command: FTMSCommand) -> ControlPointResponse.Result {
        switch command {
        case .requestControl, .reset:
            return .success

        case .start:
            switch phase {
            case .idle, .paused:
                phase = .countdown(left: Self.countdown)
                onMachine(.started)
                onTraining(.preWorkout)
            case .stopping: return .operationFailed
            case .countdown, .running: break
            }
            return .success

        case .setTargetSpeed(let kmh):
            switch phase {
            case .countdown, .running:
                target = Self.range.normalized(kmh)
                onMachine(.targetSpeedChanged(kmh: target))
                return .success
            default: return .operationFailed
            }

        case .pause:
            guard case .running = phase else { return .operationFailed }
            phase = .paused
            onMachine(.paused)
            onTraining(.idle)
            return .success

        case .stop:
            switch phase {
            case .countdown, .running:
                phase = .stopping
                target = Self.startSpeed
                onMachine(.stopped)
                onTraining(.postWorkout)
            case .paused:
                phase = .idle
                speed = 0
                target = Self.startSpeed
                onMachine(.stopped)
                onTraining(.idle)
            case .idle, .stopping: break
            }
            return .success
        }
    }

    private func step() {
        let dt = Self.tick
        switch phase {
        case .idle:
            break
        case .countdown(let left):
            if left - dt <= 0 {
                phase = .running
                onTraining(.manualMode)
            } else {
                phase = .countdown(left: left - dt)
            }
        case .running:
            speed = ramp(speed, to: target)
        case .stopping:
            speed = ramp(speed, to: 0)
            if speed == 0 {
                phase = .idle
                onTraining(.idle)
            }
        case .paused:
            speed = ramp(speed, to: 0)
        }
        // Distance and energy follow the belt; time only counts while the walk is on.
        distance += speed / 3.6 * dt
        kcal += speed * 0.0097 * dt   // about 0.5 kcal per kg and km, for 70 kg
        switch phase {
        case .running, .stopping: seconds += dt
        default: break
        }
        emit()
    }

    /// Moves 0.1 km/h per tick, like the real pad's slow ramp.
    private func ramp(_ value: Double, to goal: Double) -> Double {
        let next = value < goal ? min(goal, value + 0.1) : max(goal, value - 0.1)
        return (next * 10).rounded() / 10
    }

    private func emit() {
        var d = TreadmillData()
        d.speedKmh = speed
        d.totalDistanceMeters = Int(distance)
        d.energyTotalKcal = Int(kcal)
        d.elapsedSeconds = Int(seconds)
        onData(d)
    }
}
