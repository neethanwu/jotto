import SwiftUI
import UIKit

/// Design tokens. Views use only the semantic
/// layer (`Color.jBg`, `.jText2`…); the ink and orange scales stay private.
enum Ink {
    static let i0 = UIColor(hex: 0xFFFFFF)
    static let i50 = UIColor(hex: 0xFBFAF7)
    static let i100 = UIColor(hex: 0xF5F3F1)
    static let i200 = UIColor(hex: 0xE8E6E3)
    static let i300 = UIColor(hex: 0xD6D4D1)
    static let i400 = UIColor(hex: 0xA6A4A1)
    static let i500 = UIColor(hex: 0x82807D)
    static let i600 = UIColor(hex: 0x656360)
    static let i700 = UIColor(hex: 0x4C4A48)
    static let i800 = UIColor(hex: 0x343331)
    static let i900 = UIColor(hex: 0x1F1E1C)
    static let i950 = UIColor(hex: 0x0A0A0A)
    static let darkHairline = UIColor(hex: 0x2A2927)
    static let darkStroke = UIColor(hex: 0x2E2D2B)
}

enum Orange {
    static let o100 = UIColor(hex: 0xFFE7E0)
    static let o500 = UIColor(hex: 0xFF4F00)
    static let o950 = UIColor(hex: 0x440700)
}

extension Color {
    private static func pair(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let jBg = pair(Ink.i0, Ink.i950)
    /// Cards: the page colour inside a hairline (see `card`), not a tint.
    static let jSurface = pair(Ink.i0, Ink.i950)
    static let jCardLine = pair(Ink.i200, Ink.darkHairline)
    /// Fields and unselected chips: a neutral grey, not a warm one.
    static let jFill = pair(UIColor(hex: 0xF4F4F4), Ink.i900)
    /// The 1 pt ring around top-bar buttons.
    static let jRing = pair(UIColor(hex: 0xE3E1DE), Ink.i800)
    static let jHairline = pair(Ink.i200, Ink.darkHairline)
    /// The timeline spine is a step brighter than other hairlines in dark.
    static let jSpine = pair(Ink.i200, Ink.i800)
    static let jText = pair(Ink.i950, Ink.i50)
    static let jText2 = pair(Ink.i600, Ink.i400)
    static let jText3 = pair(Ink.i500, Ink.i500)
    static let jText4 = pair(Ink.i400, Ink.i600)
    static let jText5 = pair(Ink.i300, Ink.i700)
    static let jChrome = pair(Ink.i950, Ink.i900)
    /// Inner stroke of chrome pills; only drawn in dark.
    static let jChromeStroke = pair(.clear, Ink.darkStroke)
    /// The player: white with a hairline and a soft shadow in light, the
    /// chrome's dark in dark. Its play button is the screen's one inverted
    /// control.
    static let jPlayer = pair(Ink.i0, Ink.i900)
    static let jPlayerStroke = pair(Ink.i200, Ink.darkStroke)
    /// The part of the waveform not played yet.
    static let jWaveRest = pair(Ink.i300, Ink.i600)
    static let jChromeOn = Color(Ink.i50)
    static let jOnChromeOn = Color(Ink.i950)
    // Sheets sit one step above the page in dark, so their own fills and
    // hairlines go up a step too. The well is the recessed preview in Share.
    static let jSheet = pair(Ink.i0, Ink.i900)
    static let jSheetFill = pair(UIColor(hex: 0xF4F4F4), Ink.i800)
    static let jSheetHairline = pair(Ink.i200, Ink.i800)
    static let jSheetWell = pair(Ink.i0, Ink.i950)
    static let jToggleOff = pair(Ink.i200, Ink.i800)
    /// Behind marked text in a transcript, like a highlighter.
    static let jMarker = pair(UIColor(hex: 0xE8E8E8), UIColor(hex: 0x363636))
    /// Delete in swipe actions; the same red the system uses for destructive.
    static let jDestructive = Color(UIColor(hex: 0xE5484D))
    static let jLive = Color(Orange.o500)
    static let jLiveHalo = pair(Orange.o100, Orange.o950)

    // Fixed tones for surfaces that are dark in both modes (Live, the player).
    static let ink50 = Color(Ink.i50)
    static let ink400 = Color(Ink.i400)
    static let ink500 = Color(Ink.i500)
    static let ink600 = Color(Ink.i600)
    static let ink700 = Color(Ink.i700)
    static let ink800 = Color(Ink.i800)
    static let ink900 = Color(Ink.i900)
    static let ink950 = Color(Ink.i950)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Type

/// SF Pro everywhere; time data uses monospaced digits. Sizes follow the
/// spec at the Large content size and scale with Dynamic Type.
extension Font {
    static var dayTitle: Font { .scaled(44, .bold, relativeTo: .largeTitle) }
    static var transcriptTitle: Font { .scaled(34, .bold, relativeTo: .largeTitle) }
    static let timer = Font.system(size: 72, weight: .medium).monospacedDigit()
    static var sheetTitle: Font { .scaled(24, .semibold, relativeTo: .title2) }
    static var caption22: Font { .scaled(22, .regular, relativeTo: .title3) }
    static var rowTitle: Font { .scaled(17, .medium, relativeTo: .body) }
    static var settingValue: Font { .scaled(15, .regular, relativeTo: .subheadline) }
    static var reading: Font { .scaled(17, .regular, relativeTo: .body) }
    static var summary: Font { .scaled(15, .regular, relativeTo: .subheadline) }
    static var label: Font { .scaled(15, .semibold, relativeTo: .subheadline) }
    static var speaker: Font { .scaled(13, .semibold, relativeTo: .footnote) }
    static var meta: Font { .scaled(13, .medium, relativeTo: .caption1).monospacedDigit() }
    static var metaSmall: Font { .scaled(12, .medium, relativeTo: .caption1).monospacedDigit() }
    static var weekday: Font { .scaled(11, .medium, relativeTo: .caption2) }
}

extension Font {
    /// SF Pro at a spec size that follows Dynamic Type like `style` does.
    /// Computed, so it picks up a size change on the next render.
    static func scaled(_ size: CGFloat, _ weight: UIFont.Weight, relativeTo style: UIFont.TextStyle) -> Font {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: base))
    }
}

extension View {
    /// Large titles track tighter: -0.025em at 44, -0.02em at 34.
    func dayTitleStyle() -> some View {
        font(.dayTitle).tracking(-1.1).lineSpacing(0).foregroundStyle(Color.jText)
    }
}

// MARK: - Shared pieces

/// Top-bar icons, drawn on the design's 24-unit grid with one stroke
/// weight so they match each other (SF Symbols vary in weight and sit
/// off-centre in a circle).
enum Glyph {
    case back, down, close, more, share, search, trash, star, brackets, send, plus
    /// Rename: a pen with a rounded end and a band.
    case pen
    /// The plane filled in: Send when it's where you are or the main action.
    case sendFilled
    /// A map pin: where a recording was said.
    case pin
}

extension Glyph {
    /// For menus, which take an image rather than a view: drawn once,
    /// tinted by the menu like a symbol.
    @MainActor func image(size: CGFloat = 20) -> Image {
        let renderer = ImageRenderer(content: GlyphView(glyph: self, color: .black).frame(width: size, height: size))
        renderer.scale = 3
        let image = renderer.uiImage?.withRenderingMode(.alwaysTemplate) ?? UIImage()
        return Image(uiImage: image)
    }
}

struct GlyphView: View {
    let glyph: Glyph
    var color: Color = .jText

    var body: some View {
        Canvas { context, size in
            let k = min(size.width, size.height) / 24
            context.scaleBy(x: k, y: k)
            let style = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            var p = Path()
            switch glyph {
            case .back:
                p.move(to: CGPoint(x: 15.5, y: 5)); p.addLine(to: CGPoint(x: 8.5, y: 12)); p.addLine(to: CGPoint(x: 15.5, y: 19))
            case .down:
                p.move(to: CGPoint(x: 5, y: 8.5)); p.addLine(to: CGPoint(x: 12, y: 15.5)); p.addLine(to: CGPoint(x: 19, y: 8.5))
            case .close:
                p.move(to: CGPoint(x: 6.5, y: 6.5)); p.addLine(to: CGPoint(x: 17.5, y: 17.5))
                p.move(to: CGPoint(x: 17.5, y: 6.5)); p.addLine(to: CGPoint(x: 6.5, y: 17.5))
            case .more:
                for x in [5.5, 12, 18.5] {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1.8, y: 10.2, width: 3.6, height: 3.6)), with: .color(color))
                }
                return
            case .share:
                p.move(to: CGPoint(x: 12, y: 3.5)); p.addLine(to: CGPoint(x: 12, y: 14.5))
                p.move(to: CGPoint(x: 7.5, y: 8)); p.addLine(to: CGPoint(x: 12, y: 3.5)); p.addLine(to: CGPoint(x: 16.5, y: 8))
                p.move(to: CGPoint(x: 5, y: 12.5))
                p.addLine(to: CGPoint(x: 5, y: 18.5))
                p.addArc(tangent1End: CGPoint(x: 5, y: 20.5), tangent2End: CGPoint(x: 7, y: 20.5), radius: 2)
                p.addLine(to: CGPoint(x: 17, y: 20.5))
                p.addArc(tangent1End: CGPoint(x: 19, y: 20.5), tangent2End: CGPoint(x: 19, y: 18.5), radius: 2)
                p.addLine(to: CGPoint(x: 19, y: 12.5))
            case .trash:
                p.move(to: CGPoint(x: 4.5, y: 7)); p.addLine(to: CGPoint(x: 19.5, y: 7))
                p.move(to: CGPoint(x: 10, y: 11)); p.addLine(to: CGPoint(x: 10, y: 17))
                p.move(to: CGPoint(x: 14, y: 11)); p.addLine(to: CGPoint(x: 14, y: 17))
                p.move(to: CGPoint(x: 6.5, y: 7)); p.addLine(to: CGPoint(x: 7.4, y: 18.6))
                p.addQuadCurve(to: CGPoint(x: 9.4, y: 20.5), control: CGPoint(x: 7.5, y: 20.5))
                p.addLine(to: CGPoint(x: 14.6, y: 20.5))
                p.addQuadCurve(to: CGPoint(x: 16.6, y: 18.6), control: CGPoint(x: 16.5, y: 20.5))
                p.addLine(to: CGPoint(x: 17.5, y: 7))
                p.move(to: CGPoint(x: 9.5, y: 7)); p.addLine(to: CGPoint(x: 9.5, y: 4.5))
                p.addLine(to: CGPoint(x: 14.5, y: 4.5)); p.addLine(to: CGPoint(x: 14.5, y: 7))
            case .star:
                let points: [(Double, Double)] = [(12, 3.2), (14.6, 8.7), (20.6, 9.5), (16.2, 13.7), (17.3, 19.7),
                                                  (12, 16.8), (6.7, 19.7), (7.8, 13.7), (3.4, 9.5), (9.4, 8.7)]
                // Down a touch, so the points rather than the box are centred.
                p.addLines(points.map { CGPoint(x: $0.0, y: $0.1 + 0.55) })
                p.closeSubpath()
                context.fill(p, with: .color(color))
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                return
            case .brackets:
                p.move(to: CGPoint(x: 9, y: 4.5)); p.addLine(to: CGPoint(x: 5.5, y: 4.5))
                p.addLine(to: CGPoint(x: 5.5, y: 19.5)); p.addLine(to: CGPoint(x: 9, y: 19.5))
                p.move(to: CGPoint(x: 15, y: 4.5)); p.addLine(to: CGPoint(x: 18.5, y: 4.5))
                p.addLine(to: CGPoint(x: 18.5, y: 19.5)); p.addLine(to: CGPoint(x: 15, y: 19.5))
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                return
            case .search:
                p.addEllipse(in: CGRect(x: 4.5, y: 4.5, width: 13, height: 13))
                p.move(to: CGPoint(x: 19.5, y: 19.5)); p.addLine(to: CGPoint(x: 15.9, y: 15.9))
            case .send:
                // A paper plane, symmetric about its diagonal and the same
                // size as the other glyphs. It sits between its bounding box
                // and its centre of mass so it reads as centred in a ring.
                p.move(to: CGPoint(x: 18.8, y: 5.2)); p.addLine(to: CGPoint(x: 3.8, y: 11))
                p.addLine(to: CGPoint(x: 9.8, y: 14.2)); p.addLine(to: CGPoint(x: 13, y: 20.2)); p.closeSubpath()
                p.move(to: CGPoint(x: 9.8, y: 14.2)); p.addLine(to: CGPoint(x: 14.4, y: 9.6))
            case .sendFilled:
                var plane = Path()
                plane.move(to: CGPoint(x: 18.8, y: 5.2)); plane.addLine(to: CGPoint(x: 3.8, y: 11))
                plane.addLine(to: CGPoint(x: 9.8, y: 14.2)); plane.addLine(to: CGPoint(x: 13, y: 20.2)); plane.closeSubpath()
                context.fill(plane, with: .color(color))
                context.stroke(plane, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                // The fold, cut out of the fill so whatever is behind shows.
                var fold = Path()
                fold.move(to: CGPoint(x: 9.8, y: 14.2)); fold.addLine(to: CGPoint(x: 14.4, y: 9.6))
                context.blendMode = .destinationOut
                context.stroke(fold, with: .color(.black), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                return
            case .pin:
                // A round head narrowing to a point, a ring inside it. Drawn
                // a little heavier: it's shown at 12 to 13 points.
                p.move(to: CGPoint(x: 20, y: 10))
                p.addCurve(to: CGPoint(x: 12, y: 21.6), control1: CGPoint(x: 20, y: 14.8), control2: CGPoint(x: 14.6, y: 19.4))
                p.addCurve(to: CGPoint(x: 4, y: 10), control1: CGPoint(x: 9.4, y: 19.4), control2: CGPoint(x: 4, y: 14.8))
                p.addCurve(to: CGPoint(x: 12, y: 2), control1: CGPoint(x: 4, y: 5.58), control2: CGPoint(x: 7.58, y: 2))
                p.addCurve(to: CGPoint(x: 20, y: 10), control1: CGPoint(x: 16.42, y: 2), control2: CGPoint(x: 20, y: 5.58))
                p.closeSubpath()
                p.addEllipse(in: CGRect(x: 9, y: 7, width: 6, height: 6))
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                return
            case .plus:
                p.move(to: CGPoint(x: 12, y: 5)); p.addLine(to: CGPoint(x: 12, y: 19))
                p.move(to: CGPoint(x: 5, y: 12)); p.addLine(to: CGPoint(x: 19, y: 12))
            case .pen:
                p.move(to: CGPoint(x: 4.5, y: 19.5))
                p.addLine(to: CGPoint(x: 5.4, y: 15.4))
                p.addLine(to: CGPoint(x: 15, y: 5.8))
                p.addArc(center: CGPoint(x: 16.6, y: 7.4), radius: 2.26,
                         startAngle: .degrees(225), endAngle: .degrees(45), clockwise: false)
                p.addLine(to: CGPoint(x: 8.6, y: 18.6))
                p.closeSubpath()
                p.move(to: CGPoint(x: 13, y: 7.8)); p.addLine(to: CGPoint(x: 16.2, y: 11))
            }
            context.stroke(p, with: .color(color), style: style)
        }
        .accessibilityHidden(true)
    }
}

/// The 40-pt ring every top-bar button sits in, with an 18-pt glyph:
/// the page colour inside a 1-pt ring, like the rings on the timeline.
/// Top-bar buttons: a filled circle with an
/// outline glyph; the screen's one main action is inverted, with a
/// filled glyph. No ring.
struct CircleGlyph: View {
    let glyph: Glyph
    var fill: Color = .jFill
    var color: Color = .jText
    var ring: Color = .clear
    /// 44 in top bars; 32 beside a section title.
    var size: CGFloat = 44

    var body: some View {
        GlyphView(glyph: glyph, color: color)
            .frame(width: size * 0.475, height: size * 0.475)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(ring, lineWidth: 1))
            // 44 to touch, without taking more room.
            .contentShape(Circle().inset(by: -(44 - min(size, 44)) / 2))
    }
}

/// Pressed: a step darker and a touch smaller, with a light tap.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Capsule().fill(Color.jText.opacity(configuration.isPressed ? 0.07 : 0)).allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// 40pt ring button, used in top bars.
struct CircleIconButton: View {
    let glyph: Glyph
    let label: String
    var fill: Color = .jFill
    var color: Color = .jText
    var ring: Color = .clear
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleGlyph(glyph: glyph, fill: fill, color: color, ring: ring, size: size)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

/// Corner radii. One radius for every rectangle that stands on the page
/// (cards, text fields, wells, the playing paragraph's band), rounded
/// only just: big radii read as toy-like next to text this size. Pills
/// are for buttons and chips, never for fields.
enum Radius {
    /// Cards, fields, wells, panels.
    static let card: CGFloat = 12
    /// Something 3 pt inside one of those, like the segmented knob.
    static let inner: CGFloat = 9
}

extension View {
    /// A text field's grey ground: the same rectangle as a card.
    func fieldBackground(_ fill: Color = .jFill) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

extension View {
    /// A content card: the page colour inside a hairline.
    func card(radius: CGFloat = Radius.card) -> some View {
        background(Color.jSurface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.jCardLine, lineWidth: 1))
    }
}

/// The ⓧ at the end of a text field: empties it in one tap. Only there
/// when there is something to clear.
struct ClearButton: View {
    @Binding var text: String
    var visible = true
    var label = "Clear"
    /// After clearing: usually, put the cursor back in the field.
    var then: () -> Void = {}

    var body: some View {
        if visible, !text.isEmpty {
            Button {
                text = ""
                then()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.jText4)
                    .frame(width: 28, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .transition(.opacity)
        }
    }
}

/// On is the text colour with a page-coloured knob, so it reads in both
/// modes (the system switch tinted to text is white on white in dark).
struct JottoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(duration: 0.25, bounce: 0.15)) { configuration.isOn.toggle() }
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 12)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.jText : Color.jToggleOff)
                    Circle()
                        .fill(configuration.isOn ? Color.jBg : Color.white)
                        .shadow(color: .black.opacity(configuration.isOn ? 0 : 0.15), radius: 2, y: 1)
                        .padding(2)
                }
                .frame(width: 51, height: 31)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .sensoryFeedback(.selection, trigger: configuration.isOn)
    }
}

/// Black pill behind the tab bar and the player.
struct ChromePill: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Color.jChrome, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.jChromeStroke, lineWidth: 1))
            .shadow(color: scheme == .dark ? .clear : Color.ink950.opacity(0.18), radius: 12, y: 8)
    }
}

/// The player's pill: light in light mode, so the transcript's only
/// dark thing is its play button; the same as the chrome in dark.
struct PlayerPill: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Color.jPlayer, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.jPlayerStroke, lineWidth: 1))
            .shadow(color: scheme == .dark ? .clear : Color.ink950.opacity(0.08), radius: 16, y: 6)
    }
}

extension View {
    func chromePill() -> some View { modifier(ChromePill()) }
    func playerPill() -> some View { modifier(PlayerPill()) }
}

extension View {
    /// Content scrolling up under the status bar disappears into the page
    /// colour instead of showing behind the clock.
    func statusBarCover() -> some View {
        overlay(alignment: .top) {
            GeometryReader { geo in
                Color.jBg
                    .frame(height: geo.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Primary action: ink-50 pill with ink-950 text in dark, inverted in light.
struct PrimaryPillStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var onDark = false
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        let light = onDark || scheme == .dark
        configuration.label
            .font(.label)
            .padding(.horizontal, height < 44 ? 16 : 20)
            .frame(height: height)
            .foregroundStyle(light ? Color.ink950 : Color.ink50)
            .background(light ? Color.ink50 : Color.ink950, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The recording dot, breathing between 100% and 70% every 2.4 s.
struct BreathingDot: View {
    var size: CGFloat
    var color: Color = .jLive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.7 : 1)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dim)
            .onAppear { if !reduceMotion { dim = true } }
            .accessibilityLabel("Recording")
    }
}

/// The orange "▍" caret at the end of live text; blinks once a second.
struct Caret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Text("▍").foregroundStyle(Color.jLive.opacity(on ? 1 : 0))
        }
        .accessibilityHidden(true)
    }
}
