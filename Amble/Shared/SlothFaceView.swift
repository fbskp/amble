import SwiftUI

/// The chosen animal's face (the sloth by default) as a small icon. Static, so it also works in widgets.
struct SlothFaceView: View {
    var companion: Companion = .current

    var body: some View {
        Canvas { ctx, size in
            var c = ctx
            companion.drawFace(&c, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
