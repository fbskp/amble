import SwiftUI

/// Holds the animation state between frames. A plain class (not observable) so drawing never triggers view updates.
final class SlothKeeper {
    private var last: Date?
    private var phase = 0.0
    private var walk = 0.0
    private var awake = 0.0

    func advance(to date: Date, speed: Double, awake wantsAwake: Bool) -> SlothPose {
        let dt = last.map { min(0.1, max(0, date.timeIntervalSince($0))) } ?? 0
        last = date

        let moving = speed > 0.2
        approach(&walk, to: moving ? 1 : 0, rate: 2.5, dt: dt)      // legs ease in and out
        approach(&awake, to: wantsAwake ? 1 : 0, rate: 1.8, dt: dt) // falls asleep / wakes up gradually

        // Walk cycles per second grow with belt speed: about 0.5 Hz at 1 km/h and 1.4 Hz at 4 km/h.
        let frequency = moving ? 0.25 + 0.28 * speed : 0
        phase += frequency * dt
        return SlothPose(phase: phase, walk: walk, awake: awake, time: date.timeIntervalSinceReferenceDate)
    }

    private func approach(_ value: inout Double, to target: Double, rate: Double, dt: Double) {
        let step = rate * dt
        if value < target { value = min(target, value + step) } else { value = max(target, value - step) }
    }
}

/// The animated sloth: sleeps while the belt is stopped, wakes when it starts, walks at the belt's pace.
struct SlothView: View {
    let speedKmh: Double
    let isAwake: Bool

    @State private var keeper = SlothKeeper()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { ctx, size in
                    var c = ctx
                    SlothArt.draw(&c, size: size, pose: SlothPose(phase: 0, walk: 0, awake: isAwake ? 1 : 0, time: 0))
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in
                        let pose = keeper.advance(to: timeline.date, speed: speedKmh, awake: isAwake)
                        var c = ctx
                        SlothArt.draw(&c, size: size, pose: pose)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(isAwake ? "A sloth walking" : "A sloth sleeping")
    }
}
