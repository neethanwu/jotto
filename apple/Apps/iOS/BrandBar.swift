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

/// A tab's page under a wordmark bar that stays put. The page scrolls
/// beneath it, and a hairline appears once anything has gone under.
struct TabPage<Trailing: View, Content: View>: View {
    let trailing: Trailing
    let content: Content
    @State private var scrolled = false

    init(@ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            BrandBar { trailing }
                .padding(.horizontal, 20)
                .background(Color.jBg)
                .overlay(alignment: .bottom) { ScrollEdgeLine(visible: scrolled) }
                .zIndex(1)
            ScrollView { content }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0.5 } action: { _, now in
                    scrolled = now
                }
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The hairline under a fixed header, shown once content scrolls under it.
struct ScrollEdgeLine: View {
    let visible: Bool

    var body: some View {
        Rectangle().fill(Color.jHairline).frame(height: 1)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: visible)
            .accessibilityHidden(true)
    }
}
