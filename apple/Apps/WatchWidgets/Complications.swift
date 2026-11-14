import SwiftUI
import WidgetKit

/// jotto on the watch face: the orange dot that opens it, and while it
/// records, that it is recording and for how long (W6 in Paper).
struct JottoComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchFace.kind, provider: FaceProvider()) { entry in
            FaceView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("jotto")
        .description("Tap to record. Shows the recording while it runs.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct FaceEntry: TimelineEntry {
    let date: Date
    let state: WatchFace.State
}

struct FaceProvider: TimelineProvider {
    func placeholder(in context: Context) -> FaceEntry { FaceEntry(date: .now, state: .init(todayCount: 2, todaySeconds: 1500)) }

    func getSnapshot(in context: Context, completion: @escaping (FaceEntry) -> Void) {
        completion(FaceEntry(date: .now, state: context.isPreview ? .init(todayCount: 2, todaySeconds: 1500) : WatchFace.load()))
    }

    /// The app reloads the timeline when a recording starts or stops; a
    /// refresh after midnight resets "today".
    func getTimeline(in context: Context, completion: @escaping (Timeline<FaceEntry>) -> Void) {
        let midnight = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400 + 60)
        completion(Timeline(entries: [FaceEntry(date: .now, state: WatchFace.load())], policy: .after(midnight)))
    }
}

private let orange = Color(red: 1, green: 79 / 255, blue: 0)

struct FaceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FaceEntry

    private var since: Date? { entry.state.recordingSince }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryRectangular: rectangular
        default: inline
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle().fill(orange).padding(since == nil ? 13 : 16).widgetAccentable()
            if since != nil {
                Circle().stroke(orange, lineWidth: 2).padding(9).widgetAccentable()
            }
        }
        .accessibilityLabel(since == nil ? "Record with jotto" : "jotto is recording")
    }

    private var corner: some View {
        Circle().fill(orange).padding(6).widgetAccentable()
            .widgetLabel {
                if let since {
                    Text(since, style: .timer).monospacedDigit()
                } else {
                    Text("jotto")
                }
            }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let since {
                HStack(spacing: 5) {
                    Circle().fill(orange).frame(width: 7, height: 7).widgetAccentable()
                    Text("Recording").font(.system(size: 15, weight: .semibold)).foregroundStyle(orange).widgetAccentable()
                    Spacer(minLength: 4)
                    Text(since, style: .timer).font(.system(size: 15, weight: .medium).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
                LevelLine().frame(height: 14)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(orange).frame(width: 12, height: 12).widgetAccentable()
                    Text("Tap to record").font(.system(size: 15, weight: .semibold))
                }
                Text(WatchFace.todayLine(entry.state))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        if let since {
            Text("● Recording ") + Text(since, style: .timer)
        } else {
            Text("jotto · \(WatchFace.todayLine(entry.state))")
        }
    }
}

/// The recording's level bars, drawn still: a face can't move them.
private struct LevelLine: View {
    private static let heights: [CGFloat] = [0.3, 0.5, 0.35, 0.7, 0.45, 0.9, 0.4, 0.6, 0.3, 0.8, 0.5, 0.65, 0.35,
                                             0.55, 0.9, 0.4, 0.7, 0.3, 0.6, 0.45, 0.8, 0.5, 0.35, 1]
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(Self.heights.enumerated()), id: \.offset) { i, h in
                    Capsule()
                        .fill(i == Self.heights.count - 1 ? orange : Color.white.opacity(0.3 + 0.6 * Double(i) / 24))
                        .frame(width: 2, height: max(2, h * geo.size.height))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
