import SwiftUI

enum Onboarding {
    /// Raise this when the notice changes materially, so everyone has to read and accept it again.
    static let currentVersion = 1
    static let storageKey = "onboardingVersion"

    static var isAcknowledged: Bool { UserDefaults.standard.integer(forKey: storageKey) >= currentVersion }
}

/// The safety notice: Amble controls a physical machine, so users must know what that means.
struct SafetyNoticeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Amble controls your pad", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            bullet("Amble can start and stop the belt and change its speed.")
            bullet("Verified only with the Sportstech WalkMate. Other pads that use the standard Bluetooth fitness protocol (FTMS) may work, but can behave unexpectedly, for example by changing the speed on its own.")
            bullet("Stay close, keep the belt clear when you start, and know how to stop the pad without the app: its remote or its power switch.")
            bullet("Use Amble at your own risk.")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.4), lineWidth: 1))
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.orange)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Single welcome page, shown once (and again when the notice changes).
struct OnboardingView: View {
    let isBusy: Bool
    /// `true` when the user chose to look around in demo mode instead of connecting a pad.
    let onContinue: (_ demo: Bool) -> Void
    @State private var understood = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                SlothView(speedKmh: 1.2, isAwake: true)
                    .aspectRatio(SlothArt.designSize.width / SlothArt.designSize.height, contentMode: .fit)
                    .frame(maxHeight: 130)
                VStack(spacing: 4) {
                    Text("Welcome to Amble").font(.largeTitle.bold()).foregroundStyle(Theme.textGradient)
                    Text("A calm companion for your walking pad.").foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 14) {
                    feature("figure.walk", "Control your pad", "Start, stop, pause and set the speed over Bluetooth.")
                    feature("heart.fill", "Keep your walks", "Saves each walk to Apple Health, with distance and estimated steps.")
                    feature("target", "Reach your goals", "Set weekly goals and watch the sloth cheer you on.")
                }

                SafetyNoticeCard()

                Toggle(isOn: $understood) {
                    Text("I understand and will stay in control of my pad.").font(.subheadline)
                }
                .toggleStyle(CheckboxToggleStyle())

                Text("Next, iOS asks for Apple Health access, then for Bluetooth.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button { onContinue(false) } label: {
                    Text("Get started")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
                        .opacity(understood ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                Button("No pad at hand? Look around in demo mode") { onContinue(true) }
                    .font(.subheadline)
                    .padding(.vertical, 6)
            }
            .disabled(!understood || isBusy)
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
        }
        .tint(Theme.accent)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Theme.accent : .secondary)
                configuration.label.multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
    }
}
