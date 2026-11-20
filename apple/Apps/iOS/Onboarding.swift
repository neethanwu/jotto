import SwiftUI
import UserNotifications

/// Four pages the first time jotto opens: what it does, the watch, the
/// "ready" notice and location. Each page's button is what brings up iOS's
/// own prompt for it, so nothing is asked before it's been explained, and
/// the back button (or a swipe) returns to one that was skipped.
enum Onboarding {
    static let key = "onboarded"

    static var isDone: Bool { UserDefaults.standard.bool(forKey: key) }

    /// First thing at launch, before anything else writes to Documents:
    /// someone updating from an earlier jotto has been through it already,
    /// in effect, and doesn't see it.
    static func settle() {
        let defaults = UserDefaults.standard
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") {
            defaults.set(false, forKey: key)
            return
        }
        #endif
        guard defaults.object(forKey: key) == nil else { return }
        let files = FileManager.default
        let used = files.fileExists(atPath: Inbox.directory.path) || files.fileExists(atPath: LocalStore.directory.path)
        defaults.set(used, forKey: key)
    }
}

struct OnboardingView: View {
    let finish: () -> Void

    @State private var page = 0
    /// Which way the last page turn went, so the words slide with it.
    @State private var forward = true
    @State private var notifications: UNAuthorizationStatus?
    @State private var waitingForPlaces = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private var inbox: Inbox { .shared }
    private var places: PlaceTracker { .shared }

    private var watchApp: Inbox.WatchApp {
        #if DEBUG
        // `-onboardingWatch installed` (or notInstalled, noWatch) shows that
        // page as it would be, in the simulator.
        switch UserDefaults.standard.string(forKey: "onboardingWatch") {
        case "installed": return .installed
        case "notInstalled": return .notInstalled
        case "noWatch": return .noWatch
        default: break
        }
        #endif
        return inbox.watchApp
    }

    private static let pages = 4
    /// The figure is drawn for this height and scaled down to fit smaller screens.
    private static let figureHeight: CGFloat = 430

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            GeometryReader { geo in
                let k = min(1, geo.size.height / Self.figureHeight)
                figure(width: geo.size.width / k)
                    .frame(width: geo.size.width / k, height: Self.figureHeight)
                    .scaleEffect(k)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 220, maxHeight: Self.figureHeight)
            copy
            Spacer(minLength: 16)
            actions
        }
        .background(Color.jBg.ignoresSafeArea())
        .contentShape(Rectangle())
        // Swiping turns the pages too: right goes back, left goes on
        // without asking for anything.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { drag in
                let x = drag.translation.width
                guard abs(x) > 60, abs(x) > abs(drag.translation.height) * 1.5 else { return }
                if x > 0 { back() } else if page < Self.pages - 1 { turn(to: page + 1) }
            }
        )
        .task { await readNotifications() }
        // Back from iOS Settings, where notifications may have been turned on.
        .onChange(of: scenePhase) { _, now in
            if now == .active { Task { await readNotifications() } }
        }
        // iOS answered the location prompts. With While Using it asks
        // about Always straight after, over these pages, and only Always
        // is heard back: then they close. Otherwise they stay, and the
        // button has become Continue.
        .onChange(of: places.permission) { _, now in
            guard waitingForPlaces, now != .notDetermined, now != .authorizedWhenInUse else { return }
            waitingForPlaces = false
            if now == .authorizedAlways {
                Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    if page == Self.pages - 1 { finish() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<Self.pages, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.jText : OnboardingColor.track)
                        .frame(width: i == page ? 22 : 8, height: 4)
                }
            }
            .animation(motion, value: page)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(Self.pages)")

            Button { back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.jText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(page > 0 ? 1 : 0)
            .disabled(page == 0)
            .accessibilityHidden(page == 0)
            .animation(.easeOut(duration: 0.2), value: page > 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    // MARK: - Figure

    /// Every page's art is always there, so each can leave and arrive in
    /// its own way: the watch turns to face you, the notice drops onto the
    /// lock screen, the pin drops into the park. While its page is shown,
    /// each acts out what the page is for (`OnboardingScenes`).
    private func figure(width: CGFloat) -> some View {
        ZStack {
            WelcomeScene(shown: page == 0, reduceMotion: reduceMotion, motion: motion)
            WatchScene(page: page, state: watchApp, reduceMotion: reduceMotion, motion: motion, later: later)
            LockScene(page: page, asks: notifications == .notDetermined, reduceMotion: reduceMotion, motion: motion)
            PlacesScene(page: page, asks: !places.isOn, reduceMotion: reduceMotion, motion: motion)
        }
        .frame(width: width, height: Self.figureHeight)
        // Pictures only: the page's words say it, and VoiceOver shouldn't
        // read out every page's picture at once.
        .accessibilityHidden(true)
    }

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.6, bounce: 0.12)
    }

    private func later(_ delay: Double) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.55, bounce: 0.18).delay(delay)
    }

    // MARK: - Words

    private struct Words {
        var title: String
        var body: String
        var primary: String
        var secondary: String?
    }

    private var words: Words {
        switch page {
        case 0:
            return Words(title: "You talk.\njotto writes it down.",
                         body: "Record on your Apple Watch. A minute after each part, the words are on your iPhone, cleaned up.",
                         primary: "Continue")
        case 1:
            let title = "Recording happens\non your wrist."
            switch watchApp {
            case .notInstalled:
                return Words(title: title,
                             body: "jotto records on your Apple Watch. Install it there first: in the Watch app on this iPhone, find jotto under Available Apps and tap Install.",
                             primary: "Open the Watch app", secondary: "Later")
            case .noWatch:
                return Words(title: title,
                             body: "jotto records on Apple Watch. Pair one and jotto is there to install from the Watch app. Until then, record on this iPhone with the dot at the bottom of Days.",
                             primary: "Continue")
            case .installed, .unknown:
                return Words(title: title,
                             body: "Tap the dot to record, and hold it to stop. The first time, your watch asks for its microphone and to send you notices: allow both.",
                             primary: "Continue")
            }
        case 2:
            let body = "Recordings turn into text while jotto is closed. A notice tells you when one is ready, with its title."
            switch notifications {
            case .notDetermined:
                return Words(title: "Know when\nit's written.", body: body, primary: "Allow notifications", secondary: "Not now")
            case .denied:
                return Words(title: "Know when\nit's written.", body: body, primary: "Allow in Settings", secondary: "Not now")
            default:
                return Words(title: "Know when\nit's written.", body: body, primary: "Continue")
            }
        default:
            return Words(title: "Remember where\nyou said it.",
                         body: "Each recording keeps where it was said, and your watch's recordings turn into text as you talk, even with this iPhone locked. Locations stay on this iPhone.",
                         primary: places.isOn ? "Continue" : places.isDenied ? "Allow in Settings" : "Allow location",
                         secondary: places.isOn ? nil : "Not now")
        }
    }

    private var copy: some View {
        // The old words leave as the new ones come, so the animation sits
        // on a container that stays.
        ZStack(alignment: .topLeading) {
            wordsView
                .id(page)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: forward ? 24 : -24)),
                    removal: .opacity.combined(with: .offset(x: forward ? -24 : 24))))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion, value: page)
    }

    private var wordsView: some View {
        let words = words
        return VStack(alignment: .leading, spacing: 12) {
            Text(words.title)
                .font(.scaled(34, .bold, relativeTo: .largeTitle))
                .tracking(-1)
                .foregroundStyle(Color.jText)
                .accessibilityAddTraits(.isHeader)
            Text(words.body)
                .font(.scaled(17, .regular, relativeTo: .body))
                .lineSpacing(3)
                .foregroundStyle(Color.jText2)
            if page == 1 {
                watchStatus
                    .padding(.top, 4)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 8)
    }

    /// Whether jotto is on the paired watch, as it is now, in plain words
    /// beside the page's, not in the picture, which only acts things out.
    private var watchStatus: some View {
        HStack(spacing: 8) {
            Group {
                switch watchApp {
                case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.jText)
                case .notInstalled: Image(systemName: "arrow.down.circle").foregroundStyle(Color.jText2)
                case .noWatch: Image(systemName: "applewatch.slash").foregroundStyle(Color.jText2)
                case .unknown: ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 18)
            Text(watchStatusText)
                .font(.scaled(15, .semibold, relativeTo: .subheadline))
                .foregroundStyle(Color.jText)
        }
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.25), value: watchApp)
        .accessibilityElement(children: .combine)
    }

    private var watchStatusText: String {
        switch watchApp {
        case .installed: "jotto is on your Apple Watch"
        case .notInstalled: "Not on your Apple Watch yet"
        case .noWatch: "No Apple Watch paired"
        case .unknown: "Looking for your Apple Watch"
        }
    }

    // MARK: - Buttons

    private var actions: some View {
        let words = words
        return VStack(spacing: 4) {
            Button { primary() } label: {
                Text(words.primary)
                    .font(.scaled(17, .semibold, relativeTo: .body))
                    .foregroundStyle(Color.jBg)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.jText, in: Capsule())
                    .contentTransition(.opacity)
            }
            .buttonStyle(PressStyle())

            // Kept in place when there's none, so the button doesn't move.
            Button { secondary() } label: {
                Text(words.secondary ?? " ")
                    .font(.scaled(17, .medium, relativeTo: .body))
                    .foregroundStyle(Color.jText2)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(words.secondary == nil ? 0 : 1)
            .disabled(words.secondary == nil)
            .accessibilityHidden(words.secondary == nil)
        }
        .animation(.easeOut(duration: 0.2), value: words.primary)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    /// The words take the direction first, then the page turns, so the
    /// old words leave the way they should.
    private func turn(to next: Int) {
        guard next != page, (0..<Self.pages).contains(next) else { return }
        forward = next > page
        Task { @MainActor in
            page = next
            PhoneLog.shared.note("onboarding", "page \(next)")
        }
    }

    private func next() {
        guard page < Self.pages - 1 else { return finish() }
        turn(to: page + 1)
    }

    private func back() {
        waitingForPlaces = false
        turn(to: page - 1)
    }

    private func primary() {
        switch page {
        case 1 where watchApp == .notInstalled:
            // The Watch app, where jotto waits under Available Apps; the
            // page turns to "on your watch" when it's installed.
            if let url = URL(string: "itms-watchs://") { openURL(url) }
        case 2 where notifications == .notDetermined:
            Task {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                PhoneLog.shared.note("notify_permission", granted ? "granted" : "denied")
                // Settings → Notify when ready shows what was chosen.
                AppConfig.shared.notifiesWhenReady = granted
                await readNotifications()
                next()
            }
        case 2 where notifications == .denied:
            // Turned off before: only iOS Settings can turn it back on.
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        case 3 where !places.isOn:
            PhoneLog.shared.note("onboarding", "places on")
            if places.needsAsking {
                waitingForPlaces = true
                places.turnOn()
            } else {
                // Already asked: Always is offered, or iOS Settings opens.
                places.turnOn()
                finish()
            }
        default:
            next()
        }
    }

    private func secondary() {
        if page == 2 {
            PhoneLog.shared.note("onboarding", "notifications not now")
            // Off until it's turned on in Settings, which asks then.
            if notifications != .authorized { AppConfig.shared.notifiesWhenReady = false }
        }
        if page == 3 { PhoneLog.shared.note("onboarding", "places not now") }
        next()
    }

    private func readNotifications() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// MARK: - Colours

/// The few tones the art needs beyond the semantic ones.
enum OnboardingColor {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let track = pair(0xD6D4D1, 0x343331)
    /// Cards that stand over the art.
    static let card = pair(0xFFFFFF, 0x1F1E1C)
    static let cardLine = pair(0xE8E6E3, 0x343331)
    static let shadow = pair(0x0A0A0A, 0x000000)
    /// The watch, drawn the way the anatomy art is: 1 pt ink outlines over
    /// four tones of paper.
    static let outline = pair(0x1F1E1C, 0xA6A4A1)
    static let paper = pair(0xFFFFFF, 0x161514)
    static let paperShade = pair(0xEEEDEA, 0x1F1E1C)
    static let bezel = pair(0xF5F3F1, 0x1F1E1C)
    static let bezelLine = pair(0xA6A4A1, 0x4C4A48)
    static let tick = pair(0xA6A4A1, 0x4C4A48)
    static let glass = pair(0x0A0A0A, 0x000000)
    static let glassLine = pair(0x1F1E1C, 0x82807D)
    /// The lock screen behind the notice.
    static let lock = pair(0xF5F3F1, 0x161514)
    static let lockDate = pair(0x82807D, 0x656360)
    static let lockTime = pair(0xD6D4D1, 0x343331)
    static let noticeText = pair(0x343331, 0xD6D4D1)
    /// iOS's prompts, as drawn in the figures.
    static let prompt = pair(0xF7F6F4, 0x2A2927)
    static let promptButton = pair(0xE6E4E1, 0x3A3937)
    static let promptButtonDown = pair(0xCFCDCA, 0x52504E)
    /// Behind a prompt on the lock screen.
    static let scrim = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.45) : UIColor.black.withAlphaComponent(0.06) })
    /// The walk and the pin's ring on the Places map (`places_map.py`).
    static let mapInk = pair(0x1F1E1C, 0xA6A4A1)
    static let mapTop = pair(0xFFFFFF, 0x1F1E1C)
    static let mapRing = pair(0xE3E1DE, 0x4C4A48)
    static let mapShadow = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.55) : UIColor(hex: 0x0A0A0A).withAlphaComponent(0.12) })
    /// The fingertip showing what to tap.
    static let finger = pair(0x82807D, 0x82807D)
}

extension View {
    func floatingCard(radius: CGFloat) -> some View {
        background(OnboardingColor.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(OnboardingColor.cardLine, lineWidth: 1))
            .shadow(color: OnboardingColor.shadow.opacity(0.06), radius: 12, y: 8)
    }
}

/// jotto's icon (D-40): the dot and the bar on orange.
struct AppIconArt: View {
    var body: some View {
        Canvas { context, size in
            let k = size.width / 1024
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 230 * k, style: .continuous),
                         with: .color(.jLive))
            context.fill(Path(ellipseIn: CGRect(x: (347.1 - 196.3) * k, y: (512 - 196.3) * k, width: 392.6 * k, height: 392.6 * k)),
                         with: .color(.white))
            context.fill(Path(CGRect(x: 614.1 * k, y: 433.5 * k, width: 282.6 * k, height: 157 * k)),
                         with: .color(.ink950))
        }
    }
}
