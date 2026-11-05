import SwiftUI

/// A button that fires once on tap and keeps firing while it is held down.
struct RepeatButton<Label: View>: View {
    var size: CGFloat = 56
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase
    /// Resets by itself when the touch ends or is cancelled (a banner, Control Center, an app switch).
    /// A gesture's onEnded does not run on cancellation, which would leave the repeat running and the belt speeding up.
    @GestureState private var isHeld = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label()
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(isHeld && isEnabled ? 0.30 : 0.15), in: Circle())
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).updating($isHeld) { _, held, _ in held = true })
            .onChange(of: isHeld) { _, held in
                if held { start() } else { stop() }
            }
            .onChange(of: isEnabled) { _, enabled in if !enabled { stop() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
            .onDisappear { stop() }
            .accessibilityAddTraits(.isButton)
    }

    private func start() {
        guard isEnabled, repeatTask == nil else { return }
        action()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func stop() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
