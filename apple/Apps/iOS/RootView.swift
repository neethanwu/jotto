import SwiftUI
import UIKit

enum AppTab: Hashable {
    case days, search, account
}

/// Where a tab's navigation stack can go.
enum Route: Hashable {
    case transcript(id: String, at: Double? = nil)
    case live(id: String)
    case server
    case inbox
}

@MainActor @Observable
final class Router {
    var tab = AppTab.days
    var days: [Route] = []
    var search: [Route] = []
    var account: [Route] = []

    /// The floating tab bar shows only on a tab's root screen.
    var showsTabBar: Bool {
        switch tab {
        case .days: days.isEmpty
        case .search: search.isEmpty
        case .account: account.isEmpty
        }
    }
}

struct RootView: View {
    @State private var router = Router()

    var body: some View {
        ZStack(alignment: .bottom) {
            // Keep all three alive so each keeps its scroll position and stack.
            tab(.days) { DaysView(router: router) }
            tab(.search) { SearchView(router: router) }
            tab(.account) { AccountView() }

            if router.showsTabBar {
                TabBar(selection: $router.tab)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: router.showsTabBar)
        .ignoresSafeArea(.keyboard)
        .background(Color.jBg)
    }

    @ViewBuilder
    private func tab<Content: View>(_ which: AppTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: path(which)) {
            content()
                // Hidden tabs stay alive but out of VoiceOver's way.
                .accessibilityHidden(router.tab != which)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .transcript(id, at): TranscriptView(id: id, startAt: at)
                    case let .live(id): LiveView(id: id)
                    case .server: ServerSettingsView(config: .shared)
                    case .inbox: InboxView(inbox: .shared)
                    }
                }
        }
        .opacity(router.tab == which ? 1 : 0)
        .allowsHitTesting(router.tab == which)
        .accessibilityHidden(router.tab != which)
    }

    private func path(_ which: AppTab) -> Binding<[Route]> {
        switch which {
        case .days: $router.days
        case .search: $router.search
        case .account: $router.account
        }
    }
}

// MARK: - Tab bar

/// Floating black pill: the selected tab is an ink-50 capsule with its
/// label, the others are icons only. The capsule slides between tabs.
struct TabBar: View {
    @Binding var selection: AppTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            item(.days, "Days") { DaysIcon(selected: $0) }
            item(.search, "Search") { SearchIcon(color: $0 ? .jOnChromeOn : .ink400) }
            item(.account, "Account") { PersonIcon(color: $0 ? .jOnChromeOn : .ink400) }
        }
        .background {
            // One capsule that follows the selected tab, so it slides
            // rather than fading out in one place and in at another.
            Capsule()
                .fill(Color.jChromeOn)
                .matchedGeometryEffect(id: selection, in: pill, isSource: false)
        }
        .padding(.horizontal, 6)
        .frame(height: 62)
        .chromePill()
        // Only the bar animates; the pages swap instantly underneath.
        .animation(.spring(duration: 0.38, bounce: 0.18), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .padding(.top, 28)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            // Page colour fades in behind the bar so content scrolls under it.
            LinearGradient(
                stops: [.init(color: .jBg.opacity(0), location: 0), .init(color: .jBg, location: 0.45)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 124)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func item<Icon: View>(_ tab: AppTab, _ label: String, @ViewBuilder icon: (Bool) -> Icon) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 8) {
                icon(selected).frame(width: 20, height: 20)
                if selected {
                    Text(label)
                        .font(.label)
                        .foregroundStyle(Color.jOnChromeOn)
                        .lineLimit(1)
                        .fixedSize()
                        // Fade in once the capsule has mostly opened.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.2)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))
                        ))
                }
            }
            .padding(.leading, selected ? (tab == .account ? 14 : 18) : 0)
            .padding(.trailing, selected ? 20 : 0)
            .frame(minWidth: 56)
            .frame(height: 50)
            .matchedGeometryEffect(id: tab, in: pill, isSource: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Switch on touch down, like the system tab bar; the button action
        // still covers VoiceOver and keyboard.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if selection != tab { selection = tab }
        })
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Days icon: the timeline in miniature. A spine with two stops and two
/// lines of text; the top stop is orange when the tab is selected.
/// Drawn on the design's 18-unit grid and scaled to fit.
struct DaysIcon: View {
    var selected: Bool

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 18
            context.scaleBy(x: k, y: k)
            let ink = selected ? Color.jOnChromeOn : Color.ink400
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
            var spine = Path()
            spine.move(to: CGPoint(x: 5, y: 1.5)); spine.addLine(to: CGPoint(x: 5, y: 16.5))
            context.stroke(spine, with: .color(ink), style: style)
            context.fill(Path(ellipseIn: CGRect(x: 2.5, y: 2, width: 5, height: 5)),
                         with: .color(selected ? .jLive : ink))
            let ring = Path(ellipseIn: CGRect(x: 2.8, y: 8.3, width: 4.4, height: 4.4))
            context.fill(ring, with: .color(selected ? .jChromeOn : .jChrome))
            context.stroke(ring, with: .color(ink), style: style)
            var lines = Path()
            lines.move(to: CGPoint(x: 10, y: 4.5)); lines.addLine(to: CGPoint(x: 16, y: 4.5))
            lines.move(to: CGPoint(x: 10, y: 10.5)); lines.addLine(to: CGPoint(x: 15, y: 10.5))
            context.stroke(lines, with: .color(ink), style: style)
        }
        .accessibilityHidden(true)
    }
}

/// Magnifier on the design's 24-unit grid.
struct SearchIcon: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 24
            context.scaleBy(x: k, y: k)
            var p = Path(ellipseIn: CGRect(x: 4, y: 4, width: 14, height: 14))
            p.move(to: CGPoint(x: 20, y: 20)); p.addLine(to: CGPoint(x: 16.5, y: 16.5))
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Head and shoulders on the design's 20-unit grid.
struct PersonIcon: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 20
            context.scaleBy(x: k, y: k)
            var p = Path(ellipseIn: CGRect(x: 6.5, y: 3, width: 7, height: 7))
            p.move(to: CGPoint(x: 3.5, y: 17.5))
            p.addCurve(to: CGPoint(x: 10, y: 12.5), control1: CGPoint(x: 4.3, y: 14.2), control2: CGPoint(x: 6.8, y: 12.5))
            p.addCurve(to: CGPoint(x: 16.5, y: 17.5), control1: CGPoint(x: 13.2, y: 12.5), control2: CGPoint(x: 15.7, y: 14.2))
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Swipe back with a hidden navigation bar

/// Our screens draw their own top bars, which also disables UIKit's
/// edge-swipe to go back. Re-enable it whenever there is somewhere to go.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
