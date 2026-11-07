import SwiftUI
import AmbleCore

struct WalkView: View {
    private let pad = PadConnection.shared
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showPresets = false

    var body: some View {
        VStack(spacing: 14) {
            // All three tabs draw their title with `ScreenHeader`, so it sits in the same place on each.
            header
            // No step length in Health: a quiet hint instead of a dialog; the step estimate needs it.
            if pad.stride.needsSetup {
                Button { showSettings = true } label: {
                    Label("Set your step length for better step counts", systemImage: "figure.walk.motion")
                        .font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                // Slower and faster flank the sloth, far from Pause and Stop, so a tap while walking cannot hit those.
                HStack(spacing: 10) {
                    stepButton("minus", delta: -0.1)
                    // The sloth gives way first when the screen is short.
                    SlothView(speedKmh: pad.data.speedKmh ?? 0, isAwake: pad.isBeltActive || pad.isStopping || (pad.data.speedKmh ?? 0) > 0.1,
                              companion: GoalsStore.shared.companion)
                        .aspectRatio(SlothArt.designSize.width / SlothArt.designSize.height, contentMode: .fit)
                        .frame(minHeight: 70, maxHeight: 150)
                    stepButton("plus", delta: 0.1)
                }
                .disabled(!pad.canControl || !pad.isBeltActive)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pad.data.speedKmh ?? 0, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Theme.textGradient)
                    Text(pad.isPaused ? "paused" : "km/h").font(.title3)
                        .foregroundStyle(pad.isPaused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    if canPickSpeed {
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                // Tapping the speed opens the quick-pick speeds, so they take no room on the screen.
                .contentShape(Rectangle())
                .onTapGesture { if canPickSpeed { showPresets = true } }
                .popover(isPresented: $showPresets) { presets }
                .presentationCompactAdaptation(.popover)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(canPickSpeed ? "Opens quick speeds" : "")
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    metric("Steps (est.)", "\(pad.sessionSteps)")
                    metric("Distance", Self.distance(pad.sessionDistanceMeters))
                }
                GridRow {
                    metric("Time", Self.clock(pad.sessionSeconds))
                    metric("Energy", "\(pad.data.energyTotalKcal ?? 0) kcal")
                }
            }
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal)
        .padding(.bottom)
        .tint(Theme.accent)
        .alert(pad.healthAlert?.title ?? "",
               isPresented: Binding(get: { pad.healthAlert != nil }, set: { if !$0 { pad.dismissHealthAlert() } }),
               presenting: pad.healthAlert) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        .sheet(isPresented: $showPicker) { DevicePickerView(pad: pad) }
        .sheet(isPresented: $showSettings) { SettingsView(stride: pad.stride) }
        .onChange(of: pad.keepScreenOn) { _, active in
            // Keep the screen on while the belt runs; the phone may otherwise lock mid-walk.
            UIApplication.shared.isIdleTimerDisabled = active
        }
    }

    private var header: some View {
        ScreenHeader(title: "Amble", style: AnyShapeStyle(Theme.textGradient)) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button { showPicker = true } label: {
                Label(connectionText, systemImage: "circle.fill")
                    .font(.footnote)
                    .foregroundStyle(connectionColor)
                    .labelStyle(.titleAndIcon)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Large filled button used for Start and Stop.
    private func bigButton(_ title: LocalizedStringKey, fill: some ShapeStyle, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(fill, in: RoundedRectangle(cornerRadius: 14))
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var connectionText: String {
        switch pad.state {
        case .bluetoothUnavailable(let why): why
        case .idle: pad.isReleased ? String(localized: "Disconnected") : String(localized: "Select a pad")
        case .connecting: String(localized: "Connecting to \(pad.deviceName ?? String(localized: "pad"))...")
        case .connected: pad.isDemo ? String(localized: "Demo mode") : (pad.deviceName ?? String(localized: "Connected"))
        case .disconnected: String(localized: "Pad not reachable")
        }
    }

    private var connectionColor: Color {
        switch pad.state {
        case .connected: pad.isDemo ? Theme.accent : .green
        case .connecting: .orange
        default: .red
        }
    }

    /// Whole metres below 1 km, kilometres with two decimals above.
    private static func distance(_ meters: Int) -> String {
        meters < 1000 ? "\(meters) m" : "\((Double(meters) / 1000).formatted(.number.precision(.fractionLength(2)))) km"
    }

    private var canPickSpeed: Bool { pad.canControl && pad.isBeltActive }

    private var presets: some View {
        HStack(spacing: 10) {
            ForEach([1.0, 2.0, 3.0, 4.0, 5.0], id: \.self) { kmh in
                Button(String(format: "%.0f", kmh)) {
                    pad.setSpeed(kmh)
                    showPresets = false
                }
                .buttonStyle(.bordered)
                .font(.title3.weight(.semibold))
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }

    /// Both buttons are the same circle, so minus and plus look equally large.
    private func stepButton(_ symbol: String, delta: Double) -> some View {
        RepeatButton(size: 56) { pad.changeSpeed(by: delta) } label: {
            Image(systemName: symbol).font(.title2.weight(.bold))
        }
        .accessibilityLabel(delta > 0 ? "Faster" : "Slower")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let error = pad.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if pad.isPaused {
                HStack(spacing: 12) {
                    bigButton("Resume", fill: Theme.gradient, enabled: pad.canControl) { pad.resume() }
                    bigButton("Finish", fill: Color.red, enabled: pad.canControl) { pad.stop() }
                }
            } else if pad.isBeltActive {
                HStack(spacing: 12) {
                    // A pad that rejected pause only gets Stop, instead of a button that never works.
                    if pad.pauseSupported { bigButton("Pause", fill: Theme.teal) { pad.pause() } }
                    bigButton("Stop", fill: Color.red) { pad.stop() }
                }
            } else {
                bigButton(pad.isStopping ? "Stopping..." : "Start", fill: Theme.gradient,
                          enabled: pad.canControl && !pad.isStopping) { pad.start() }
            }
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
