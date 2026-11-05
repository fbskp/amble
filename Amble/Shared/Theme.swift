import SwiftUI

/// Colours taken from the app icon (teal to green), shared by the app and the Live Activity.
enum Theme {
    static let teal = Color(red: 0.04, green: 0.35, blue: 0.40)
    static let green = Color(red: 0.30, green: 0.78, blue: 0.45)
    /// Mid tone that stays readable on both light and dark backgrounds; used as the app tint.
    static let accent = Color(red: 0.10, green: 0.60, blue: 0.48)
    /// Lighter teal for gradient text, so it also reads on dark backgrounds.
    static let textTeal = Color(red: 0.10, green: 0.55, blue: 0.58)
    /// Light green for the minutes ring and its legend.
    static let mint = Color(red: 0.55, green: 0.90, blue: 0.62)

    static let gradient = LinearGradient(colors: [teal, green], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let textGradient = LinearGradient(colors: [textTeal, green], startPoint: .leading, endPoint: .trailing)
}
