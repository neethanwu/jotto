import SwiftUI

private extension Color {
    static let live = Color(red: 1, green: 79 / 255, blue: 0)
    static let ink400 = Color(red: 166 / 255, green: 164 / 255, blue: 161 / 255)
    static let ink500 = Color(red: 130 / 255, green: 128 / 255, blue: 125 / 255)
    static let ink700 = Color(red: 76 / 255, green: 74 / 255, blue: 72 / 255)
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
                Image("Wordmark").resizable().scaledToFit().frame(height: 17).accessibilityLabel("Jotto")
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

private struct RecordingScreen: View {
    let recorder: Recorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(clock(context.date))
                    .font(.system(size: 46, weight: .medium).monospacedDigit())
                    .tracking(-0.9)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }

            LevelBars(levels: recorder.levels)
                .frame(height: 22)
                .padding(.horizontal, 8)

            if recorder.state == .interrupted {
                Text("Paused by another app")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink400)
            }

            Button(action: recorder.stop) {
                ZStack {
                    Circle().fill(Color.live).frame(width: 84, height: 84)
                        .opacity(dim ? 0.7 : 1)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dim)
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 26, height: 26)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 5) {
                    Circle().fill(Color.live).frame(width: 7, height: 7)
                    Text(recorder.state == .interrupted ? "Paused" : "Recording")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.live)
            }
        }
        .onAppear {
            // Scoped to the dot: a repeating withAnimation would leak into the timer.
            if !reduceMotion { dim = true }
        }
    }

    private func clock(_ date: Date) -> String {
        let s = Int(date.timeIntervalSince(recorder.startedAt ?? date))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
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
