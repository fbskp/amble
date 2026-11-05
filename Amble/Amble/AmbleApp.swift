import SwiftUI

@main
struct AmbleApp: App {
    init() {
        // Create the connection right away, also on a background relaunch by Bluetooth, so iOS can hand the pad link back.
        // Not before the safety notice is accepted: creating it triggers the Bluetooth and Health prompts.
        if Onboarding.isAcknowledged { _ = PadConnection.shared }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
