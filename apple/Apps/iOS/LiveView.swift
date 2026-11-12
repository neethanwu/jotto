import SwiftUI

/// A recording in progress. Always dark: the timer, the breathing dot,
/// Mark and Section (the same as the watch's star and [ ]), and the latest
/// transcript as it arrives (a couple of minutes behind, since the watch
/// sends audio in two-minute parts). Hold the dot for a second to stop,
/// as on the watch: the phone asks the watch to stop, or stops itself when
/// the recording is on the phone.
struct LiveView: View {
    let id: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: SessionDetail?
    /// The star turns orange for a moment after a mark, as on the watch.
    @State private var justMarked = false
    @State private var holding = false
    /// When the phone asked the watch to stop, until the recording ends.
    @State private var stopAskedAt: Date?
    /// How far the screen has been pulled down to close it.
    @State private var pull: CGFloat = 0
    private var pipeline: Pipeline { .shared }
    private var sectionOpen: Bool { pipeline.openSections[id] != nil }
    private var highlightCount: Int {
        let r = LocalStore.shared.recordings[id]
        return (r?.marks.count ?? 0) + (r?.sections?.count ?? 0)
    }

    private var entry: TimelineEntry? { Library.shared.entries.first { $0.id == id } }
    private var startedAt: Date? { detail?.startedAt ?? entry?.startedAt }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CircleIconButton(glyph: .down, label: "Close", fill: .ink900, color: .ink50) { dismiss() }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.clock(startedAt.map { context.date.timeIntervalSince($0) } ?? 0))
                    .font(.timer)
                    .tracking(-1.44)
                    .foregroundStyle(Color.ink50)
                    .contentTransition(.numericText())
            }
            .padding(.top, 40)

            HoldToStopDot(holding: $holding) { stop() }
                .padding(.top, 36)

            if let startedAt {
                HStack(spacing: 10) {
                    LivePill(label: "Mark", glyph: .star, accent: justMarked) { mark(startedAt) }
                    LivePill(label: sectionOpen ? "End section" : "Section", glyph: .brackets, accent: sectionOpen) {
                        pipeline.toggleSection(id, startedAt: startedAt)
                    }
                }
                .padding(.top, 20)
                .sensoryFeedback(.impact(weight: .medium), trigger: highlightCount)
                .sensoryFeedback(.selection, trigger: sectionOpen)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(metaLine(startedAt, now: context.date))
                    .font(.scaled(13, .medium, relativeTo: .footnote))
                    .foregroundStyle(Color.ink500)
                    .contentTransition(.numericText())
                }
                    .padding(.top, 20)
                    .animation(.easeOut(duration: 0.2), value: highlightCount)
            }

            Spacer(minLength: 24)
            captions
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
        }
        .background {
            // Rounded at the top once it's being pulled, like a card.
            UnevenRoundedRectangle(topLeadingRadius: pull > 0 ? 44 : 0, topTrailingRadius: pull > 0 ? 44 : 0, style: .continuous)
                .fill(Color.ink950)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.15), value: pull > 0)
        }
        .offset(y: pull)
        // Pull down anywhere to close, like a sheet; the recording carries on.
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    let dy = value.translation.height
                    guard dy > 0, dy > abs(value.translation.width), !holding else { return }
                    pull = dy
                }
                .onEnded { value in
                    guard pull > 0 else { return }
                    if pull > 140 || value.predictedEndTranslation.height > 420 {
                        dismiss()
                    } else {
                        withAnimation(.spring(duration: 0.3, bounce: 0.1)) { pull = 0 }
                    }
                }
        )
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await poll() }
        .onChange(of: entry?.state) { old, state in
            // Finished on the watch: show the transcript instead. Gone
            // altogether: stopped within a few seconds, taken for a mistake.
            if let state, state != .live { dismiss() }
            if old != nil, state == nil { dismiss() }
        }
    }

    private func mark(_ startedAt: Date) {
        pipeline.markNow(id, startedAt: startedAt)
        withAnimation(.easeOut(duration: 0.15)) { justMarked = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.3)) { justMarked = false }
        }
    }

    private var onPhone: Bool { PhoneRecorder.shared.sessionID == id }

    private func stop() {
        if onPhone {
            PhoneRecorder.shared.stop()
            return
        }
        stopAskedAt = .now
        if !Inbox.shared.askWatchToStop(id) { stopAskedAt = .distantPast }
    }

    private func metaLine(_ startedAt: Date, now: Date) -> String {
        if holding { return "Keep holding to stop · let go to keep recording" }
        if onPhone, PhoneRecorder.shared.interrupted { return "Paused while the microphone is in use · carries on after" }
        if let asked = stopAskedAt {
            return now.timeIntervalSince(asked) < 10 ? "Stopping on your watch" : "Couldn't reach your watch. Stop it on your wrist"
        }
        let count = highlightCount
        if sectionOpen { return count == 0 ? "Section open" : "Section open · \(Format.plural(count, "mark"))" }
        let lead = count == 0 ? "Since \(Format.time(startedAt))" : Format.plural(count, "mark")
        return "\(lead) · hold the dot to stop"
    }

    private var lines: [String] {
        (detail?.blocks ?? [])
            .filter { $0.backchannel != true }
            .suffix(3)
            .map { $0.clean ?? $0.text }
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(lines.dropLast().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.summary)
                    .foregroundStyle(Color.ink700)
                    .lineLimit(2)
            }
            if !reduceMotion && !lines.isEmpty {
                Particles().frame(height: 96)
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let blink = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                (Text(lines.last.map(tail) ?? "Listening. Text arrives a couple of minutes behind")
                    .foregroundStyle(lines.isEmpty ? Color.ink500 : Color.ink50)
                    + Text("▍").foregroundStyle(Color.jLive.opacity(blink ? 1 : 0)))
                    .font(.caption22)
                    .tracking(-0.22)
                    .lineSpacing(10)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.4), value: lines)
    }

    /// The end of a long paragraph, so the caret always shows.
    private func tail(_ line: String) -> String {
        let limit = line.unicodeScalars.contains { $0.value >= 0x3000 } ? 64 : 150
        guard line.count > limit else { return line }
        let cut = line.suffix(limit)
        let start = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[start...]
    }

    private func poll() async {
        while !Task.isCancelled {
            if let fresh = try? await API.session(id) { detail = fresh }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// Grey and orange specks drifting left to right and settling into a line:
/// sound turning into text.
private struct Particles: View {
    private struct Speck {
        let y: Double, speed: Double, phase: Double, size: Double, orange: Bool
    }

    private let specks: [Speck] = (0..<46).map { i in
        var g = SystemRandomNumberGenerator()
        return Speck(
            y: Double.random(in: 0...1, using: &g),
            speed: Double.random(in: 0.08...0.2, using: &g),
            phase: Double(i) / 46,
            size: Double.random(in: 1.5...3, using: &g),
            orange: i % 7 == 0
        )
    }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                for s in specks {
                    let x = (s.phase + t * s.speed).truncatingRemainder(dividingBy: 1)
                    // Spread out on the left, gathering toward the baseline on the right.
                    let spread = 1 - x
                    let y = size.height * (0.85 - (s.y - 0.5) * spread * 1.4 - 0.35 * spread)
                    let alpha = min(1, x * 4) * min(1, (1 - x) * 3)
                    let rect = CGRect(x: x * size.width, y: y, width: s.size, height: s.size)
                    ctx.fill(Circle().path(in: rect),
                             with: .color((s.orange ? Color.jLive : Color.ink500).opacity(alpha * 0.9)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Mark and Section on the Live screen: 44 high, ink-900 with a faint
/// ring; orange while a section is open or just after a mark.
private struct LivePill: View {
    let label: String
    let glyph: Glyph
    let accent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                GlyphView(glyph: glyph, color: accent ? .jLive : .ink50)
                    .frame(width: 15, height: 15)
                Text(label)
                    .font(.scaled(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(accent ? Color.jLive : Color.ink50)
                    .contentTransition(.interpolate)
            }
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .frame(height: 44)
            .background(Color.ink900, in: Capsule())
            .overlay(Capsule().strokeBorder(accent ? Color.jLive.opacity(0.6) : Color(white: 0.18), lineWidth: 1))
            .animation(.easeOut(duration: 0.2), value: accent)
        }
        .buttonStyle(PressStyle())
    }
}

/// The breathing dot, held for a second to stop, like the watch's: a
/// ring fills around it while the finger stays; letting go early keeps
/// recording.
private struct HoldToStopDot: View {
    @Binding var holding: Bool
    let onStop: () -> Void
    @State private var progress: CGFloat = 0
    @State private var stops = 0

    var body: some View {
        BreathingDot(size: 124)
            .scaleEffect(holding ? 0.94 : 1)
            .animation(.spring(duration: 0.25), value: holding)
            .overlay {
                ZStack {
                    Circle().stroke(Color.ink800, lineWidth: 3).opacity(holding ? 1 : 0)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.jLive, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 144, height: 144)
                .allowsHitTesting(false)
            }
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: 1, maximumDistance: 40) {
                stops += 1
                onStop()
            } onPressingChanged: { pressing in
                holding = pressing
                if pressing {
                    withAnimation(.linear(duration: 1)) { progress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: holding) { _, now in now }
            .sensoryFeedback(.success, trigger: stops)
            .accessibilityElement()
            .accessibilityLabel("Recording")
            .accessibilityHint("Hold for a second to stop")
            .accessibilityAction(named: "Stop recording") { onStop() }
    }
}
