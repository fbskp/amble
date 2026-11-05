import SwiftUI

/// The title row of a main screen. All three tabs draw it themselves, so the title sits at the same height and the same inset on each,
/// close below the status bar (a navigation bar would add its own empty 44 pt strip above a large title).
struct ScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var style: AnyShapeStyle = AnyShapeStyle(.primary)
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(style)
                .accessibilityAddTraits(.isHeader)
            trailing()
        }
        .padding(.top, 8)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title: title, trailing: { EmptyView() })
    }
}
