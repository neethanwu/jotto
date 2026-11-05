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
/// label, the others are icons only.
struct TabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 4) {
            item(.days, "Days") { DaysIcon(selected: selection == .days) }
            item(.search, "Search") { Image(systemName: "magnifyingglass") }
            item(.account, "Account") { Image(systemName: "person") }
        }
        .padding(6)
        .frame(height: 62)
        .chromePill()
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

    private func item<Icon: View>(_ tab: AppTab, _ label: String, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 8) {
                icon().font(.system(size: 18, weight: .semibold)).frame(width: 20, height: 20)
                if selected {
                    Text(label).font(.label).lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Color.jOnChromeOn : Color.ink400)
            .padding(.leading, selected ? 18 : 0)
            .padding(.trailing, selected ? 20 : 0)
            .frame(minWidth: 56, minHeight: 50)
            .background(selected ? Color.jChromeOn : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: selection)
    }
}

/// Days icon: an orange dot over a short line, the timeline in miniature.
struct DaysIcon: View {
    var selected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Circle().fill(Color.jLive).frame(width: 8, height: 8)
            Capsule().fill(selected ? Color.ink950 : Color.ink400).frame(width: 2, height: 9)
        }
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
