import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct JottoLiveActivities: WidgetBundle {
    var body: some Widget { RecordingLiveActivity() }
}

private let orange = Color(red: 1, green: 79 / 255, blue: 0)
private let ink50 = Color(red: 251 / 255, green: 250 / 255, blue: 247 / 255)
private let ink500 = Color(red: 130 / 255, green: 128 / 255, blue: 125 / 255)
private let ink800 = Color(red: 52 / 255, green: 51 / 255, blue: 49 / 255)

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivity.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(ink50)
                .widgetURL(Self.url(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Circle().fill(orange).frame(width: 40, height: 40).padding(.leading, 4).padding(.top, 4)
                }
                // Title and the clock share the centre, so the clock has room.
                DynamicIslandExpandedRegion(.center) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recording").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink50)
                            Text(Self.meta(context, short: true)).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(ink500)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.system(size: 28, weight: .medium).monospacedDigit())
                            .foregroundStyle(ink50)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 84, alignment: .trailing)
                    }
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        // The latest line once there is one; until then, the sound.
                        if let line = context.state.lastLine {
                            Text("…" + line).font(.system(size: 14)).foregroundStyle(ink500).lineLimit(1)
                                .frame(height: 18)
                        } else {
                            SoundLine().frame(height: 18)
                        }
                        Controls(context: context)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Circle().fill(orange).frame(width: 12, height: 12).padding(.leading, 4)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(ink50)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
            } minimal: {
                Circle().fill(orange).frame(width: 12, height: 12)
            }
            .widgetURL(Self.url(context))
            .keylineTint(orange)
        }
    }

    static func url(_ context: ActivityViewContext<RecordingActivity>) -> URL? {
        URL(string: "jotto://live/\(context.attributes.sessionID)")
    }

    /// "Since 14:00 · 2 marks"; in the island, "14:00 · 2 marks".
    static func meta(_ context: ActivityViewContext<RecordingActivity>, short: Bool = false) -> String {
        let time = context.attributes.startedAt.formatted(date: .omitted, time: .shortened)
        let since = short ? time : "Since " + time
        let marks = context.state.marks
        return marks == 0 ? since : "\(since) · \(marks) \(marks == 1 ? "mark" : "marks")"
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivity>

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle().fill(orange).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink50)
                    Text(RecordingLiveActivity.meta(context))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(ink500)
                }
                Spacer(minLength: 8)
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 30, weight: .medium).monospacedDigit())
                    .foregroundStyle(ink50)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            // No transcript on the lock screen (anyone can see it): the sound instead.
            SoundLine().frame(height: 18)
            Controls(context: context)
        }
        .padding(16)
    }
}

/// The wordmark, then Mark and Section, as on the phone's Live screen.
private struct Controls: View {
    let context: ActivityViewContext<RecordingActivity>

    var body: some View {
        HStack(spacing: 8) {
            Image("Wordmark").resizable().scaledToFit().frame(height: 16).accessibilityLabel("Jotto")
            Spacer()
            Button(intent: MarkMomentIntent(sessionID: context.attributes.sessionID)) {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 11, weight: .bold))
                    Text("Mark")
                }
            }
            .buttonStyle(Pill(accent: false))
            Button(intent: ToggleSectionIntent(sessionID: context.attributes.sessionID)) {
                HStack(spacing: 6) {
                    Brackets().stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 11, height: 11)
                    Text(context.state.sectionOpen ? "End section" : "Section")
                }
            }
            .buttonStyle(Pill(accent: context.state.sectionOpen))
        }
    }
}

private struct Pill: ButtonStyle {
    let accent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(accent ? orange : ink50)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(ink800, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The [ ] of a section, on the design's 24-unit grid.
private struct Brackets: Shape {
    func path(in rect: CGRect) -> Path {
        let u = rect.width / 24
        var p = Path()
        p.move(to: CGPoint(x: 9 * u, y: 4.5 * u)); p.addLine(to: CGPoint(x: 5.5 * u, y: 4.5 * u))
        p.addLine(to: CGPoint(x: 5.5 * u, y: 19.5 * u)); p.addLine(to: CGPoint(x: 9 * u, y: 19.5 * u))
        p.move(to: CGPoint(x: 15 * u, y: 4.5 * u)); p.addLine(to: CGPoint(x: 18.5 * u, y: 4.5 * u))
        p.addLine(to: CGPoint(x: 18.5 * u, y: 19.5 * u)); p.addLine(to: CGPoint(x: 15 * u, y: 19.5 * u))
        return p
    }
}

/// Level bars, drawn still (a Live Activity can't move them): older on the
/// left and dimmer, the newest orange, as on the watch.
private struct SoundLine: View {
    private static let heights: [CGFloat] = [0.25, 0.4, 0.3, 0.55, 0.35, 0.7, 0.45, 0.3, 0.6, 0.4, 0.8, 0.5, 0.35, 0.65,
                                             0.45, 0.9, 0.4, 0.6, 0.3, 0.7, 0.5, 0.85, 0.4, 0.55, 0.35, 0.75, 0.5, 0.6,
                                             0.4, 0.95, 0.55, 0.7, 0.45, 0.8, 0.5, 1]
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(Self.heights.enumerated()), id: \.offset) { i, h in
                    let age = Double(i) / Double(Self.heights.count - 1)
                    Capsule()
                        .fill(i == Self.heights.count - 1 ? orange : ink50.opacity(0.18 + 0.5 * age))
                        .frame(width: 2.5, height: max(2.5, h * geo.size.height))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
