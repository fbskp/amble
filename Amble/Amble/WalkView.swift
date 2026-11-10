import SwiftUI
import AmbleCore

struct WalkView: View {
    private let pad = PadConnection.shared
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showPresets = false
    @Environment(\.units) private var units
    /// Height this screen has between the bars. The sloth, the gap above it and the speed are sized from it,
    /// so the proportions hold from a small iPhone to an unfolded one.
    @State private var availableHeight: CGFloat = 0

    /// Proportions taken from a standard iPhone, where the screen has about 680 pt between the bars.
    private func share(_ fraction: CGFloat, fallback: CGFloat) -> CGFloat {
        availableHeight > 0 ? availableHeight * fraction : fallback
    }
    private var slothMaxHeight: CGFloat { share(0.36, fallback: 220) }
    private var topGap: CGFloat { share(0.025, fallback: 16) }
    private var speedFontSize: CGFloat { min(max(share(0.12, fallback: 80), 60), 120) }

    var body: some View {
        VStack(spacing: 14) {
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
            // A small gap above; the free room goes below, between the read-outs and the controls.
            Spacer(minLength: 0).frame(maxHeight: topGap)
            VStack(spacing: 4) {
                // Slower and faster flank the sloth, far from Pause and Stop, so a tap while walking cannot hit those.
                // The buttons sit over the empty margins of the artwork, so the sloth can use the full width.
                ZStack {
                    // The sloth gives way first when the screen is short.
                    SlothView(speedKmh: pad.data.speedKmh ?? 0, isAwake: pad.isBeltActive || pad.isStopping || (pad.data.speedKmh ?? 0) > 0.1,
                              companion: GoalsStore.shared.companion)
                        .aspectRatio(SlothArt.designSize.width / SlothArt.designSize.height, contentMode: .fit)
                        .frame(minHeight: 70, maxHeight: slothMaxHeight)
                    HStack {
                        stepButton("minus", delta: -0.1)
                        Spacer()
                        stepButton("plus", delta: 0.1)
                    }
                }
                .disabled(!pad.canControl || !pad.isBeltActive)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(units.speed(pad.data.speedKmh ?? 0), format: .number.precision(.fractionLength(1)))
                        .font(.system(size: speedFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Theme.textGradient)
                    Group { if pad.isPaused { Text("paused") } else { Text(verbatim: units.speedSymbol) } }
                        .font(.title3)
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
                    metric("Distance", units.distance(Double(pad.sessionDistanceMeters)))
                }
                GridRow {
                    metric("Time", Self.clock(pad.sessionSeconds))
                    metric("Energy", "\(pad.sessionEnergyKcal) kcal")
                }
            }
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal)
        .padding(.bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        // No title: the speed is this screen's headline, and the tab already says where you are.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .tint(Theme.accent)
        .alert(pad.healthQueue.alert?.title ?? "",
               isPresented: Binding(get: { pad.healthQueue.alert != nil }, set: { if !$0 { pad.healthQueue.dismissAlert() } }),
               presenting: pad.healthQueue.alert) { _ in
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

    /// The system navigation bar holds the title, so it keeps clear of rounded display corners on every device.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showPicker = true } label: {
                // Icon and text side by side, not a `Label`: a toolbar shows a Label as its icon only.
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(connectionColor)
                    Text(connectionText).font(.footnote).foregroundStyle(connectionColor)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .fixedSize()
                .padding(.horizontal, 4)
            }
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
        case .idle:
            switch pad.releaseReason {
            case .auto: String(localized: "Disconnected, pad is free")
            case .user: String(localized: "Disconnected")
            case nil: String(localized: "Select a pad")
            }
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

    private var canPickSpeed: Bool { pad.canControl && pad.isBeltActive }

    private var presets: some View {
        HStack(spacing: 10) {
            ForEach(pad.quickSpeeds(kmPerUnit: units.kmPerSpeedUnit), id: \.self) { value in
                Button(value.formatted(.number.precision(.fractionLength(0...1)))) {
                    pad.setSpeed(value * units.kmPerSpeedUnit)
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
        RepeatButton(size: 56) { pad.changeSpeed(by: delta, kmPerUnit: units.kmPerSpeedUnit) } label: {
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
