import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AmbleWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WalkLiveActivity()
        GoalsWidget()
    }
}

/// Counts up on its own and freezes while the walk is paused.
private struct WalkTimer: View {
    let state: WalkActivityAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.timerStart...Date.distantFuture, pauseTime: state.pausedAt, countsDown: false, showsHours: false)
            .monospacedDigit()
    }
}

private func distanceText(_ meters: Int) -> String { Units.current.distance(Double(meters)) }

/// Speed with one decimal in the unit chosen in the app, in the user's number format (3,5 in German).
private func speedText(_ kmh: Double) -> String { Units.current.speedValue(kmh) }

/// "paused", or the speed unit.
private func speedLabel(_ state: WalkActivityAttributes.ContentState) -> Text {
    state.isPaused ? Text("paused") : Text(verbatim: Units.current.speedSymbol)
}

struct WalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            ActivityFamilyView(context: context)
                .activityBackgroundTint(Theme.teal)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        SlothFaceView().frame(width: 30, height: 30)
                        Text(verbatim: Units.current.speedText(context.state.speedKmh))
                            .font(.headline)
                            .foregroundStyle(Theme.green)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WalkTimer(state: context.state)
                        .font(.headline.monospacedDigit())
                        .frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(distanceText(context.state.distanceMeters))
                        Spacer()
                        Text("~\(context.state.steps) steps")
                        Spacer()
                        Text("\(context.state.energyKcal) kcal")
                    }
                    .font(.subheadline)
                }
            } compactLeading: {
                SlothFaceView().frame(width: 22, height: 22)
            } compactTrailing: {
                Text(speedText(context.state.speedKmh)).monospacedDigit().foregroundStyle(Theme.green)
            } minimal: {
                SlothFaceView().frame(width: 22, height: 22)
            }
            .keylineTint(Theme.green)
        }
        // Also offer a compact card for the Apple Watch Smart Stack.
        .supplementalActivityFamilies([.small])
    }
}

/// iPhone gets the full card; the Apple Watch Smart Stack gets the small one.
private struct ActivityFamilyView: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<WalkActivityAttributes>

    var body: some View {
        switch family {
        case .small:
            SmallWatchView(context: context)
        default:
            LockScreenView(context: context)
                .padding()
                .background(Theme.gradient)
        }
    }
}

/// Speed and timer, sized for a Watch card.
private struct SmallWatchView: View {
    let context: ActivityViewContext<WalkActivityAttributes>

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(speedText(context.state.speedKmh))
                    .font(.title2.weight(.bold)).monospacedDigit()
                speedLabel(context.state).font(.caption2)
                Spacer(minLength: 2)
                WalkTimer(state: context.state).font(.subheadline.weight(.semibold).monospacedDigit())
            }
        }
        .padding(8)
        .foregroundStyle(.white)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<WalkActivityAttributes>

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    SlothFaceView().frame(width: 32, height: 32)
                    Text("Amble").font(.headline)
                }
                Spacer()
                WalkTimer(state: context.state)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                metric(speedText(context.state.speedKmh), speedLabel(context.state))
                Spacer()
                metric(distanceText(context.state.distanceMeters), Text("distance"))
                Spacer()
                metric("~\(context.state.steps)", Text("steps"))
                Spacer()
                metric("\(context.state.energyKcal)", Text("kcal"))
            }
        }
        .foregroundStyle(.white)
    }

    private func metric(_ value: String, _ title: Text) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            title.font(.caption).foregroundStyle(.white.opacity(0.75))
        }
    }
}
