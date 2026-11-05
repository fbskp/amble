import Foundation

/// Web addresses the app opens. They only open in the browser when the user taps a link.
enum Links {
    static let repository = "https://github.com/fbskp/amble"

    /// The policy in the language the app is shown in (German, otherwise English).
    static var privacyPolicy: URL {
        let german = Bundle.main.preferredLocalizations.first == "de"
        return URL(string: repository + "/blob/main/" + (german ? "PRIVACY.de.md" : "PRIVACY.md"))!
    }
}
