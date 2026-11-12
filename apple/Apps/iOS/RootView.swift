import SwiftUI
import UIKit

/// Days, Send, Settings. Search lives on Days.
enum AppTab: Hashable {
    case days, send, settings
}

/// Where a tab's stack can go.
enum Route: Hashable {
    case transcript(id: String, at: Double? = nil, rename: Bool = false)
    case processing
    case language
    case keepAudio
    case openIn
    case inbox
}

@MainActor @Observable
final class Router {
    /// A recording in progress, open over everything. A cover rather than
    /// a push: forcing dark inside a push turns the whole window dark.
    struct Live: Identifiable, Hashable { let id: String }

    var tab = AppTab.days
    var live: Live?
    /// Bumped when Days is tapped while already showing: back to today.
    var daysReselected = 0
    var days: [Route] = []
    var send: [Route] = []
    var settings: [Route] = []

    /// The floating tab bar shows only on a tab's root screen.
    var showsTabBar: Bool {
        switch tab {
        case .days: days.isEmpty
        case .send: send.isEmpty
        case .settings: settings.isEmpty
        }
    }
}

struct RootView: View {
    @State private var router = Router()

    var body: some View {
        ZStack(alignment: .bottom) {
            // Keep both alive so each keeps its scroll position and stack.
            tab(.days) { DaysView(router: router) }
            tab(.send) { SendView(router: router) }
            tab(.settings) { SettingsView(router: router) }

            if router.showsTabBar {
                TabBar(selection: $router.tab) { tab in
                    if tab == .days { router.daysReselected += 1 }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: router.showsTabBar)
        .ignoresSafeArea(.keyboard)
        .background(Color.jBg)
        .fullScreenCover(item: $router.live) {
            // Clear behind it, so pulling it down shows the app underneath.
            LiveView(id: $0.id).presentationBackground(.clear)
        }
        // The lock-screen activity or the island was tapped: jotto://live/<id>.
        .onOpenURL { url in
            guard url.scheme == "jotto", url.host() == "live" else { return }
            let id = url.lastPathComponent
            if LocalStore.shared.recordings[id]?.endedAt == nil {
                router.live = Router.Live(id: id)
            } else {
                router.tab = .days
                router.days = [.transcript(id: id)]
            }
        }
        // A "ready" notice was tapped.
        .onChange(of: Notifier.shared.opening, initial: true) { _, id in
            guard let id else { return }
            router.live = nil
            router.tab = .days
            router.days = [.transcript(id: id)]
            Notifier.shared.opening = nil
        }
    }

    @ViewBuilder
    private func tab<Content: View>(_ which: AppTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: path(which)) {
            content()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .transcript(id, at, rename): TranscriptView(id: id, startAt: at, startsRenaming: rename)
                    case .processing: ProcessingView()
                    case .language: LanguageView()
                    case .keepAudio: KeepAudioView()
                    case .openIn: OpenInView()
                    case .inbox: InboxView(inbox: .shared)
                    }
                }
        }
        .opacity(router.tab == which ? 1 : 0)
        .allowsHitTesting(router.tab == which)
        // Hidden tabs stay alive but out of VoiceOver's way.
        .accessibilityHidden(router.tab != which)
    }

    private func path(_ which: AppTab) -> Binding<[Route]> {
        switch which {
        case .days: $router.days
        case .send: $router.send
        case .settings: $router.settings
        }
    }
}

/// Two sliders on the design's 20-unit grid: settings.
struct SlidersIcon: View {
    var color: Color = .jText
    /// Fill inside the knobs: the background the icon sits on, so the
    /// track stops at the ring. The knobs stay rings when selected.
    var knob: Color = .jFill

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 20
            context.scaleBy(x: k, y: k)
            let style = StrokeStyle(lineWidth: 1.6, lineCap: .round)
            var lines = Path()
            lines.move(to: CGPoint(x: 2.5, y: 6)); lines.addLine(to: CGPoint(x: 17.5, y: 6))
            lines.move(to: CGPoint(x: 2.5, y: 14)); lines.addLine(to: CGPoint(x: 17.5, y: 14))
            context.stroke(lines, with: .color(color), style: style)
            for center in [CGPoint(x: 7, y: 6), CGPoint(x: 13, y: 14)] {
                let ring = Path(ellipseIn: CGRect(x: center.x - 2.3, y: center.y - 2.3, width: 4.6, height: 4.6))
                context.fill(ring, with: .color(self.knob))
                context.stroke(ring, with: .color(color), style: style)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tab bar

/// Floating black pill: the selected tab is an ink-50 capsule with its
/// label, the others are icons only. The capsule slides between tabs.
struct TabBar: View {
    @Binding var selection: AppTab
    /// Tapping the tab that's already selected.
    var onReselect: (AppTab) -> Void = { _ in }
    @Namespace private var pill
    /// When the selection last changed. A tap only counts as tapping the
    /// tab already shown (Days: back to today) if it had been shown for a
    /// moment; the tap that just switched to it doesn't. The order of the
    /// touch and the button's action isn't reliable enough to go by.
    @State private var changedAt = Date.distantPast

    var body: some View {
        HStack(spacing: 4) {
            item(.days, "Days") { DaysIcon(selected: $0) }
            // The selected tab's glyph fills in.
            item(.send, "Send") { GlyphView(glyph: $0 ? .sendFilled : .send, color: $0 ? .jOnChromeOn : .ink400) }
            item(.settings, "Settings") { SlidersIcon(color: $0 ? .jOnChromeOn : .ink400, knob: $0 ? .jChromeOn : .jChrome) }
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
        .onChange(of: selection) { changedAt = .now }
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
            .padding(.leading, selected ? 18 : 0)
            .padding(.trailing, selected ? 20 : 0)
            .frame(minWidth: 56)
            .frame(height: 50)
            .matchedGeometryEffect(id: tab, in: pill, isSource: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Switch on touch down, like the system tab bar; the button action
        // still covers VoiceOver and keyboard.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if selection != tab { selection = tab }
                }
                .onEnded { value in
                    let tapped = abs(value.translation.width) < 20 && abs(value.translation.height) < 20
                    if tapped, selection == tab, Date.now.timeIntervalSince(changedAt) > 0.8 { onReselect(tab) }
                }
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Days icon: the timeline in miniature. Two stops the same size on a
/// spine that carries on below, each with a line of text; the top stop
/// is a solid dot (orange when the tab is selected), the second a ring.
/// Drawn on the design's 20-unit grid, the same as the settings icon.
struct DaysIcon: View {
    var selected: Bool

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 20
            context.scaleBy(x: k, y: k)
            let ink = selected ? Color.jOnChromeOn : Color.ink400
            let style = StrokeStyle(lineWidth: 1.6, lineCap: .round)
            var spine = Path()
            spine.move(to: CGPoint(x: 5.5, y: 8.6)); spine.addLine(to: CGPoint(x: 5.5, y: 11.4))
            spine.move(to: CGPoint(x: 5.5, y: 16.6)); spine.addLine(to: CGPoint(x: 5.5, y: 18.2))
            context.stroke(spine, with: .color(ink), style: style)
            context.fill(Path(ellipseIn: CGRect(x: 2.9, y: 2.9, width: 5.2, height: 5.2)),
                         with: .color(selected ? .jLive : ink))
            context.stroke(Path(ellipseIn: CGRect(x: 3.7, y: 12.2, width: 3.6, height: 3.6)),
                           with: .color(ink), style: style)
            var lines = Path()
            lines.move(to: CGPoint(x: 10.5, y: 5.5)); lines.addLine(to: CGPoint(x: 17.5, y: 5.5))
            lines.move(to: CGPoint(x: 10.5, y: 14)); lines.addLine(to: CGPoint(x: 15.5, y: 14))
            context.stroke(lines, with: .color(ink), style: style)
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
