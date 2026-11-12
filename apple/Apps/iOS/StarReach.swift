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

            Text("Drag either end. Sections cover exactly what you mark.")
                .font(.scaled(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Color.jText3)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .sensoryFeedback(.selection, trigger: config.momentBefore)
        .sensoryFeedback(.selection, trigger: config.momentAfter)
        .animation(.easeOut(duration: 0.12), value: config.momentBefore)
        .animation(.easeOut(duration: 0.12), value: config.momentAfter)
    }

    private var knob: some View {
        Circle()
            .fill(Color.jBg)
            .overlay(Circle().strokeBorder(Color.jRing, lineWidth: 1))
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
