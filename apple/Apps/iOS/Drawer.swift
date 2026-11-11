import SwiftUI

// MARK: - Drawer

/// A panel that rises from the bottom edge: full width, running under the
/// home indicator, only its top corners rounded. iOS 26 shows a part-height
/// sheet as a card floating clear of the sides and bottom, which is not
/// what a drawer is, so this one is drawn by hand over a clear cover.
extension View {
    func drawer<Item: Identifiable, Panel: View>(
        item: Binding<Item?>, @ViewBuilder panel: @escaping (Item) -> Panel
    ) -> some View {
        modifier(DrawerItemModifier(item: item, panel: panel))
    }

    func drawer<Panel: View>(
        isPresented: Binding<Bool>, @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        modifier(DrawerFlagModifier(isPresented: isPresented, panel: panel))
    }
}

extension EnvironmentValues {
    /// Slides the drawer away. Nil outside a drawer.
    @Entry var closeDrawer: (() -> Void)?
}

private func withoutAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

private struct DrawerItemModifier<Item: Identifiable, Panel: View>: ViewModifier {
    @Binding var item: Item?
    let panel: (Item) -> Panel
    /// The cover itself appears without the system's slide; the drawer
    /// animates on its own inside it.
    @State private var shown: Item?

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id) { _, id in
                if id != nil, shown == nil { withoutAnimation { shown = item } }
            }
            .fullScreenCover(item: $shown) { value in
                DrawerCover(onGone: {
                    withoutAnimation { shown = nil }
                    item = nil
                }) { panel(value) }
            }
    }
}

private struct DrawerFlagModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let panel: () -> Panel
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, now in
                if now, !shown { withoutAnimation { shown = true } }
            }
            .fullScreenCover(isPresented: $shown) {
                DrawerCover(onGone: {
                    withoutAnimation { shown = false }
                    isPresented = false
                }) { panel() }
            }
    }
}

private struct DrawerCover<Panel: View>: View {
    let onGone: () -> Void
    @ViewBuilder let panel: Panel

    @State private var open = false
    @State private var drag: CGFloat = 0
    @State private var closing = false
    @State private var panelHeight: CGFloat = 0

    private let radius: CGFloat = 32
    private static var space: String { "drawer" }
    /// The grabber and the title row: a pull that starts lower belongs to
    /// the list, which may scroll.
    private let handle: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            let height = (geo.size.height * 0.9).rounded()
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(open ? 0.3 * max(0, 1 - drag / max(panelHeight, 1)) : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)

                if open {
                    VStack(spacing: 0) {
                        Capsule().fill(Color.jText5).frame(width: 36, height: 5)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 10)
                            .padding(.bottom, 14)
                            .accessibilityHidden(true)
                        panel
                            .environment(\.closeDrawer, close)
                    }
                    .frame(maxWidth: .infinity)
                    // As tall as its content, up to nine tenths of the screen.
                    .modifier(CapHeight(height: height))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                    .background {
                        // Runs on past the bottom edge, so a pull upward
                        // never shows a gap beneath it.
                        UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius,
                                               style: .continuous)
                            .fill(Color.jSheet)
                            .padding(.bottom, -400)
                            .ignoresSafeArea(edges: .bottom)
                    }
                    .offset(y: drag)
                    .simultaneousGesture(pull(height: panelHeight, top: geo.size.height - panelHeight))
                    .transition(.move(edge: .bottom))
                    .accessibilityAction(.escape) { close() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .coordinateSpace(.named(Self.space))
        }
        .presentationBackground(.clear)
        .onAppear {
            withAnimation(.spring(duration: 0.42, bounce: 0.06)) { open = true }
        }
    }

    /// Down past a third of the way, or flicked, closes; up gives a little.
    private func pull(height: CGFloat, top: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard !closing, value.startLocation.y - top < handle else { return }
                let dy = value.translation.height
                drag = dy >= 0 ? dy : -sqrt(-dy) * 2
            }
            .onEnded { value in
                guard !closing, value.startLocation.y - top < handle else { return }
                let dy = value.translation.height
                if dy > height / 3 || value.predictedEndTranslation.height > height * 0.6 {
                    close()
                } else {
                    withAnimation(.spring(duration: 0.32, bounce: 0.1)) { drag = 0 }
                }
            }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(.spring(duration: 0.3, bounce: 0)) {
            open = false
        } completion: {
            onGone()
        }
    }
}

/// Offers the panel no more than `height` and takes the size it asks for,
/// so a short panel stays short and a long one stops below the top.
private struct CapHeight: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        CapLayout(height: height) { content }
    }
}

private struct CapLayout: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let capped = ProposedViewSize(width: proposal.width, height: min(proposal.height ?? height, height))
        return subviews.first?.sizeThatFits(capped) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
