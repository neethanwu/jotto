import SwiftUI

/// Settings → Highlights: what a star keeps, drawn on a stretch of speech
/// and dragged by its edges; three lengths to pick at once; and sections,
/// which you start and end yourself.
struct HighlightsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var config: AppConfig = .shared

    private static let presets: [(name: String, seconds: Int)] = [("Quick", 5), ("Moment", 10), ("Long", 30)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Highlights", detail: "Tap the star while you record. jotto keeps the moments around it.") { dismiss() }

                StarReach(config: config)
                    .padding(.top, 24)

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

                HStack(alignment: .top, spacing: 14) {
                    GlyphView(glyph: .brackets, color: .jText)
                        .frame(width: 16, height: 16)
                        .frame(width: 36, height: 36)
                        .background(Color.jFill, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sections")
                            .font(.scaled(16, .semibold, relativeTo: .callout))
                            .foregroundStyle(Color.jText)
                        Text("For a longer part, tap [ ] to start a section and again to end it. One left open ends after 10 minutes.")
                            .font(.scaled(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(Color.jText3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(.top, 32)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// How much a star covers, set on the picture itself: a stretch of speech
/// as bars, the tap in the middle, and the part kept lit around it. Each
/// edge of that part is dragged out to as much as 30 seconds before or
/// after, in 5-second steps.
struct StarReach: View {
    @Bindable var config: AppConfig

    private static let step = 5
    private static let inset: CGFloat = 16
    private static let heights: [CGFloat] = [10, 16, 22, 14, 26, 18, 30, 12, 20, 28, 16, 24, 34, 18, 26, 14, 30, 22, 12, 28, 18, 24, 32, 16, 20, 26, 14, 22, 30, 18, 12, 24, 16, 28, 20, 14]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - Self.inset * 2
            let mid = width / 2
            let scale = mid / CGFloat(Highlight.maxReach)
            let left = mid - CGFloat(config.momentBefore) * scale
            let right = mid + CGFloat(config.momentAfter) * scale
            let step = width / CGFloat(Self.heights.count)
            let labelWidth = min(width, max(120, right - left))
            ZStack(alignment: .topLeading) {
                // The part kept.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.jLiveHalo.opacity(0.7))
                    .frame(width: right - left, height: 72)
                    .offset(x: Self.inset + left, y: 44)
                HStack(spacing: 0) {
                    ForEach(Array(Self.heights.enumerated()), id: \.offset) { i, h in
                        let x = (CGFloat(i) + 0.5) * step
                        Capsule()
                            .fill(x >= left && x <= right ? Color.jText : Color.jText5)
                            .frame(width: 3, height: h * 1.4)
                            .frame(width: step)
                    }
                }
                .frame(width: width, height: 72)
                .offset(x: Self.inset, y: 44)
                // The tap.
                Rectangle()
                    .fill(Color.jLive)
                    .frame(width: 1.5, height: 80)
                    .offset(x: Self.inset + mid - 0.75, y: 40)
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
                .offset(x: Self.inset + mid - 60, y: 10)
                .accessibilityHidden(true)

                handle(at: left, label: "Before the tap", seconds: $config.momentBefore, scale: scale) { mid - $0 }
                handle(at: right, label: "After the tap", seconds: $config.momentAfter, scale: scale) { $0 - mid }

                HStack {
                    Text("← \(config.momentBefore) s")
                    Spacer()
                    Text("\(config.momentAfter) s →")
                }
                .font(.scaled(13, .semibold, relativeTo: .footnote).monospacedDigit())
                .foregroundStyle(Color.jText)
                .contentTransition(.numericText())
                .frame(width: labelWidth)
                .offset(x: Self.inset + min(width - labelWidth, max(0, (left + right) / 2 - labelWidth / 2)), y: 126)
                .accessibilityHidden(true)

                Text("Drag either edge")
                    .font(.scaled(11, .medium, relativeTo: .caption2))
                    .foregroundStyle(Color.jText4)
                    .frame(width: width)
                    .offset(x: Self.inset, y: 152)
                    .accessibilityHidden(true)
            }
            .coordinateSpace(.named("reach"))
        }
        .frame(height: 180)
        .background(Color.jWell, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .sensoryFeedback(.selection, trigger: config.momentBefore)
        .sensoryFeedback(.selection, trigger: config.momentAfter)
        .animation(.easeOut(duration: 0.12), value: config.momentBefore)
        .animation(.easeOut(duration: 0.12), value: config.momentAfter)
    }

    /// A grip on one edge of the lit part: drawn as a short bar, touched
    /// as a 44-point column.
    private func handle(at x: CGFloat, label: String, seconds: Binding<Int>, scale: CGFloat,
                        distance: @escaping (CGFloat) -> CGFloat) -> some View {
        // Like the knob of a slider, stood on end.
        Capsule()
            .fill(Color.jBg)
            .overlay(Capsule().strokeBorder(Color.jText5, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
            .frame(width: 12, height: 48)
            .frame(width: 44, height: 88)
            .contentShape(Rectangle())
            .offset(x: Self.inset + x - 22, y: 36)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("reach"))
                    .onChanged { seconds.wrappedValue = snap(distance($0.location.x - Self.inset), scale) }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(seconds.wrappedValue) seconds")
            .accessibilityAdjustableAction { direction in
                let next = seconds.wrappedValue + (direction == .increment ? Self.step : -Self.step)
                seconds.wrappedValue = min(Highlight.maxReach, max(Self.step, next))
            }
    }

    /// Points from the middle to seconds, snapped to 5, 5…30.
    private func snap(_ distance: CGFloat, _ scale: CGFloat) -> Int {
        let pointsPerSecond = max(scale, 0.1)
        let raw = Double(distance / pointsPerSecond)
        let snapped = Int((raw / Double(Self.step)).rounded()) * Self.step
        return min(Highlight.maxReach, max(Self.step, snapped))
    }
}
