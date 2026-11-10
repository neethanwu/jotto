import SwiftUI

/// A recording in progress. Always dark: the timer, the breathing dot,
/// and the latest transcript as it arrives (a couple of minutes behind,
/// since the watch sends audio in two-minute parts).
struct LiveView: View {
    let id: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: SessionDetail?

    private var entry: TimelineEntry? { Library.shared.entries.first { $0.id == id } }
    private var startedAt: Date? { detail?.startedAt ?? entry?.startedAt }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CircleIconButton(glyph: .down, label: "Close", fill: .ink950, color: .ink50, ring: .ink800) { dismiss() }
                Spacer()
                Text("Recording")
                    .font(.label)
                    .foregroundStyle(Color.jLive)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
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

            BreathingDot(size: 124)
                .padding(.top, 36)

            if let startedAt {
                Text("Since \(Format.time(startedAt)) · stop it on your wrist")
                    .font(.metaSmall)
                    .foregroundStyle(Color.ink500)
                    .padding(.top, 24)
            }

            Spacer(minLength: 24)
            captions
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
        }
        .background(Color.ink950.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await poll() }
        .onChange(of: entry?.state) { _, state in
            // Finished on the watch: show the transcript instead.
            if let state, state != .live { dismiss() }
        }
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
                Particles().frame(height: 36)
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
