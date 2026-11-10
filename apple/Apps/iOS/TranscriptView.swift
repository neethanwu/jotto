import SwiftUI

/// One recording: title Jotto wrote (tap to rename), the transcript in its
/// Clean or Original form, and a player at the bottom.
struct TranscriptView: View {
    let id: String
    /// Open scrolled to this moment (from search).
    var startAt: Double?

    @Environment(\.dismiss) private var dismiss
    @State private var detail: SessionDetail?
    @State private var error: String?
    @State private var showOriginal = AppConfig.shared.opensOriginal
    @State private var player = RecordingPlayer()
    @State private var sharing = false
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var scrolledToStart = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    if let detail {
                        content(detail)
                            .padding(.bottom, 140)
                    } else if let error {
                        Text(error).font(.summary).foregroundStyle(Color.jText3).padding(20)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: detail?.blocks.count) { _, _ in scrollToStart(proxy) }
                .onChange(of: currentBlock) { _, block in
                    let scrubbing = player.scrubTime != nil
                    guard player.isPlaying || scrubbing, let block else { return }
                    withAnimation(.easeInOut(duration: scrubbing ? 0.15 : 0.3)) { proxy.scrollTo(block, anchor: .center) }
                }
                .sensoryFeedback(.selection, trigger: currentBlock) { _, _ in player.scrubTime != nil }
            }
        }
        .background(Color.jBg)
        .overlay(alignment: .bottom) {
            if let detail { PlayerBar(player: player, hasAudio: !detail.segments.isEmpty) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $sharing) {
            if let detail { ShareSheet(detail: detail, title: title(detail)) }
        }
        .sheet(isPresented: $renaming) {
            if let detail {
                RenameSheet(detail: detail, current: title(detail)) { newTitle in
                    Task { await rename(to: newTitle) }
                }
            }
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete recording and audio", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The text and audio are removed from your iPhone and the server")
        }
        .task { await poll() }
        .onDisappear { player.stop() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            CircleIconButton(systemName: "chevron.left", label: "Back") { dismiss() }
            Spacer()
            Menu {
                Button("Rename", systemImage: "pencil") { renaming = true }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.jText)
                    .frame(width: 40, height: 40)
                    .background(Color.jFill, in: Circle())
            }
            .accessibilityLabel("More")
            CircleIconButton(systemName: "square.and.arrow.up", label: "Share") { sharing = true }
                .disabled(detail == nil)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: - Content

    private func content(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(meta(detail))
                .font(.meta)
                .foregroundStyle(Color.jText3)
                .padding(.top, 12)

            Button { renaming = true } label: {
                Text(title(detail))
                    .font(.transcriptTitle)
                    .tracking(-0.68)
                    .foregroundStyle(Color.jText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .accessibilityHint("Rename")

            if detail.titleByUser != true {
                Button { renaming = true } label: {
                    Label(detail.title == nil ? "Jotto names it once there is enough to go on" : "Title by Jotto · tap to rename",
                          systemImage: "pencil")
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }

            viewSwitch(detail)
                .padding(.top, 24)

            status(detail)

            paragraphs(detail)
                .padding(.top, 20)
        }
        .padding(.horizontal, 20)
    }

    private func viewSwitch(_ detail: SessionDetail) -> some View {
        let fillers = detail.blocks.reduce(0) { n, b in
            n + (b.clean.map { Fillers.diff(raw: b.text, clean: $0).removedRuns } ?? 0)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 20) {
                tabButton("Clean", selected: !showOriginal) { showOriginal = false }
                tabButton("Original", selected: showOriginal) { showOriginal = true }
                Spacer()
                if fillers > 0 {
                    Text("\(fillers) \(fillers == 1 ? "filler" : "fillers") gone")
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                }
            }
            Rectangle().fill(Color.jHairline).frame(height: 1)
        }
    }

    private func tabButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.label)
                .foregroundStyle(selected ? Color.jText : Color.jText3)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Color.jText : .clear).frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func status(_ detail: SessionDetail) -> some View {
        let note: String? = switch detail.status {
        case "recording": "Still recording. Text arrives a couple of minutes behind"
        case "processing":
            if let total = detail.segmentCount, total > 0 {
                "Transcribing · \(detail.segments.filter { $0.status == "done" || $0.status == "failed" }.count) of \(total) parts"
            } else { "Transcribing" }
        default:
            (detail.missingSegments ?? 0) > 0
                ? "\(Format.plural(detail.missingSegments ?? 0, "part")) never reached your iPhone, so there are gaps"
                : nil
        }
        if let note {
            Text(note)
                .font(.metaSmall)
                .foregroundStyle(Color.jText3)
                .padding(.top, 16)
        }
    }

    private func paragraphs(_ detail: SessionDetail) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(rows(detail)) { row in
                ParagraphView(
                    row: row,
                    showOriginal: showOriginal,
                    isCurrent: currentBlock == row.block.id
                ) {
                    player.seek(to: row.block.start)
                }
                .id(row.block.id)
            }
        }
    }

    // MARK: - Data

    struct Row: Identifiable {
        let block: TranscriptBlock
        let showSpeaker: Bool
        let newSection: Bool
        var id: Int { block.id }
    }

    private func rows(_ detail: SessionDetail) -> [Row] {
        let visible = detail.blocks.filter { showOriginal || $0.backchannel != true }
        var rows: [Row] = []
        var previous: TranscriptBlock?
        for block in visible {
            let newSection = previous.map { $0.section != block.section } ?? false
            let showSpeaker = block.speaker != nil && (previous == nil || newSection || previous?.speaker != block.speaker)
            rows.append(Row(block: block, showSpeaker: showSpeaker, newSection: newSection))
            previous = block
        }
        return rows
    }

    private var currentBlock: Int? {
        guard let detail, player.shownTime > 0 else { return nil }
        return detail.blocks.last { $0.start <= player.shownTime + 0.1 }?.id
    }

    private func title(_ detail: SessionDetail) -> String {
        detail.title ?? Format.provisionalTitle(detail.startedAt)
    }

    private func meta(_ detail: SessionDetail) -> String {
        var parts = [Format.weekdayDayMonth(detail.startedAt), Format.time(detail.startedAt)]
        if let end = detail.endedAt { parts.append(Format.length(end.timeIntervalSince(detail.startedAt))) }
        let speakers = Set(detail.blocks.compactMap(\.speaker)).count
        if speakers > 1 { parts.append(Format.plural(speakers, "speaker")) }
        return parts.joined(separator: " · ")
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                let fresh = try await API.session(id)
                detail = fresh
                error = nil
                await player.load(fresh)
            } catch {
                self.error = error.localizedDescription
            }
            if detail?.status == "ready" { return }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func scrollToStart(_ proxy: ScrollViewProxy) {
        guard let startAt, !scrolledToStart, let detail,
              let block = detail.blocks.last(where: { $0.start <= startAt + 0.5 }) else { return }
        scrolledToStart = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            proxy.scrollTo(block.id, anchor: .center)
            player.seek(to: block.start, play: false)
        }
    }

    private func rename(to newTitle: String) async {
        do {
            try await API.rename(id, to: newTitle)
            Library.shared.applyRename(id, title: newTitle)
            detail = try await API.session(id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        do {
            try await API.delete(id)
            Library.shared.remove(id)
            try? FileManager.default.removeItem(at: Uploader.sessionsDirectory.appending(path: id))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Paragraph

struct ParagraphView: View {
    let row: TranscriptView.Row
    let showOriginal: Bool
    let isCurrent: Bool
    let seek: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if row.newSection {
                Rectangle().fill(Color.jHairline).frame(height: 1).padding(.bottom, 22)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Button(action: seek) {
                    Text(Format.clock(row.block.start))
                        .font(.metaSmall)
                        .foregroundStyle(isCurrent ? Color.jText : Color.jText3)
                        .frame(width: 48, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play from \(Format.clock(row.block.start))")

                VStack(alignment: .leading, spacing: 2) {
                    if row.showSpeaker {
                        Text(Format.speaker(row.block.speaker))
                            .font(.speaker)
                            .foregroundStyle(Color.jText)
                    }
                    text
                        .font(.reading)
                        .lineSpacing(10)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, isCurrent ? 0 : 0)
            .overlay(alignment: .leading) {
                if isCurrent {
                    Rectangle().fill(Color.jText).frame(width: 1.5).offset(x: -10)
                }
            }
        }
    }

    private var text: Text {
        let block = row.block
        if block.backchannel == true {
            return Text(block.text).foregroundStyle(Color.jText4)
        }
        guard let clean = block.clean else {
            // Not cleaned up yet: show what was said, a step quieter.
            return Text(block.text).foregroundStyle(Color.jText2)
        }
        guard showOriginal else { return Text(clean).foregroundStyle(Color.jText) }

        var out = AttributedString()
        for piece in Fillers.diff(raw: block.text, clean: clean).pieces {
            var part = AttributedString(piece.text)
            if piece.removed {
                part.foregroundColor = Color.jText4
                part.strikethroughStyle = .single
            } else {
                part.foregroundColor = Color.jText
            }
            out += part
        }
        return Text(out)
    }
}

// MARK: - Player bar

/// Same place and height as the tab bar, so nothing jumps on push.
struct PlayerBar: View {
    let player: RecordingPlayer
    let hasAudio: Bool

    var body: some View {
        let scrubbing = player.scrubTime != nil

        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.ink950)
                    .frame(width: 48, height: 48)
                    .background(Color.ink50, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.availability != .ready)
            .opacity(player.availability == .ready ? 1 : 0.4)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            switch player.availability {
            case .ready:
                Waveform(player: player)

                // Both step aside while scrubbing: the bubble has the time.
                HStack(spacing: 8) {
                    Text(Format.clock(player.time))
                        .font(.metaSmall)
                        .foregroundStyle(Color.ink400)
                        .fixedSize()
                        .frame(minWidth: 36, alignment: .trailing)
                    Button(action: player.cycleRate) {
                        Text(rateLabel)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.ink50)
                            .frame(width: 38, height: 30)
                            .background(Color.ink800, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(rateLabel)
                }
                .opacity(scrubbing ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: scrubbing)
                .sensoryFeedback(.selection, trigger: player.rate)
            case .loading:
                Text(hasAudio ? "Loading audio" : "No audio yet")
                    .font(.metaSmall).foregroundStyle(Color.ink400)
                Spacer()
            case let .unavailable(reason):
                Text(reason).font(.metaSmall).foregroundStyle(Color.ink400)
                Spacer()
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .frame(height: 62)
        .chromePill()
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 34)
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [.init(color: .jBg.opacity(0), location: 0), .init(color: .jBg, location: 0.45)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 124)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var rateLabel: String {
        player.rate == 1.25 ? "1.25×" : player.rate.rounded() == player.rate ? "\(Int(player.rate))×" : "\(player.rate)×"
    }
}

/// Peaks across the recording. Drag anywhere in the pill's height: the
/// position and the transcript follow the finger, the audio moves on release.
struct Waveform: View {
    let player: RecordingPlayer

    private let barArea: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let levels = player.levels
            let bars = max(levels.count, RecordingPlayer.barCount)
            let step = geo.size.width / CGFloat(bars)
            let duration = max(player.duration, 0.001)
            let progress = min(1, player.shownTime / duration)
            let scrubbing = player.scrubTime != nil

            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 0) {
                    ForEach(0..<bars, id: \.self) { i in
                        let level = i < levels.count ? CGFloat(levels[i]) : 0.1
                        Capsule()
                            .fill(Double(i) / Double(bars) < progress ? Color.ink50 : Color.ink600)
                            .frame(width: max(1.5, step * 0.5), height: max(2, level * barArea))
                            .frame(width: step)
                    }
                }
                .scaleEffect(y: scrubbing ? 1.25 : 1)

                Capsule()
                    .fill(Color.ink50)
                    .frame(width: 2, height: scrubbing ? 44 : 34)
                    .offset(x: max(0, progress * geo.size.width - 1))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let fraction = min(1, max(0, value.location.x / geo.size.width))
                    player.scrub(to: fraction * player.duration)
                }
                .onEnded { _ in player.endScrub() }
            )
            .overlay(alignment: .topLeading) {
                if scrubbing {
                    bubble.position(x: bubbleX(progress: progress, in: geo), y: -28)
                }
            }
            .animation(.spring(duration: 0.25), value: scrubbing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(Format.clock(player.time))
        .accessibilityAdjustableAction { direction in
            player.seek(to: player.time + (direction == .increment ? 15 : -15), play: player.isPlaying)
        }
    }

    private var bubble: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(Format.clock(player.shownTime))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.ink50)
            Text("/ \(Format.clock(player.duration))")
                .font(.metaSmall)
                .foregroundStyle(Color.ink500)
        }
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(height: 38)
        .chromePill()
        .allowsHitTesting(false)
    }

    /// Over the finger. The pill's right side leaves room; only the very
    /// start of the wave needs holding back from the screen edge.
    private func bubbleX(progress: Double, in geo: GeometryProxy) -> CGFloat {
        let halfBubble: CGFloat = player.duration >= 3600 ? 85 : 66
        let x = progress * geo.size.width
        return max(x, 16 + halfBubble - geo.frame(in: .global).minX)
    }
}
