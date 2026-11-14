import SwiftUI
import WatchKit

private extension Color {
    static let live = Color(red: 1, green: 79 / 255, blue: 0)
    static let ink400 = Color(red: 166 / 255, green: 164 / 255, blue: 161 / 255)
    static let ink500 = Color(red: 130 / 255, green: 128 / 255, blue: 125 / 255)
    static let ink700 = Color(red: 76 / 255, green: 74 / 255, blue: 72 / 255)
    static let ink800 = Color(red: 52 / 255, green: 51 / 255, blue: 49 / 255)
    static let ink50 = Color(red: 251 / 255, green: 250 / 255, blue: 247 / 255)
    static let ink900 = Color(red: 31 / 255, green: 30 / 255, blue: 28 / 255)
}

/// W1 ready · W2 recording · W3 saved, with W4 (kept on watch) a tap away.
struct RecorderView: View {
    let recorder: Recorder
    let transfer: WatchTransfer

    var body: some View {
        NavigationStack {
            Group {
                if recorder.state != .idle {
                    RecordingScreen(recorder: recorder)
                } else if let saved = recorder.justSaved {
                    SavedScreen(length: saved.length, sentNow: saved.sentNow)
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            recorder.dismissSaved()
                        }
                        .onTapGesture { recorder.dismissSaved() }
                } else {
                    ReadyScreen(recorder: recorder, transfer: transfer)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: recorder.state)
            .animation(.easeInOut(duration: 0.3), value: recorder.justSaved == nil)
        }
    }
}

// MARK: - W1 Ready

private struct ReadyScreen: View {
    let recorder: Recorder
    let transfer: WatchTransfer

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Button(action: recorder.start) {
                    Circle().fill(Color.live).frame(width: 100, height: 100)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record")

                Text("Tap to record")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.top, 4)
                Text(todayLine)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.ink500)

                if !transfer.pending.isEmpty {
                    NavigationLink {
                        KeptScreen(transfer: transfer)
                    } label: {
                        HStack(spacing: 8) {
                            DashedRing()
                            Text("\(transfer.pending.count) \(transfer.pending.count == 1 ? "recording" : "recordings") to send")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.ink900, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // The toolbar centres it lower than the system clock sits;
                // nudged up so its baseline meets the time's.
                Image("Wordmark").resizable().scaledToFit().frame(height: 17)
                    .offset(y: -7)
                    .accessibilityLabel("jotto")
            }
        }
        .onAppear { transfer.refreshPending() }
    }

    private var todayLine: String {
        let today = History.shared.today
        guard !today.isEmpty else { return "Nothing yet today" }
        let minutes = Int(today.map(\.length).reduce(0, +) / 60)
        let length = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
        return "\(today.count) today · \(length)"
    }
}

// MARK: - W2 Recording

/// Star marks a moment, [ ] opens and closes a section, and the dot only
/// stops when held: a white ring runs round it for a second, and letting
/// go before it closes keeps recording.
private struct RecordingScreen: View {
    let recorder: Recorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    @State private var holding = false
    @State private var ring: CGFloat = 0
    @State private var pressedAt: Date?
    @State private var justMarked = false
    @State private var hintFlash = false

    private static let holdDuration: TimeInterval = 1

    var body: some View {
        GeometryReader { geo in
            // Scales from the drawn 208 pt screen down to the 40 mm watch.
            let scale = min(1, geo.size.width / 208)
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clock(since: recorder.startedAt, now: context.date))
                        .font(.system(size: 46 * scale, weight: .medium).monospacedDigit())
                        .tracking(-0.9)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }

                LevelBars(levels: recorder.levels)
                    .frame(height: 22 * scale)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)

                Spacer(minLength: 2)

                HStack(spacing: 0) {
                    starButton(size: 44 * scale)
                    Spacer(minLength: 0)
                    dot(size: 80 * scale)
                    Spacer(minLength: 0)
                    sectionButton(size: 44 * scale)
                }
                .padding(.horizontal, 14 * scale)

                Text(hint)
                    .font(.system(size: 11, weight: holding ? .semibold : .medium))
                    .foregroundStyle(holding || hintFlash ? Color.ink50 : Color.ink500)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 6)
                    // Clear of the screen's rounded corners.
                    .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(edges: .bottom)
        .toolbar {
            // Nudged up to sit on the system clock's baseline, like the wordmark.
            ToolbarItem(placement: .topBarLeading) { status.offset(y: -9.5) }
        }
        .task(id: recorder.lastMarkAt) {
            guard recorder.lastMarkAt != nil else { return }
            justMarked = true
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { justMarked = false }
        }
        .onAppear {
            // Scoped to the dot: a repeating withAnimation would leak into the timer.
            if !reduceMotion { dim = true }
        }
    }

    // MARK: Status line

    private var status: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.live).frame(width: 7, height: 7)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(statusText(now: context.date))
            }
        }
        .font(.system(size: 15, weight: .semibold).monospacedDigit())
        .foregroundStyle(Color.live)
    }

    private func statusText(now: Date) -> String {
        if recorder.state == .interrupted { return "Paused" }
        if justMarked { return "Marked · \(recorder.marks)" }
        if let begin = recorder.sectionStartedAt { return "Section \(clock(since: begin, now: now))" }
        return "Recording"
    }

    private var hint: String {
        if holding { return "Let go to keep recording" }
        if hintFlash { return "Hold the dot to stop" }
        if recorder.state == .interrupted { return "Paused by another app" }
        if recorder.sectionStartedAt != nil { return "Tap [ ] to end the section" }
        return "Hold the dot to stop"
    }

    // MARK: Controls

    private func starButton(size: CGFloat) -> some View {
        Button { recorder.mark(source: "button") } label: {
            // Drawn like the [ ] beside it, so both sit at the same size
            // and centre; the SF star rode high in its circle.
            Star()
                .fill(Color.ink50)
                .frame(width: size * 0.45, height: size * 0.45)
                .frame(width: size, height: size)
                .background(justMarked ? Color.live : Color.ink800, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(holding ? 0.35 : 1)
        .disabled(holding)
        // Double tap marks too; stopping stays on the dot.
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel("Mark this moment")
    }

    private func sectionButton(size: CGFloat) -> some View {
        let open = recorder.sectionStartedAt != nil
        return Button(action: recorder.toggleSection) {
            Brackets()
                .stroke(Color.ink50, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.41, height: size * 0.41)
                .frame(width: size, height: size)
                .background(open ? Color.live : Color.ink800, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(holding ? 0.35 : 1)
        .disabled(holding)
        .accessibilityLabel(open ? "End section" : "Start section")
    }

    private func dot(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.live)
                .frame(width: holding ? size * 0.95 : size, height: holding ? size * 0.95 : size)
                .opacity(holding ? 1 : dim ? 0.7 : 1)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dim)
            RoundedRectangle(cornerRadius: size * 0.0625)
                .fill(Color.ink50)
                .frame(width: size * 0.275, height: size * 0.275)
                .opacity(holding ? 1 : 0)
            Group {
                Circle().stroke(Color.ink50.opacity(0.18), lineWidth: 3).opacity(holding ? 1 : 0)
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(Color.ink50, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size * 1.125, height: size * 1.125)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 40) {
            recorder.stop()
        } onPressingChanged: { pressing in
            pressed(pressing)
        }
        .accessibilityElement()
        .accessibilityLabel("Stop recording")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { recorder.stop() }
    }

    private func pressed(_ pressing: Bool) {
        if pressing {
            pressedAt = .now
            WKInterfaceDevice.current().play(.click)
            withAnimation(.easeOut(duration: 0.12)) { holding = true }
            withAnimation(.linear(duration: Self.holdDuration)) { ring = 1 }
        } else {
            let wasTap = pressedAt.map { Date.now.timeIntervalSince($0) < 0.25 } ?? false
            pressedAt = nil
            withAnimation(.easeOut(duration: 0.2)) {
                holding = false
                ring = 0
            }
            if wasTap { flashHint() }
        }
    }

    /// A tap on the dot is someone trying to stop: say how.
    private func flashHint() {
        hintFlash = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            hintFlash = false
        }
    }

    private func clock(since start: Date?, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start ?? now)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The star, on the design's 24-unit grid, moved down so its points
/// (not just its box) sit in the middle.
private struct Star: Shape {
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

/// The section icon, on the design's 24-unit grid.
private struct Brackets: Shape {
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

/// 30 thin bars, oldest dim on the left, the newest orange on the right.
private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                    let age = Double(i) / Double(max(1, levels.count - 1))
                    Capsule()
                        .fill(i == levels.count - 1 ? Color.live : Color.white.opacity(0.25 + 0.75 * age))
                        .frame(width: 2, height: max(2, CGFloat(level) * geo.size.height))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - W3 Saved

private struct SavedScreen: View {
    let length: TimeInterval
    let sentNow: Bool
    @State private var drawn: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 100, height: 100)
                Checkmark()
                    .trim(from: 0, to: drawn)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 34, height: 26)
            }
            Text("Saved").font(.system(size: 17, weight: .semibold)).padding(.top, 4)
            Text("\(clock) · \(sentNow ? "to iPhone" : "on this watch")")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ink500)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.easeOut(duration: 0.35).delay(0.15)) { drawn = 1 } }
        .accessibilityElement(children: .combine)
    }

    private var clock: String {
        let s = Int(length)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// MARK: - W4 Kept on watch

private struct KeptScreen: View {
    let transfer: WatchTransfer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kept on your watch").font(.system(size: 17, weight: .semibold))
                Text("Sends when iPhone is near")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink400)
                    .padding(.bottom, 6)
                ForEach(transfer.pending) { item in
                    HStack(spacing: 8) {
                        DashedRing()
                        Text(item.startedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                            .font(.system(size: 15, weight: .medium).monospacedDigit())
                        Spacer()
                        Text("\(max(1, Int(item.length / 60))) min")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.ink400)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color.ink900, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
        .onAppear { transfer.refreshPending() }
    }
}

/// Waiting: the same dashed ring as "processing" on the phone timeline.
private struct DashedRing: View {
    var body: some View {
        Circle()
            .strokeBorder(Color.ink400, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.2]))
            .frame(width: 12, height: 12)
    }
}
