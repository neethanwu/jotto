import SwiftUI

/// How much a star covers, as a stretch of time around the tap: the star
/// sits in the middle of an axis, and each end is dragged out to as much
/// as 30 seconds before or after, in 5-second steps.
struct StarReach: View {
    @Bindable var config: AppConfig

    private static let step = 5
    private static let knob: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("A star covers").font(.reading).foregroundStyle(Color.jText)
                Spacer(minLength: 12)
                Text("\(config.momentBefore) s before · \(config.momentAfter) s after")
                    .font(.scaled(15, .medium, relativeTo: .subheadline).monospacedDigit())
                    .foregroundStyle(Color.jText2)
                    .contentTransition(.numericText())
            }
            .padding(.top, 14)

            GeometryReader { geo in
                let width = geo.size.width
                let mid = width / 2
                // Points per second, with room for half a knob at each end.
                let scale = (mid - Self.knob / 2) / CGFloat(Highlight.maxReach)
                let left = mid - CGFloat(config.momentBefore) * scale
                let right = mid + CGFloat(config.momentAfter) * scale
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.jToggleOff).frame(height: 4)
                    Capsule().fill(Color.jText)
                        .frame(width: max(0, right - left), height: 4)
                        .offset(x: left)
                    knob.offset(x: left - Self.knob / 2)
                        .gesture(drag { config.momentBefore = seconds(mid - $0, scale) })
                        .accessibilityElement()
                        .accessibilityLabel("Before the tap")
                        .accessibilityValue("\(config.momentBefore) seconds")
                        .accessibilityAdjustableAction { config.momentBefore = adjust(config.momentBefore, $0) }
                    knob.offset(x: right - Self.knob / 2)
                        .gesture(drag { config.momentAfter = seconds($0 - mid, scale) })
                        .accessibilityElement()
                        .accessibilityLabel("After the tap")
                        .accessibilityValue("\(config.momentAfter) seconds")
                        .accessibilityAdjustableAction { config.momentAfter = adjust(config.momentAfter, $0) }
                    // The tap itself, fixed in the middle.
                    Circle().fill(Color.jText)
                        .frame(width: Self.knob, height: Self.knob)
                        .overlay {
                            GlyphView(glyph: .star, color: .jBg).frame(width: 12, height: 12)
                        }
                        .offset(x: mid - Self.knob / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .frame(height: 48)
                .coordinateSpace(.named("axis"))
            }
            .frame(height: 48)
            .padding(.top, 14)

            HStack {
                Text("\(Highlight.maxReach) s before")
                Spacer()
                Text("You tap")
                Spacer()
                Text("\(Highlight.maxReach) s after")
            }
            .font(.scaled(11, .medium, relativeTo: .caption2).monospacedDigit())
            .foregroundStyle(Color.jText4)
        }
        .sensoryFeedback(.selection, trigger: config.momentBefore)
        .sensoryFeedback(.selection, trigger: config.momentAfter)
        .animation(.easeOut(duration: 0.12), value: config.momentBefore)
        .animation(.easeOut(duration: 0.12), value: config.momentAfter)
    }

    private var knob: some View {
        Circle()
            .fill(Color.jBg)
            .overlay(Circle().strokeBorder(Color.jText5, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            .frame(width: Self.knob, height: Self.knob)
            // A bigger target than it looks.
            .frame(width: 44, height: 48)
            .contentShape(Rectangle())
            .offset(x: -9)
    }

    private func drag(_ moved: @escaping (CGFloat) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("axis"))
            .onChanged { moved($0.location.x) }
    }

    /// Distance from the middle to seconds, snapped to 5, 5…30.
    private func seconds(_ distance: CGFloat, _ scale: CGFloat) -> Int {
        let raw = Double(distance / scale)
        let snapped = Int((raw / Double(Self.step)).rounded()) * Self.step
        return min(Highlight.maxReach, max(Self.step, snapped))
    }

    private func adjust(_ value: Int, _ direction: AccessibilityAdjustmentDirection) -> Int {
        let next = direction == .increment ? value + Self.step : value - Self.step
        return min(Highlight.maxReach, max(Self.step, next))
    }
}

/// Settings → Highlights: a picture of what a star keeps, the two ends
/// to drag, and three lengths to pick at once.
struct HighlightsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var config: AppConfig = .shared

    private static let presets: [(name: String, seconds: Int)] = [("Quick", 5), ("Moment", 10), ("Long", 30)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Highlights", detail: "Tap the star while you record. jotto keeps the moments around it.") { dismiss() }

                StarPicture(before: config.momentBefore, after: config.momentAfter)
                    .padding(.top, 24)

                StarReach(config: config)
                    .padding(.top, 10)

                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.seconds) { preset in
                        let on = config.momentBefore == preset.seconds && config.momentAfter == preset.seconds
                        Button {
                            config.momentBefore = preset.seconds
                            config.momentAfter = preset.seconds
                        } label: {
                            Text("\(preset.name) · \(preset.seconds) s")
                                .font(.scaled(14, .medium, relativeTo: .subheadline))
                                .foregroundStyle(on ? Color.jBg : Color.jText)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(on ? Color.jText : Color.jFill, in: Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// A stretch of speech as bars, the part a star keeps lit around the
/// tap, as wide as the seconds before and after.
private struct StarPicture: View {
    let before: Int
    let after: Int

    private static let heights: [CGFloat] = [10, 16, 22, 14, 26, 18, 30, 12, 20, 28, 16, 24, 34, 18, 26, 14, 30, 22, 12, 28, 18, 24, 32, 16, 20, 26, 14, 22, 30, 18, 12, 24, 16, 28, 20, 14]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - 32
            let mid = width / 2
            let scale = mid / CGFloat(Highlight.maxReach)
            let left = mid - CGFloat(before) * scale
            let right = mid + CGFloat(after) * scale
            let step = width / CGFloat(Self.heights.count)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.jLiveHalo.opacity(0.7))
                    .frame(width: right - left, height: 64)
                    .offset(x: 16 + left, y: 44)
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(Self.heights.enumerated()), id: \.offset) { i, h in
                        let x = (CGFloat(i) + 0.5) * step
                        Capsule()
                            .fill(x >= left && x <= right ? Color.jText : Color.jText5)
                            .frame(width: 3, height: h * 1.4)
                            .frame(width: step)
                    }
                }
                .frame(width: width, height: 64)
                .offset(x: 16, y: 44)
                // The tap.
                Rectangle()
                    .fill(Color.jLive)
                    .frame(width: 1.5, height: 72)
                    .offset(x: 16 + mid - 0.75, y: 40)
                HStack(spacing: 4) {
                    GlyphView(glyph: .star, color: .jLive).frame(width: 10, height: 10)
                    Text("You tap")
                        .font(.scaled(12, .semibold, relativeTo: .caption1))
                        .foregroundStyle(Color.ink50)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color.ink950, in: Capsule())
                .fixedSize()
                .frame(width: 120)
                .offset(x: 16 + mid - 60, y: 12)
                HStack {
                    Text("← \(before) s")
                    Spacer()
                    Text("\(after) s →")
                }
                .font(.scaled(13, .semibold, relativeTo: .footnote).monospacedDigit())
                .foregroundStyle(Color.jText)
                .frame(width: min(width, max(120, right - left)))
                .offset(x: 16 + min(width - min(width, max(120, right - left)), max(0, (left + right) / 2 - min(width, max(120, right - left)) / 2)), y: 116)
                .contentTransition(.numericText())
            }
        }
        .frame(height: 150)
        .background(Color.jWell, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: before)
        .animation(.easeOut(duration: 0.15), value: after)
        .accessibilityElement()
        .accessibilityLabel("A star keeps \(before) seconds before the tap and \(after) seconds after")
    }
}
