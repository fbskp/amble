import SwiftUI

/// The sloth's face as a small icon. Static, so it also works in widgets.
struct SlothFaceView: View {
    var body: some View {
        Canvas { ctx, size in
            var c = ctx
            SlothArt.drawFace(&c, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
