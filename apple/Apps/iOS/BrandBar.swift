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

/// A ring capsule the height of the ring buttons, for "Today".
struct BarPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.scaled(15, .medium, relativeTo: .subheadline))
            .foregroundStyle(Color.jText)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Color.jBg, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.jRing, lineWidth: 1))
            .overlay { Capsule().fill(Color.jText.opacity(configuration.isPressed ? 0.07 : 0)) }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Capsule().inset(by: -4))
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}
