import SwiftUI
import UserNotifications

/// Four pages the first time jotto opens: what it does, the watch, the
/// "ready" notice and Places. Each page's button is what brings up iOS's
/// own prompt for it, so nothing is asked before it's been explained.
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
    @State private var notifications: UNAuthorizationStatus?
    @State private var waitingForPlaces = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    private var inbox: Inbox { .shared }
    private var places: PlaceTracker { .shared }

    private static let pages = 4
    /// The figure is drawn for this height and scaled down to fit smaller screens.
    private static let figureHeight: CGFloat = 430

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress
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
        .task { await readNotifications() }
        // iOS answered the location prompt (Always is offered afterwards,
        // over Days).
        .onChange(of: places.permission) { _, now in
            if waitingForPlaces, now != .notDetermined { finish() }
        }
    }

    // MARK: - Progress

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.pages, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Color.jText : OnboardingColor.track)
                    .frame(width: i == page ? 22 : 8, height: 4)
            }
        }
        .animation(motion, value: page)
        .padding(.top, 14)
        .padding(.horizontal, 28)
        .frame(height: 52, alignment: .top)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(Self.pages)")
    }

    // MARK: - Figure

    /// Every page's art is always there, so each can leave and arrive in
    /// its own way: the watch turns to face you, the notice drops onto the
    /// lock screen, the pin drops into the park.
    private func figure(width: CGFloat) -> some View {
        ZStack {
            welcomeWatch
            frontWatch
            lockScreen
            map
        }
        .frame(width: width, height: Self.figureHeight)
    }

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.6, bounce: 0.12)
    }

    private func later(_ delay: Double) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.55, bounce: 0.18).delay(delay)
    }

    /// The watch from the empty Days page, at an angle.
    private var welcomeWatch: some View {
        let shown = page == 0
        // Wider than the screen: an overlay, so it doesn't widen the figure.
        return Color.clear.overlay {
            Image("WatchArt")
                .resizable()
                .frame(width: 680, height: 485)
                .offset(x: -15, y: 14)
        }
            .rotation3DEffect(.degrees(shown || reduceMotion ? 0 : -32), axis: (x: 0.55, y: -1, z: 0), perspective: 0.5)
            .scaleEffect(shown || reduceMotion ? 1 : 1.06)
            .opacity(shown ? 1 : 0)
            .animation(motion, value: page)
    }

    /// The same watch turned to face you, with what's on it.
    private var frontWatch: some View {
        let shown = page == 1
        let before = page < 1 && !reduceMotion
        return ZStack(alignment: .bottom) {
            Color.clear.overlay {
                FrontWatch(installed: inbox.watchApp == .installed)
                    .scaleEffect(450 / 402)
                    .frame(width: 450, height: 439)
            }
                .offset(y: -12)
                .rotation3DEffect(.degrees(before ? 32 : 0), axis: (x: 0.55, y: -1, z: 0), perspective: 0.5)
                .scaleEffect(before ? 0.9 : 1)
                .offset(x: page > 1 && !reduceMotion ? -48 : 0)
                .opacity(shown ? 1 : 0)
                .animation(motion, value: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            WatchStatusCard(state: inbox.watchApp)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .offset(y: shown || reduceMotion ? 0 : 24)
                .opacity(shown ? 1 : 0)
                .animation(shown ? later(0.3) : motion, value: page)
        }
        .animation(.easeOut(duration: 0.3), value: inbox.watchApp)
    }

    private var lockScreen: some View {
        let shown = page == 2
        return LockScreenArt(shown: shown, reduceMotion: reduceMotion, later: later)
            .offset(x: page < 2 && !reduceMotion ? 48 : 0)
            .opacity(shown ? 1 : 0)
            .animation(motion, value: page)
    }

    private var map: some View {
        let shown = page == 3
        return ZStack(alignment: .bottom) {
            Color.clear.overlay {
                ZStack {
                    Image("PlacesMap").resizable().frame(width: 450, height: 438)
                    Image("PlacesPin").resizable().frame(width: 450, height: 438)
                        // The pin's tip, so it lands on its spot.
                        .scaleEffect(shown || reduceMotion ? 1 : 0.6, anchor: UnitPoint(x: 0.5332, y: 0.6057))
                        .offset(y: shown || reduceMotion ? 0 : -36)
                        .opacity(shown ? 1 : 0)
                        .animation(shown ? later(0.35) : motion, value: page)
                }
            }
            .offset(y: 5 + (shown || reduceMotion ? 0 : 20))
            .opacity(shown ? 1 : 0)
            .animation(motion, value: page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PlaceCard()
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .offset(y: shown || reduceMotion ? 0 : 24)
                .opacity(shown ? 1 : 0)
                .animation(shown ? later(0.6) : motion, value: page)
        }
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
            switch inbox.watchApp {
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
                             body: "The first time you record, your watch asks for its microphone and to send you notices. Allow both: a call can pause a recording, and a notice brings you back to it.",
                             primary: "Continue")
            }
        case 2:
            return Words(title: "Know when\nit's written.",
                         body: "Recordings turn into text while jotto is closed. A notice tells you when one is ready, with its title.",
                         primary: notifications == .notDetermined ? "Allow notifications" : "Continue")
        default:
            return Words(title: "Remember where\nyou said it.",
                         body: "Each recording keeps where it was made. Your watch's recordings also turn into text as you talk, with this iPhone locked. Places stay on this iPhone.",
                         primary: places.isOn ? "Continue" : "Turn on Places",
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
                    insertion: .opacity.combined(with: .offset(x: 24)),
                    removal: .opacity.combined(with: .offset(x: -24))))
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
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 8)
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

    private func next() {
        guard page < Self.pages - 1 else { return finish() }
        page += 1
        PhoneLog.shared.note("onboarding", "page \(page)")
    }

    private func primary() {
        switch page {
        case 1 where inbox.watchApp == .notInstalled:
            // The Watch app, where jotto waits under Available Apps; the
            // page turns to "on your watch" when it's installed.
            if let url = URL(string: "itms-watchs://") { openURL(url) }
        case 2 where notifications == .notDetermined:
            Task {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                PhoneLog.shared.note("notify_permission", granted ? "granted" : "denied")
                await readNotifications()
                next()
            }
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
        if page == 3 { PhoneLog.shared.note("onboarding", "places not now") }
        next()
    }

    private func readNotifications() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// MARK: - Colours

/// The few tones the art needs beyond the semantic ones.
private enum OnboardingColor {
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
}

private extension View {
    func floatingCard(radius: CGFloat) -> some View {
        background(OnboardingColor.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(OnboardingColor.cardLine, lineWidth: 1))
            .shadow(color: OnboardingColor.shadow.opacity(0.06), radius: 12, y: 8)
    }
}

// MARK: - Watch

/// Apple Watch face on, drawn on the 402 × 392 grid of the anatomy art:
/// case, bezel, glass, crown and side button. With jotto installed its
/// screen shows jotto's home; without, a plain watch face.
private struct FrontWatch: View {
    let installed: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Crown and side button, behind the case's edge.
            part(x: 297, y: 134, w: 8, h: 28, r: 2, fill: OnboardingColor.paperShade)
            part(x: 303, y: 128, w: 12, h: 40, r: 4, fill: OnboardingColor.paper)
            Path { p in
                for y in stride(from: 133.0, through: 161, by: 4) {
                    p.move(to: CGPoint(x: 305, y: y)); p.addLine(to: CGPoint(x: 313, y: y))
                }
            }
            .stroke(OnboardingColor.tick, lineWidth: 1)
            part(x: 297, y: 190, w: 9, h: 52, r: 3, fill: OnboardingColor.paper)

            part(x: 99, y: 68, w: 204, h: 244, r: 54, fill: OnboardingColor.paper)
            part(x: 104, y: 73, w: 194, h: 234, r: 49, fill: OnboardingColor.bezel, line: OnboardingColor.bezelLine)
            part(x: 109, y: 78, w: 184, h: 224, r: 44, fill: OnboardingColor.glass, line: OnboardingColor.glassLine)
            Circle().fill(OnboardingColor.outline).frame(width: 1.6, height: 1.6).position(x: 106, y: 190)

            ZStack(alignment: .topLeading) {
                jottoHome.opacity(installed ? 1 : 0)
                plainFace.opacity(installed ? 0 : 1)
            }
            .environment(\.colorScheme, .dark)
        }
        .frame(width: 402, height: 392, alignment: .topLeading)
    }

    private func part(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat,
                      fill: Color, line: Color = OnboardingColor.outline) -> some View {
        let shape = RoundedRectangle(cornerRadius: r, style: .circular)
        return shape.fill(fill)
            .overlay(shape.stroke(line, lineWidth: 1))
            .frame(width: w, height: h)
            .offset(x: x, y: y)
    }

    private var jottoHome: some View {
        ZStack(alignment: .topLeading) {
            Image("Wordmark")
                .resizable()
                .scaledToFit()
                .frame(width: 30.2, height: 14.3)
                .offset(x: 130.2, y: 100)
            Text("9:41")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink50)
                .frame(width: 60, alignment: .trailing)
                .position(x: 241, y: 107.5)
            Circle().fill(Color.jLive).frame(width: 84, height: 84).position(x: 201, y: 180)
            Text("Tap to record")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.14)
                .foregroundStyle(Color.ink50)
                .fixedSize()
                .position(x: 201, y: 251)
            Text("Nothing yet today")
                .font(.system(size: 10))
                .foregroundStyle(Color.ink500)
                .fixedSize()
                .position(x: 201, y: 269.5)
        }
    }

    private var plainFace: some View {
        ZStack(alignment: .topLeading) {
            Text("THU 19")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.ink400)
                .fixedSize()
                .position(x: 201, y: 163.5)
            Text("9:41")
                .font(.system(size: 56, weight: .light))
                .tracking(-1.5)
                .foregroundStyle(Color.ink50)
                .fixedSize()
                .position(x: 201, y: 202)
        }
    }
}

/// Under the watch: whether jotto is on it.
private struct WatchStatusCard: View {
    let state: Inbox.WatchApp

    var body: some View {
        HStack(spacing: 12) {
            badge.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.scaled(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText)
                Text(detail)
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText2)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .floatingCard(radius: 20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .installed:
            Circle().fill(Color.jText).overlay {
                Path { p in
                    p.move(to: CGPoint(x: 3, y: 7.4)); p.addLine(to: CGPoint(x: 5.8, y: 10)); p.addLine(to: CGPoint(x: 11, y: 4))
                }
                .stroke(Color.jBg, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 14)
            }
        case .unknown:
            ProgressView().controlSize(.small)
        case .notInstalled, .noWatch:
            Circle().strokeBorder(Color.jText4, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    private var title: String {
        switch state {
        case .installed: "jotto is on your Apple Watch"
        case .notInstalled: "jotto isn't on your watch yet"
        case .noWatch: "No Apple Watch paired"
        case .unknown: "Looking for your Apple Watch"
        }
    }

    private var detail: String {
        switch state {
        case .installed: "Paired and ready to record"
        case .notInstalled: "Install it from the Watch app on this iPhone"
        case .noWatch: "You can record on this iPhone for now"
        case .unknown: "A moment"
        }
    }
}

// MARK: - Lock screen

/// A "ready" notice arriving on the lock screen, as jotto words it: the
/// title, when and how long, and what it was about.
private struct LockScreenArt: View {
    let shown: Bool
    let reduceMotion: Bool
    let later: (Double) -> Animation

    private let now = Date.now

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(OnboardingColor.lock)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            VStack(spacing: 0) {
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnboardingColor.lockDate)
                Text(now.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(.system(size: 84, weight: .bold))
                    .tracking(-2.5)
                    .foregroundStyle(OnboardingColor.lockTime)
                    .frame(height: 92)
            }
            .padding(.top, 48)

            // An older notice, stacked behind.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OnboardingColor.card.opacity(0.7))
                .shadow(color: OnboardingColor.shadow.opacity(0.05), radius: 8, y: 4)
                .frame(height: 60)
                .padding(.horizontal, 44)
                .padding(.top, 250)
                .opacity(shown ? 1 : 0)
                .animation(shown ? later(0.2) : .easeOut(duration: 0.2), value: shown)

            notice
                .padding(.horizontal, 32)
                .padding(.top, 178)
                .offset(y: shown || reduceMotion ? 0 : -48)
                .opacity(shown ? 1 : 0)
                .animation(shown ? later(0.4) : .easeOut(duration: 0.2), value: shown)

            // The lock screen fades into the page at its foot.
            LinearGradient(colors: [Color.jBg.opacity(0), Color.jBg], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.85))
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconArt().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Walk to the park")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.jText)
                    Spacer(minLength: 8)
                    Text("now")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jText3)
                }
                Text("\(Format.time(now.addingTimeInterval(-31 * 60))) · 18 min")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(OnboardingColor.noticeText)
                Text("Talked through the route for Saturday and who brings the food.")
                    .font(.system(size: 15))
                    .foregroundStyle(OnboardingColor.noticeText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(OnboardingColor.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: OnboardingColor.shadow.opacity(0.10), radius: 16, y: 12)
    }
}

/// jotto's icon (D-40): the dot and the bar on orange.
private struct AppIconArt: View {
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

// MARK: - Places

/// How a place shows on a transcript.
private struct PlaceCard: View {
    private let at = Date.now.addingTimeInterval(-31 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                GlyphView(glyph: .pin, color: .jText3).frame(width: 13, height: 13)
                Text("Victoria Park")
                    .font(.scaled(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Color.jText)
                Text("· \(Format.time(at))")
                    .font(.scaled(13, .regular, relativeTo: .footnote).monospacedDigit())
                    .foregroundStyle(Color.jText3)
            }
            Text("Let's meet by the east gate at ten, then walk down to the water.")
                .font(.scaled(15, .regular, relativeTo: .subheadline))
                .lineSpacing(2)
                .foregroundStyle(OnboardingColor.noticeText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .floatingCard(radius: 20)
    }
}
