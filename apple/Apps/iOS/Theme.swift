import SwiftUI
import UIKit

/// Design tokens from docs/04-ios-design.md. Views use only the semantic
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
    static let jSurface = pair(Ink.i50, Ink.i900)
    static let jFill = pair(Ink.i100, Ink.i900)
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
    static let jChromeOn = Color(Ink.i50)
    static let jOnChromeOn = Color(Ink.i950)
    static let jLive = Color(Orange.o500)
    static let jLiveHalo = pair(Orange.o100, Orange.o950)

    // Fixed tones for surfaces that are dark in both modes (Live, share sheet).
    static let ink50 = Color(Ink.i50)
    static let ink400 = Color(Ink.i400)
    static let ink500 = Color(Ink.i500)
    static let ink600 = Color(Ink.i600)
    static let ink700 = Color(Ink.i700)
    static let ink900 = Color(Ink.i900)
    static let ink950 = Color(Ink.i950)
    static let inkPaper = Color(Ink.i50)
    static let inkPaperText = Color(Ink.i950)
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

/// 40pt round icon button on `fill`, used in top bars.
struct CircleIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jText)
                .frame(width: 40, height: 40)
                .background(Color.jFill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

extension View {
    func chromePill() -> some View { modifier(ChromePill()) }
}

/// Primary action: ink-50 pill with ink-950 text in dark, inverted in light.
struct PrimaryPillStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var onDark = false

    func makeBody(configuration: Configuration) -> some View {
        let light = onDark || scheme == .dark
        configuration.label
            .font(.label)
            .padding(.horizontal, 20)
            .frame(height: 44)
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
