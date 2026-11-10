import SwiftUI

/// The 52-pt top bar on each tab's root screen: the wordmark on the left,
/// sharing a left edge with the big title below, and room on the right.
struct BrandBar<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing

    init(@ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Image("Wordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 28)
                .accessibilityLabel("Jotto")
            Spacer()
            trailing
        }
        .frame(height: 52)
    }
}

/// Small `fill` capsule for secondary actions in the top bar, such as "Today".
struct BarPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.scaled(15, .medium, relativeTo: .subheadline))
            .foregroundStyle(Color.jText)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Color.jFill, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
