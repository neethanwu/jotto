import SwiftUI

// Each onboarding page's figure acts out what the page is for, over and
// over while the page is shown: a recording writing itself down, the watch
// recording and stopping, jotto installing from the Watch app, iOS's
// prompts answered and what they bring arriving. A grey fingertip shows
// what to tap. With Reduce Motion each holds its last frame.

// MARK: - Timing

/// Waits inside a scene's loop; false once its page has gone.
@MainActor
private func wait(_ seconds: Double) async -> Bool {
    try? await Task.sleep(for: .seconds(seconds))
    return !Task.isCancelled
}

private let settle = Animation.spring(duration: 0.5, bounce: 0.15)
private let drop = Animation.spring(duration: 0.55, bounce: 0.28)

// MARK: - Fingertip

/// Where the fingertip is, and whether it's down.
struct FingerState: Equatable {
    var at = ""
    var shown = false
    var pressed = false
}

/// The centres of what a scene's fingertip can tap, by name.
private struct TapTargets: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] { [:] }
    static func reduce(value: inout [String: Anchor<CGPoint>], nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// `at` is where on it the fingertip lands: off a label's middle, so
    /// the words stay readable under it.
    func tapTarget(_ id: String, at point: UnitPoint = .center) -> some View {
        anchorPreference(key: TapTargets.self, value: .unitPoint(point)) { [id: $0] }
    }

    /// The fingertip over the scene, at the target it's set to; gone
    /// with the scene's page, wherever it was.
    func fingertip(_ finger: FingerState, on shown: Bool) -> some View {
        overlayPreferenceValue(TapTargets.self) { anchors in
            GeometryReader { geo in
                let at = anchors[finger.at].map { geo[$0] } ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                Circle()
                    .fill(OnboardingColor.finger.opacity(finger.pressed ? 0.6 : 0.38))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
                    .frame(width: 40, height: 40)
                    .shadow(color: OnboardingColor.shadow.opacity(0.2), radius: 6, y: 3)
                    .scaleEffect(finger.pressed ? 0.8 : finger.shown ? 1 : 1.35)
                    .opacity(finger.shown && shown ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: shown)
                    .position(at)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Moves the fingertip to a target (appearing there if it wasn't shown)
/// and presses it. Returns with the finger still down after `hold`.
@MainActor
private func press(_ finger: Binding<FingerState>, _ id: String, hold: Double = 0.16) async -> Bool {
    if !finger.wrappedValue.shown {
        finger.wrappedValue.at = id
        withAnimation(.easeOut(duration: 0.3)) { finger.wrappedValue.shown = true }
    } else {
        withAnimation(.spring(duration: 0.55, bounce: 0.1)) { finger.wrappedValue.at = id }
    }
    guard await wait(0.6) else { return false }
    withAnimation(.easeOut(duration: 0.12)) { finger.wrappedValue.pressed = true }
    return await wait(hold)
}

@MainActor
private func lift(_ finger: Binding<FingerState>, away: Bool = true) {
    withAnimation(.easeOut(duration: 0.25)) {
        finger.wrappedValue.pressed = false
        if away { finger.wrappedValue.shown = false }
    }
}

// MARK: - iOS prompts

/// iOS's permission prompt, small, as it looks on this iPhone: the title
/// and its buttons, side by side or stacked.
private struct PromptArt: View {
    let title: String
    let buttons: [String]
    var stacked = false
    var finger: FingerState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jText)
                .fixedSize(horizontal: false, vertical: true)
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                ForEach(buttons, id: \.self) { button in
                    let down = finger.pressed && finger.at == button
                    Text(button)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.jText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(down ? OnboardingColor.promptButtonDown : OnboardingColor.promptButton, in: Capsule())
                        .tapTarget(button, at: UnitPoint(x: 0.9, y: 0.66))
                }
            }
        }
        .padding(18)
        .frame(width: 314)
        .background(OnboardingColor.prompt, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(OnboardingColor.cardLine, lineWidth: 1))
        .shadow(color: OnboardingColor.shadow.opacity(0.16), radius: 24, y: 12)
    }
}

private extension View {
    /// A prompt arriving and going the way iOS's do.
    func prompt(_ shown: Bool) -> some View {
        scaleEffect(shown ? 1 : 1.08).opacity(shown ? 1 : 0)
    }
}

// MARK: - 1 · Welcome

/// The watch from the empty Days page. Its dot sends out rings while a
/// card below listens, writes the words down as they're said, then takes
/// the recording's title.
struct WelcomeScene: View {
    let shown: Bool
    let reduceMotion: Bool
    let motion: Animation

    private enum Stage { case rest, listening, written }
    @State private var stage = Stage.rest
    @State private var words = 0

    private static let sentence = "Book the table for Saturday at eight, and ask Sam to bring the cake."
        .split(separator: " ").map(String.init)

    private var active: Bool { shown && !reduceMotion }
    private var now: Stage { reduceMotion ? .written : stage }
    private var listening: Bool { active && now == .listening }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Wider than the screen: an overlay, so it doesn't widen the figure.
            Color.clear.overlay {
                Image("WatchArt")
                    .resizable()
                    .frame(width: 680, height: 485)
                    .overlay(alignment: .topLeading) { rings }
                    .offset(x: -15, y: 14)
            }
            .rotation3DEffect(.degrees(shown || reduceMotion ? 0 : -32), axis: (x: 0.55, y: -1, z: 0), perspective: 0.5)
            .scaleEffect(shown || reduceMotion ? 1 : 1.06)
            .opacity(shown ? 1 : 0)
            .animation(motion, value: shown)

            card
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .offset(y: shown && now != .rest ? 0 : 24)
                .opacity(shown && now != .rest ? 1 : 0)
                .animation(shown ? settle : motion, value: shown)
        }
        .task(id: active) { await loop() }
    }

    /// Rings from the dot on the watch, in the plane of its screen.
    private var rings: some View {
        TimelineView(.animation(paused: !listening)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t / 1.8 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Ellipse()
                        .stroke(Color.jLive.opacity(0.7 * (1 - p)), lineWidth: 2)
                        .frame(width: 62.4 * (1 + p * 1.1), height: 41.6 * (1 + p * 1.1))
                }
            }
        }
        // The dot's centre in the drawing (554, 302 of 1046 × 746).
        .position(x: 554 * 0.65, y: 302 * 0.65)
        .opacity(listening ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: listening)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Circle().fill(Color.jLive).frame(width: 7, height: 7)
                    Text("Listening")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.jLive)
                    Spacer(minLength: 8)
                    LevelBarsArt(live: listening, count: 18)
                        .frame(width: 70, height: 14)
                }
                .opacity(now == .written ? 0 : 1)
                HStack(spacing: 6) {
                    Text("Saturday dinner")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.jText)
                    Text("· 0:09")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Color.jText3)
                }
                .opacity(now == .written ? 1 : 0)
            }
            .frame(height: 16)
            // Every word is laid out from the start, so the card keeps
            // its size as they appear.
            Text(sentence)
                .font(.system(size: 15))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .floatingCard(radius: 20)
    }

    private var sentence: AttributedString {
        let shownWords = now == .written ? Self.sentence.count : words
        var text = AttributedString()
        for (i, word) in Self.sentence.enumerated() {
            var piece = AttributedString(i == 0 ? word : " " + word)
            piece.foregroundColor = i < shownWords ? OnboardingColor.noticeText : .clear
            text += piece
        }
        return text
    }

    private func loop() async {
        guard active else { return }
        stage = .rest
        words = 0
        while true {
            guard await wait(0.6) else { return }
            withAnimation(settle) { stage = .listening }
            guard await wait(0.9) else { return }
            for i in 1...Self.sentence.count {
                withAnimation(.easeOut(duration: 0.2)) { words = i }
                guard await wait(0.17) else { return }
            }
            guard await wait(0.7) else { return }
            withAnimation(.easeInOut(duration: 0.3)) { stage = .written }
            guard await wait(3.4) else { return }
            withAnimation(.easeIn(duration: 0.3)) { stage = .rest }
            guard await wait(0.4) else { return }
            words = 0
        }
    }
}

/// Bars that move like a voice, the newest in orange.
private struct LevelBarsArt: View {
    let live: Bool
    var count = 24
    var tint = Color.jText3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !live)) { context in
            let t = live ? context.date.timeIntervalSinceReferenceDate : 0
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    let x = Double(i)
                    let level = live ? abs(sin(t * 3.1 + x * 0.9) * sin(t * 1.3 + x * 0.37)) : 0.15
                    Capsule()
                        .fill(i == count - 1 ? Color.jLive : tint.opacity(0.35 + 0.65 * x / Double(count)))
                        .frame(width: 2, height: 2 + 12 * level)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - 2 · Watch

/// The same watch turned to face you. With jotto on it, a recording is
/// started with a tap and stopped by holding the dot; without, jotto
/// installs from the Watch app's Available Apps; with no watch, the dot
/// on this iPhone records instead.
struct WatchScene: View {
    let page: Int
    let state: Inbox.WatchApp
    let reduceMotion: Bool
    let motion: Animation
    let later: (Double) -> Animation

    @State private var face = WatchFace.home
    @State private var today = 0
    @State private var finger = FingerState()
    /// Not installed: 0 waiting, 1 installing, 2 installed.
    @State private var install = 0
    @State private var progress: CGFloat = 0
    /// No watch: 0 waiting, 1 recording, 2 saved.
    @State private var phone = 0
    @State private var seconds = 0

    private var shown: Bool { page == 1 }
    private var active: Bool { shown && !reduceMotion }

    var body: some View {
        let before = page < 1 && !reduceMotion
        ZStack(alignment: .bottom) {
            Color.clear.overlay {
                FrontWatch(face: shownFace, holding: face.holding, today: today)
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

            card
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .offset(y: shown || reduceMotion ? 0 : 24)
                .opacity(shown ? 1 : 0)
                .animation(shown ? later(0.3) : motion, value: page)
        }
        .fingertip(finger, on: shown)
        .animation(.easeOut(duration: 0.3), value: state)
        .task(id: LoopKey(active: active, state: state)) { await loop() }
    }

    private struct LoopKey: Hashable {
        let active: Bool
        let state: Inbox.WatchApp
    }

    private var shownFace: WatchFace {
        switch state {
        case .installed: reduceMotion ? .home : face
        case .notInstalled: install == 2 ? .home : .plain
        case .noWatch, .unknown: .plain
        }
    }

    @ViewBuilder
    private var card: some View {
        switch state {
        case .installed: StatusCardArt(badge: .check, title: "jotto is on your Apple Watch", detail: "Paired and ready to record")
        case .unknown: StatusCardArt(badge: .looking, title: "Looking for your Apple Watch", detail: "A moment")
        case .notInstalled: installRow
        case .noWatch: phoneRow
        }
    }

    /// jotto under Available Apps in the Watch app.
    private var installRow: some View {
        HStack(spacing: 12) {
            AppIconArt().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("jotto")
                    .font(.scaled(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText)
                Text("Watch app · Available Apps")
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText2)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            ZStack {
                Text("Install")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.jText)
                    .frame(width: 76, height: 30)
                    .background(finger.pressed ? OnboardingColor.promptButtonDown : OnboardingColor.promptButton, in: Capsule())
                    .opacity(install == 0 ? 1 : 0)
                ZStack {
                    Circle().stroke(OnboardingColor.track, lineWidth: 2.5)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.jText, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.jText).frame(width: 8, height: 8)
                }
                .frame(width: 26, height: 26)
                .opacity(install == 1 ? 1 : 0)
                Text("Installed")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.jText3)
                    .opacity(install == 2 ? 1 : 0)
            }
            .frame(width: 80)
            .tapTarget("install", at: UnitPoint(x: 0.62, y: 0.65))
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .floatingCard(radius: 20)
    }

    /// The record dot at the bottom of Days, on this iPhone.
    private var phoneRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.jLive)
                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 11, height: 11)
                    .opacity(phone == 1 ? 1 : 0)
            }
            .frame(width: 34, height: 34)
            .scaleEffect(finger.pressed ? 0.9 : 1)
            .tapTarget("phoneDot")
            VStack(alignment: .leading, spacing: 2) {
                Text("Record on this iPhone")
                    .font(.scaled(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText)
                Text(phoneDetail)
                    .font(.scaled(13, .regular, relativeTo: .footnote).monospacedDigit())
                    .foregroundStyle(phone == 1 ? Color.jLive : Color.jText2)
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .floatingCard(radius: 20)
    }

    private var phoneDetail: String {
        switch phone {
        case 1: "Recording · 0:0\(seconds)"
        case 2: "Saved · 0:0\(seconds)"
        default: "No Apple Watch paired"
        }
    }

    private func loop() async {
        guard active else { return }
        face = .home
        finger = FingerState()
        install = 0
        progress = 0
        phone = 0
        seconds = 0
        switch state {
        case .installed: await recordOnWatch()
        case .notInstalled: await installFromWatchApp()
        case .noWatch: await recordOnPhone()
        case .unknown: return
        }
    }

    private func recordOnWatch() async {
        while true {
            guard await wait(1.1) else { return }
            guard await press($finger, "homeDot") else { return }
            lift($finger)
            withAnimation(settle) { face = .recording(0, ring: 0) }
            for s in 1...4 {
                guard await wait(1) else { return }
                withAnimation(.snappy) { face = .recording(s, ring: 0) }
            }
            // Stopping takes a hold: a ring runs round the dot for a second.
            guard await press($finger, "recDot", hold: 0) else { return }
            withAnimation(.easeOut(duration: 0.15)) { face = .holding(4, ring: 0) }
            withAnimation(.linear(duration: 1)) { face = .holding(4, ring: 1) }
            guard await wait(1.05) else { return }
            lift($finger)
            withAnimation(settle) { face = .saved(4) }
            guard await wait(1.9) else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                face = .home
                today += 1
            }
            guard await wait(1.6) else { return }
        }
    }

    private func installFromWatchApp() async {
        while true {
            guard await wait(1.1) else { return }
            guard await press($finger, "install") else { return }
            lift($finger)
            withAnimation(.easeOut(duration: 0.2)) { install = 1 }
            withAnimation(.easeInOut(duration: 2.2)) { progress = 1 }
            guard await wait(2.4) else { return }
            withAnimation(.easeInOut(duration: 0.45)) { install = 2 }
            guard await wait(3) else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                install = 0
                progress = 0
            }
        }
    }

    private func recordOnPhone() async {
        while true {
            guard await wait(1.1) else { return }
            guard await press($finger, "phoneDot") else { return }
            lift($finger, away: false)
            withAnimation(.snappy) {
                phone = 1
                seconds = 0
            }
            for s in 1...3 {
                guard await wait(1) else { return }
                withAnimation(.snappy) { seconds = s }
            }
            guard await press($finger, "phoneDot") else { return }
            lift($finger)
            withAnimation(.snappy) { phone = 2 }
            guard await wait(2.2) else { return }
            withAnimation(.easeInOut(duration: 0.35)) { phone = 0 }
        }
    }
}

/// What's on the watch's screen.
enum WatchFace: Equatable {
    case plain
    case home
    case recording(Int, ring: CGFloat)
    case holding(Int, ring: CGFloat)
    case saved(Int)

    var holding: Bool { if case .holding = self { true } else { false } }
}

/// Apple Watch face on, drawn on the 402 × 392 grid of the anatomy art:
/// case, bezel, glass, crown and side button, and on its screen jotto
/// (home, recording, saved) or a plain watch face.
private struct FrontWatch: View {
    let face: WatchFace
    let holding: Bool
    let today: Int

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
                plainFace.opacity(face == .plain ? 1 : 0)
                home.opacity(face == .home ? 1 : 0)
                recording.opacity(isRecording ? 1 : 0)
                saved.opacity(isSaved ? 1 : 0)
            }
            .environment(\.colorScheme, .dark)
        }
        .frame(width: 402, height: 392, alignment: .topLeading)
    }

    private var isRecording: Bool {
        switch face { case .recording, .holding: true; default: false }
    }

    private var isSaved: Bool { if case .saved = face { true } else { false } }

    private var seconds: Int {
        switch face {
        case .recording(let s, _), .holding(let s, _), .saved(let s): s
        default: 0
        }
    }

    private var ring: CGFloat {
        switch face {
        case .recording(_, let r), .holding(_, let r): r
        default: 0
        }
    }

    private func part(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat,
                      fill: Color, line: Color = OnboardingColor.outline) -> some View {
        let shape = RoundedRectangle(cornerRadius: r, style: .circular)
        return shape.fill(fill)
            .overlay(shape.stroke(line, lineWidth: 1))
            .frame(width: w, height: h)
            .offset(x: x, y: y)
    }

    private var clock: some View {
        Text("9:41")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.ink50)
            .frame(width: 60, alignment: .trailing)
            .position(x: 241, y: 107.5)
    }

    private var home: some View {
        ZStack(alignment: .topLeading) {
            Image("Wordmark")
                .resizable()
                .scaledToFit()
                .frame(width: 30.2, height: 14.3)
                .offset(x: 130.2, y: 100)
            clock
            Circle().fill(Color.jLive).frame(width: 84, height: 84)
                .tapTarget("homeDot")
                .position(x: 201, y: 180)
            Text("Tap to record")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.14)
                .foregroundStyle(Color.ink50)
                .fixedSize()
                .position(x: 201, y: 251)
            Text(today == 0 ? "Nothing yet today" : "\(today) today · \(today) min")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ink500)
                .contentTransition(.numericText())
                .fixedSize()
                .position(x: 201, y: 269.5)
        }
    }

    /// jotto's recording screen: the time, the levels, star, dot and [ ].
    private var recording: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 4) {
                Circle().fill(Color.jLive).frame(width: 6, height: 6)
                Text("Recording")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.jLive)
            .fixedSize()
            .frame(width: 100, alignment: .leading)
            .position(x: 180, y: 107.5)
            clock
            Text("0:0\(seconds)")
                .font(.system(size: 40, weight: .medium).monospacedDigit())
                .tracking(-0.8)
                .foregroundStyle(Color.ink50)
                .contentTransition(.numericText())
                .fixedSize()
                .position(x: 201, y: 146)
            LevelBarsArt(live: isRecording && !holding, count: 26, tint: .white)
                .frame(width: 140, height: 18)
                .position(x: 201, y: 181)
            HStack(spacing: 0) {
                WatchStar().fill(Color.ink50)
                    .frame(width: 16, height: 16)
                    .frame(width: 36, height: 36)
                    .background(Color.ink800, in: Circle())
                    .opacity(holding ? 0.35 : 1)
                Spacer(minLength: 0)
                ZStack {
                    Circle().fill(Color.jLive).frame(width: holding ? 61 : 64, height: holding ? 61 : 64)
                    RoundedRectangle(cornerRadius: 4).fill(Color.ink50).frame(width: 17.6, height: 17.6)
                        .opacity(holding ? 1 : 0)
                    Circle().stroke(Color.ink50.opacity(0.18), lineWidth: 3).frame(width: 72, height: 72)
                        .opacity(holding ? 1 : 0)
                    Circle().trim(from: 0, to: ring)
                        .stroke(Color.ink50, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 72, height: 72)
                }
                .frame(width: 64, height: 64)
                .tapTarget("recDot")
                Spacer(minLength: 0)
                WatchBrackets()
                    .stroke(Color.ink50, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 15)
                    .frame(width: 36, height: 36)
                    .background(Color.ink800, in: Circle())
                    .opacity(holding ? 0.35 : 1)
            }
            .frame(width: 160)
            .position(x: 201, y: 230)
            Text(holding ? "Let go to keep recording" : "Hold the dot to stop")
                .font(.system(size: 10, weight: holding ? .semibold : .medium))
                .foregroundStyle(holding ? Color.ink50 : Color.ink500)
                .fixedSize()
                .position(x: 201, y: 277)
        }
    }

    private var saved: some View {
        ZStack(alignment: .topLeading) {
            clock
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 3)
                CheckArt()
                    .trim(from: 0, to: isSaved ? 1 : 0)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 22, height: 17)
                    .animation(.easeOut(duration: 0.35).delay(0.15), value: isSaved)
            }
            .frame(width: 64, height: 64)
            .position(x: 201, y: 172)
            Text("Saved")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ink50)
                .fixedSize()
                .position(x: 201, y: 225)
            Text("0:0\(seconds) · to iPhone")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ink500)
                .fixedSize()
                .position(x: 201, y: 243)
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

/// The watch's star, on its 24-unit grid.
private struct WatchStar: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 24
        let points: [(Double, Double)] = [(12, 3.2), (14.6, 8.7), (20.6, 9.5), (16.2, 13.7), (17.3, 19.7),
                                          (12, 16.8), (6.7, 19.7), (7.8, 13.7), (3.4, 9.5), (9.4, 8.7)]
        var p = Path()
        p.addLines(points.map { CGPoint(x: $0.0 * u, y: ($0.1 + 0.55) * u) })
        p.closeSubpath()
        return p.strokedPath(StrokeStyle(lineWidth: 1.2 * u, lineJoin: .round)).union(p)
    }
}

/// The watch's section icon, [ ], on its 24-unit grid.
private struct WatchBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 24
        var p = Path()
        p.move(to: CGPoint(x: 9 * u, y: 4.5 * u))
        p.addLine(to: CGPoint(x: 5.5 * u, y: 4.5 * u))
        p.addLine(to: CGPoint(x: 5.5 * u, y: 19.5 * u))
        p.addLine(to: CGPoint(x: 9 * u, y: 19.5 * u))
        p.move(to: CGPoint(x: 15 * u, y: 4.5 * u))
        p.addLine(to: CGPoint(x: 18.5 * u, y: 4.5 * u))
        p.addLine(to: CGPoint(x: 18.5 * u, y: 19.5 * u))
        p.addLine(to: CGPoint(x: 15 * u, y: 19.5 * u))
        return p
    }
}

private struct CheckArt: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// Under the watch: whether jotto is on it.
private struct StatusCardArt: View {
    enum Badge { case check, looking }
    let badge: Badge
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch badge {
                case .check:
                    Circle().fill(Color.jText).overlay {
                        CheckArt()
                            .stroke(Color.jBg, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 11, height: 8)
                    }
                case .looking:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 32, height: 32)
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
    }
}

// MARK: - 3 · Notifications

/// A lock screen. iOS asks about notifications and Allow is tapped; then
/// a "ready" notice drops in, worded as jotto words it: the title, when
/// and how long, what it was about.
struct LockScene: View {
    let page: Int
    /// iOS hasn't asked yet, so the prompt is acted out first.
    let asks: Bool
    let reduceMotion: Bool
    let motion: Animation

    @State private var noticeIn = false
    @State private var promptIn = false
    @State private var finger = FingerState()
    private let now = Date.now

    private var shown: Bool { page == 2 }
    private var active: Bool { shown && !reduceMotion }
    private var notice: Bool { reduceMotion || noticeIn }

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
                .opacity(shown && notice ? 1 : 0)

            noticeArt
                .padding(.horizontal, 32)
                .padding(.top, 178)
                .offset(y: notice ? 0 : -48)
                .opacity(shown && notice ? 1 : 0)

            // iOS dims what's behind its prompt.
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(OnboardingColor.scrim)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .opacity(promptIn ? 1 : 0)

            // The lock screen fades into the page at its foot.
            LinearGradient(colors: [Color.jBg.opacity(0), Color.jBg], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.85))
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .bottom)

            PromptArt(title: "“jotto” Would Like to Send You Notifications",
                      buttons: ["Don’t Allow", "Allow"], finger: finger)
                .prompt(promptIn)
                .padding(.top, 128)
        }
        .fingertip(finger, on: shown)
        .offset(x: page < 2 && !reduceMotion ? 48 : 0)
        .opacity(shown ? 1 : 0)
        .animation(motion, value: page)
        .task(id: active) { await loop() }
    }

    private var noticeArt: some View {
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

    private func loop() async {
        guard active else { return }
        noticeIn = false
        promptIn = false
        finger = FingerState()
        while true {
            guard await wait(0.4) else { return }
            if asks {
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) { promptIn = true }
                guard await wait(0.8) else { return }
                guard await press($finger, "Allow") else { return }
                lift($finger)
                withAnimation(.easeOut(duration: 0.22)) { promptIn = false }
                guard await wait(0.45) else { return }
            }
            withAnimation(drop) { noticeIn = true }
            guard await wait(2.8) else { return }
            withAnimation(.easeIn(duration: 0.35)) { noticeIn = false }
            guard await wait(0.5) else { return }
        }
    }
}

// MARK: - 4 · Location

/// The map drawn for Places, there from the start so the prompts have
/// somewhere to land. iOS asks for location, While Using is tapped, then
/// it offers Always and that's tapped too; then the walk into the park
/// draws itself, the pin drops where it ends and sends out rings, and the
/// words said there come up under it.
struct PlacesScene: View {
    let page: Int
    /// iOS hasn't been asked (or jotto doesn't keep places yet), so the
    /// prompts are acted out first.
    let asks: Bool
    let reduceMotion: Bool
    let motion: Animation

    @State private var pinIn = false
    @State private var cardIn = false
    @State private var firstPrompt = false
    @State private var secondPrompt = false
    @State private var finger = FingerState()
    /// When the walk started drawing; nil while there's none.
    @State private var walkedFrom: Date?
    @State private var walkShown = false
    /// The map steps back while iOS asks, both times.
    @State private var prompting = false

    private var shown: Bool { page == 3 }
    private var active: Bool { shown && !reduceMotion }

    /// The walk on the map, as fractions of it (`places_map.py route`).
    private static let route: [CGPoint] = [
        (0.3486, 0.6191), (0.4577, 0.5546), (0.4864, 0.5726), (0.4897, 0.5752), (0.4926, 0.5780),
        (0.4950, 0.5810), (0.4970, 0.5842), (0.4987, 0.5876), (0.5000, 0.5912), (0.5010, 0.5949),
        (0.5019, 0.5988), (0.5025, 0.6028), (0.5030, 0.6069), (0.5332, 0.6057),
    ].map { CGPoint(x: $0.0, y: $0.1) }
    /// The map's drawing units in points.
    private static let unit: CGFloat = 450 / 330
    private static let walkTime = 1.3

    var body: some View {
        let pin = reduceMotion || pinIn
        let card = reduceMotion || cardIn
        ZStack(alignment: .bottom) {
            Color.clear.overlay {
                ZStack {
                    Image("PlacesMap").resizable()
                    walk
                    ground(pin: pin)
                    Image("PlacesPin").resizable()
                        // The pin's tip, so it lands on its spot.
                        .scaleEffect(pin ? 1 : 0.6, anchor: UnitPoint(x: 0.5332, y: 0.6057))
                        .offset(y: pin ? 0 : -36)
                        .opacity(pin ? 1 : 0)
                }
                .frame(width: 450, height: 438)
            }
            .opacity(prompting ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.3), value: prompting)
            .offset(y: 5 + (shown || reduceMotion ? 0 : 20))
            .opacity(shown ? 1 : 0)
            .animation(motion, value: page)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PlaceCardArt()
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .offset(y: card ? 0 : 24)
                .opacity(shown && card ? 1 : 0)
                .animation(motion, value: page)

            ZStack {
                PromptArt(title: "Allow “jotto” to use your location?",
                          buttons: ["Allow Once", "Allow While Using App", "Don’t Allow"],
                          stacked: true, finger: finger)
                    .prompt(firstPrompt)
                PromptArt(title: "Allow “jotto” to also use your location even when you are not using the app?",
                          buttons: ["Keep Only While Using", "Change to Always Allow"],
                          stacked: true, finger: finger)
                    .prompt(secondPrompt)
            }
            .frame(maxHeight: .infinity)
            .opacity(shown ? 1 : 0)
        }
        .fingertip(finger, on: shown)
        .task(id: active) { await loop() }
    }

    /// The dotted walk drawing itself from the corner into the park, its
    /// head in orange, then its dots marching on towards the pin.
    private var walk: some View {
        TimelineView(.animation(paused: !active || walkedFrom == nil)) { context in
            let since = walkedFrom.map { context.date.timeIntervalSince($0) } ?? (reduceMotion ? 99 : 0)
            let t = min(1, since / Self.walkTime)
            let drawn = 1 - pow(1 - t, 2.2)
            GeometryReader { geo in
                let size = geo.size
                let points = Self.route.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                ZStack(alignment: .topLeading) {
                    Polyline(points: points)
                        .trim(from: 0, to: drawn)
                        .stroke(OnboardingColor.mapInk, style: StrokeStyle(
                            lineWidth: 1.8 * Self.unit, lineCap: .round,
                            dash: [0.1, 4.6 * Self.unit], dashPhase: -since * 9))
                    Circle()
                        .fill(OnboardingColor.mapTop)
                        .overlay(Circle().stroke(OnboardingColor.mapInk, lineWidth: Self.unit))
                        .frame(width: 6.4 * Self.unit, height: 6.4 * Self.unit)
                        .position(points[0])
                    Circle()
                        .fill(Color.jLive)
                        .frame(width: 9, height: 9)
                        .position(Polyline(points: points).point(at: drawn))
                        .opacity(t < 1 ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: t < 1)
                }
            }
        }
        .opacity(reduceMotion || walkShown ? 1 : 0)
    }

    /// The pin's shadow and ring on the ground, and rings going out from
    /// it once it has landed.
    private func ground(pin: Bool) -> some View {
        GeometryReader { geo in
            let at = CGPoint(x: 0.5332 * geo.size.width, y: 0.6057 * geo.size.height)
            ZStack {
                TimelineView(.animation(paused: !active || !pin)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<2, id: \.self) { i in
                            let p = (t / 1.6 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                            Ellipse()
                                .stroke(Color.jLive.opacity(0.55 * (1 - p)), lineWidth: 1.5)
                                .frame(width: 24 * Self.unit * (1 + 1.4 * p), height: 13.2 * Self.unit * (1 + 1.4 * p))
                        }
                    }
                    .opacity(active && pin ? 1 : 0)
                }
                Ellipse()
                    .stroke(OnboardingColor.mapRing, lineWidth: 0.8 * Self.unit)
                    .frame(width: 24 * Self.unit, height: 13.2 * Self.unit)
                Ellipse()
                    .fill(OnboardingColor.mapShadow)
                    .frame(width: 16 * Self.unit, height: 8.8 * Self.unit)
            }
            .position(at)
            .opacity(pin ? 1 : 0)
        }
    }

    private func loop() async {
        guard active else { return }
        pinIn = false
        cardIn = false
        firstPrompt = false
        secondPrompt = false
        prompting = false
        walkShown = false
        walkedFrom = nil
        finger = FingerState()
        while true {
            guard await wait(0.5) else { return }
            if asks {
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                    firstPrompt = true
                    prompting = true
                }
                guard await wait(0.6) else { return }
                guard await press($finger, "Allow While Using App") else { return }
                lift($finger, away: false)
                withAnimation(.easeOut(duration: 0.2)) { firstPrompt = false }
                guard await wait(0.3) else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) { secondPrompt = true }
                guard await wait(0.7) else { return }
                guard await press($finger, "Change to Always Allow") else { return }
                lift($finger)
                withAnimation(.easeOut(duration: 0.2)) {
                    secondPrompt = false
                    prompting = false
                }
                guard await wait(0.35) else { return }
            }
            walkShown = true
            walkedFrom = .now
            guard await wait(Self.walkTime - 0.15) else { return }
            withAnimation(drop) { pinIn = true }
            guard await wait(0.3) else { return }
            withAnimation(settle) { cardIn = true }
            guard await wait(2.8) else { return }
            withAnimation(.easeIn(duration: 0.35)) {
                pinIn = false
                cardIn = false
                walkShown = false
            }
            guard await wait(0.4) else { return }
            walkedFrom = nil
        }
    }
}

/// Straight lines through points, and where along them a fraction of the
/// way is.
private struct Polyline: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addLines(points)
        return p
    }

    func point(at fraction: Double) -> CGPoint {
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var left = lengths.reduce(0, +) * min(max(fraction, 0), 1)
        for (i, length) in lengths.enumerated() {
            if left <= length, length > 0 {
                let k = left / length
                return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * k,
                               y: points[i].y + (points[i + 1].y - points[i].y) * k)
            }
            left -= length
        }
        return points.last ?? .zero
    }
}

/// How a place shows on a transcript.
private struct PlaceCardArt: View {
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
