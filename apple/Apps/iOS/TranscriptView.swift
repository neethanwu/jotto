import SwiftUI

/// One recording: title Jotto wrote (tap to rename), the transcript in its
/// Clean or Original form with marked stretches drawn in, a Highlights tab
/// when there are any, and a player at the bottom.
struct TranscriptView: View {
    enum Tab { case clean, original, highlights }

    let id: String
    /// Open scrolled to this moment (from search).
    var startAt: Double?
    /// Open with the title ready to edit (Rename from the Days menu).
    var startsRenaming = false

    @Environment(\.dismiss) private var dismiss
    @State private var detail: SessionDetail?
    @State private var error: String?
    @State private var tab: Tab = AppConfig.shared.opensOriginal ? .original : .clean
    /// A highlight was tapped in the Highlights tab: scroll here in Clean.
    @State private var jumpTarget: Int?
    @State private var player = RecordingPlayer()
    @State private var sharing = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool
    @State private var confirmDelete = false
    @State private var scrolledToStart = false
    @State private var pickingLanguages = false
    /// Bumped to start polling again after a redo.
    @State private var polls = 0

    private var isImported: Bool { LocalStore.shared.recordings[id]?.imported != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    if let detail {
                        // Meta and title scroll away; the view switch stays
                        // at the top, so more of the screen is the text.
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            head(detail)
                                .padding(.horizontal, 20)
                                .id(Self.headID)
                            Section {
                                paragraphs(detail)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 20)
                                    .padding(.bottom, 140)
                                    // While the title is being edited the transcript
                                    // steps back. A veil over it rather than changing
                                    // the rows themselves: touching the selectable
                                    // text's modifiers rebuilt it, and it slid into
                                    // place as the keyboard went.
                                    .overlay {
                                        Color.jBg
                                            .opacity(renaming ? 0.7 : 0)
                                            .allowsHitTesting(renaming)
                                            .accessibilityHidden(true)
                                    }
                            } header: {
                                pinnedHeader(detail)
                            }
                        }
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
                    guard tab != .highlights, player.isPlaying || scrubbing, let block, let detail else { return }
                    withAnimation(.easeInOut(duration: scrubbing ? 0.15 : 0.3)) {
                        proxy.scrollTo(groupID(of: block, in: detail), anchor: .center)
                    }
                }
                .onChange(of: jumpTarget) { _, target in
                    guard let target, let detail else { return }
                    Task {
                        // Let Clean lay out first.
                        try? await Task.sleep(for: .milliseconds(150))
                        withAnimation(.easeInOut(duration: 0.3)) {
                            // Clear of the pinned view switch.
                            proxy.scrollTo(groupID(of: target, in: detail), anchor: UnitPoint(x: 0.5, y: 0.2))
                        }
                        jumpTarget = nil
                    }
                }
                .onChange(of: titleFocused) { _, focused in
                    // Rename from the menu with the title scrolled away.
                    if focused { withAnimation(Self.editMotion) { proxy.scrollTo(Self.headID, anchor: .top) } }
                }
                .sensoryFeedback(.selection, trigger: currentBlock) { _, _ in player.scrubTime != nil }
            }
        }
        .background(Color.jBg)
        .overlay(alignment: .bottom) {
            if let detail { PlayerBar(player: player, hasAudio: !detail.segments.isEmpty) }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Only the title is ever typed into, and it sits above the
        // keyboard; letting the keyboard resize the page made the
        // transcript jump as it came and went.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .drawer(isPresented: $sharing) {
            if let detail { SendPanel(detail: detail, title: title(detail)) }
        }
        // The title is always the field; focusing it is what starts a rename.
        .onChange(of: titleFocused) { _, focused in
            if focused, !renaming { withAnimation(Self.editMotion) { renaming = true } }
        }
        .onChange(of: detail.map { title($0) } ?? "", initial: true) { _, current in
            if !renaming { draftTitle = current }
        }
        .onChange(of: detail == nil) { _, missing in
            if !missing, startsRenaming, !renaming { titleFocused = true }
        }
        .alert("Delete this recording?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text(DeleteCopy.message(detail.map { title($0) } ?? "This recording"))
        }
        .task(id: polls) { await poll() }
        .sheet(isPresented: $pickingLanguages) { LanguageView() }
        .onDisappear { player.stop() }
    }

    // MARK: - Top bar

    /// One curve for everything that changes when a rename starts or ends.
    static let editMotion = Animation.smooth(duration: 0.32)

    /// Both bars are always there and cross-fade, so nothing reflows.
    private var topBar: some View {
        ZStack {
            if renaming {
                HStack {
                    Button("Cancel") { finishRenaming(save: false) }
                        .font(.label)
                        .foregroundStyle(Color.jText2)
                    Spacer()
                    Button("Done") { finishRenaming(save: true) }
                        .buttonStyle(PrimaryPillStyle(height: 36))
                }
                .padding(.horizontal, 20)
                .transition(.opacity)
            } else {
                browsingBar
                    .transition(.opacity)
            }
        }
        .frame(height: 52)
    }

    private var browsingBar: some View {
        HStack(spacing: 10) {
            CircleIconButton(glyph: .back, label: "Back") { dismiss() }
            Spacer()
            Menu {
                Button("Rename", systemImage: "pencil") { titleFocused = true }
                if detail?.status == "ready", detail?.segments.contains(where: \.hasAudio) == true, !isImported {
                    // Pick the language right here; no trip to Settings.
                    Menu("Transcribe again", systemImage: "arrow.clockwise") {
                        ForEach(AppConfig.shared.languages, id: \.self) { language in
                            Button {
                                Pipeline.shared.redo(id, language: language)
                                polls += 1
                            } label: {
                                if detail?.language == language {
                                    Label(LanguageView.name(language), systemImage: "checkmark")
                                } else {
                                    Text(LanguageView.name(language))
                                }
                            }
                        }
                        if AppConfig.shared.languages.count > 1 {
                            Button {
                                Pipeline.shared.redo(id, language: LocalRecording.mixed)
                                polls += 1
                            } label: {
                                let title = "Mixed: " + AppConfig.shared.languages.map(LanguageView.shortName).joined(separator: " + ")
                                if detail?.language == LocalRecording.mixed {
                                    Label(title, systemImage: "checkmark")
                                } else {
                                    Text(title)
                                }
                            }
                        }
                        Divider()
                        Button("Other languages…") { pickingLanguages = true }
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                CircleGlyph(glyph: .more)
            }
            .accessibilityLabel("More")
            CircleIconButton(glyph: .sendFilled, label: "Send", fill: .jText, color: .jBg) { sharing = true }
                .disabled(detail == nil)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - Content

    private static let headID = "head"

    /// Meta and title, scrolling with the text.
    private func head(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(meta(detail))
                .font(.meta)
                .foregroundStyle(Color.jText3)
                .padding(.top, 12)

            titleField

            // The hint and the underline share one slot, so starting a
            // rename changes nothing below the title.
            ZStack(alignment: .topLeading) {
                if detail.titleByUser != true {
                    Button { titleFocused = true } label: {
                        Label(detail.title == nil ? "Jotto names it once there is enough to go on" : "Title by Jotto · tap to rename",
                              systemImage: "pencil")
                            .font(.metaSmall)
                            .foregroundStyle(Color.jText3)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                    .opacity(renaming ? 0 : 1)
                    .disabled(renaming)
                }
                Rectangle().fill(Color.jText).frame(height: 1.5)
                    .padding(.top, 8)
                    .opacity(renaming ? 1 : 0)
                    .accessibilityHidden(true)
            }

            if renaming {
                suggestions(detail)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 24)
    }

    /// The view switch and what's still happening, pinned while the text scrolls.
    private func pinnedHeader(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            viewSwitch(detail)
            status(detail)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.jBg)
        // While the title is being edited, the rest steps back.
        .opacity(renaming ? 0.3 : 1)
        .allowsHitTesting(!renaming)
    }

    /// The title is a field all the time, styled as the title, so tapping
    /// it puts the cursor in place without swapping views. Room for the
    /// clear button is kept even when it is hidden, so the text never
    /// rewraps.
    private var titleField: some View {
        TextField("Title", text: $draftTitle, axis: .vertical)
            .font(.transcriptTitle)
            .tracking(-0.68)
            .foregroundStyle(Color.jText)
            .tint(Color.jLive)
            .focused($titleFocused)
            .submitLabel(.done)
            // Wraps like a paragraph, but Return means Done.
            .onChange(of: draftTitle) { _, text in
                if text.contains("\n") {
                    draftTitle = text.replacingOccurrences(of: "\n", with: "")
                    finishRenaming(save: true)
                }
            }
            .padding(.trailing, 32)
            .overlay(alignment: .trailing) {
                if renaming, !draftTitle.isEmpty {
                    Button { draftTitle = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.jText4)
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear title")
                    .transition(.opacity)
                }
            }
            .padding(.top, 8)
            .accessibilityHint(renaming ? "" : "Rename")
    }

    @ViewBuilder
    private func suggestions(_ detail: SessionDetail) -> some View {
        let suggestions = ([detail.titleByUser == true ? nil : detail.title] + (detail.titleSuggestions ?? []).map { $0 })
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Jotto suggests")
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText3)
                    .padding(.top, 14)
                FlowLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        let on = s == draftTitle
                        Button { draftTitle = s } label: {
                            Text(s)
                                .font(.summary)
                                .foregroundStyle(on ? Color.jBg : Color.jText)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(on ? Color.jText : Color.jFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func finishRenaming(save: Bool) {
        let newTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if save, let detail, !newTitle.isEmpty, newTitle != title(detail) {
            Task { await rename(to: newTitle) }
        }
        if !save || newTitle.isEmpty, let detail { draftTitle = title(detail) }
        titleFocused = false
        withAnimation(Self.editMotion) { renaming = false }
    }

    private func viewSwitch(_ detail: SessionDetail) -> some View {
        // Original strikes out what the rules took; the model's rewording
        // isn't counted.
        let fillers = tab == .original ? detail.blocks.reduce(0) { n, b in
            n + ((b.trimmed ?? b.clean).map { Fillers.diff(raw: b.text, clean: $0).removedRuns } ?? 0)
        } : 0
        let marked = detail.highlights?.count ?? 0
        return VStack(spacing: 0) {
            HStack(spacing: 20) {
                tabButton("Clean", selected: tab == .clean) { tab = .clean }
                tabButton("Original", selected: tab == .original) { tab = .original }
                if marked > 0 {
                    tabButton("Highlights", count: marked, selected: tab == .highlights) { tab = .highlights }
                }
                Spacer(minLength: 8)
                if fillers > 0 {
                    Text("\(fillers) \(fillers == 1 ? "filler" : "fillers") gone")
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                }
            }
            Rectangle().fill(Color.jHairline).frame(height: 1)
        }
    }

    private func tabButton(_ label: String, count: Int? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            (Text(label) + Text(count.map { " \($0)" } ?? "").fontWeight(.medium))
                .font(.label)
                .lineLimit(1)
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
        let heard = detail.segments.filter { $0.status == "done" || $0.status == "failed" }.count
        let tidying = detail.status == "ready" ? detail.tidying : nil
        let working = detail.status == "processing" || tidying != nil
        let note: String? = if let tidying {
            "Tidying up · \(tidying.done) of \(tidying.total)"
        } else { switch detail.status {
        case "recording": "Still recording. Text arrives a couple of minutes behind"
        case "processing":
            if let waiting = Pipeline.shared.waiting, heard < (detail.segmentCount ?? 1) {
                waiting
            } else if let total = detail.segmentCount, total > 0 {
                heard >= total ? "Cleaning up" : "Transcribing · \(heard) of \(total) parts"
            } else { "Transcribing" }
        default:
            (detail.missingSegments ?? 0) > 0
                ? "\(Format.plural(detail.missingSegments ?? 0, "part")) never reached your iPhone, so there are gaps"
                : nil
        } }
        if let note {
            HStack(spacing: 8) {
                if working { ProcessingRing(size: 12) }
                Text(note)
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText3)
                    .contentTransition(.numericText())
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
            .animation(.easeOut(duration: 0.2), value: note)
        }
    }

    @ViewBuilder
    private func paragraphs(_ detail: SessionDetail) -> some View {
        if detail.blocks.isEmpty {
            if detail.status == "ready" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing to write down")
                        .font(.rowTitle)
                        .foregroundStyle(Color.jText)
                    Text("Jotto couldn't make out any words. If people spoke another language, change it in Settings → Language.")
                        .font(.summary)
                        .foregroundStyle(Color.jText2)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                PendingLines()
            }
        } else if tab == .highlights {
            highlightList(detail)
        } else {
            let rows = rows(detail)
            let highlights = detail.highlights ?? []
            // Each highlight is named on the first paragraph it covers.
            let starts = Dictionary(grouping: highlights) { h in rows.first { h.covers($0.block) }?.id ?? -1 }
            let marked = Set(rows.filter { r in highlights.contains { $0.covers(r.block) } }.map(\.id))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    ParagraphView(
                        row: row, starting: starts[row.id] ?? [], marked: marked.contains(row.id),
                        isLast: i == rows.count - 1,
                        showOriginal: showOriginal, isCurrent: currentBlock == row.block.id,
                        play: { player.seek(to: row.block.start) },
                        // Tapping the text moves the playhead; it only plays if it already was.
                        moveHere: { player.seek(to: row.block.start, play: player.isPlaying) },
                        highlight: { highlightParagraph(row.block) }
                    )
                    .id(row.id)
                }
            }
        }
    }

    /// "Highlight" in the text's menu: the paragraph becomes a section.
    private func highlightParagraph(_ block: TranscriptBlock) {
        guard let detail else { return }
        Pipeline.shared.markedSection(id, startedAt: detail.startedAt, start: block.start, end: block.end)
        Task { self.detail = try? await API.session(id) }
    }

    /// Each highlight with what was said in it, in order. Tapping one
    /// shows it in place in Clean, ready to play from there.
    private func highlightList(_ detail: SessionDetail) -> some View {
        let highlights = detail.highlights ?? []
        let spoken = detail.blocks.filter { $0.backchannel != true }
        return VStack(alignment: .leading, spacing: 30) {
            ForEach(highlights) { h in
                let said = spoken.filter(h.covers)
                Button {
                    tab = .clean
                    player.seek(to: h.start, play: false)
                    jumpTarget = said.first?.id
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            HighlightChip(highlight: h)
                            Text(h.isSection
                                 ? "Section · \(Format.length(h.end - h.start))"
                                 : "Moment · \(Format.clock(h.start)) – \(Format.clock(h.end))")
                                .font(.metaSmall)
                                .foregroundStyle(Color.jText3)
                        }
                        if said.isEmpty {
                            Text("Nothing was said here").font(.reading).foregroundStyle(Color.jText3)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(said) { block in
                                (Text(block.speaker == nil ? "" : Format.speaker(block.speaker) + "  ").font(.speaker)
                                    + Text(block.clean ?? block.text).font(.reading))
                                    .foregroundStyle(Color.jText)
                                    .lineSpacing(11)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows it in the transcript")
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

    /// The scroll target for a paragraph: itself.
    private func groupID(of block: Int, in detail: SessionDetail) -> Int { block }

    private var showOriginal: Bool { tab == .original }

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
        if let language = detail.language { parts.append(LanguageView.shortName(language)) }
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
            // Done, unless the text is still being tidied.
            if detail?.status == "ready", detail?.tidying == nil { return }
            try? await Task.sleep(for: .seconds(detail?.tidying == nil ? 4 : 2))
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
            try? FileManager.default.removeItem(at: AudioFiles.directory.appending(path: id))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Paragraph

struct ParagraphView: View {
    let row: TranscriptView.Row
    /// Highlights that start here: chips over the text.
    var starting: [Highlight] = []
    /// Inside a highlight: the text is shaded, like a highlighter.
    var marked = false
    /// The thread in the gutter stops at the last paragraph.
    var isLast = false
    let showOriginal: Bool
    let isCurrent: Bool
    let play: () -> Void
    let moveHere: () -> Void
    let highlight: () -> Void

    static let gutter: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if row.newSection {
                Rectangle().fill(Color.jHairline).frame(height: 1).padding(.bottom, 22)
            }
            HStack(alignment: .top, spacing: 0) {
                // The time in a gutter of its own, with a dashed thread down
                // to the next one, so every paragraph has its time and the
                // text keeps its column. The whole gutter plays from here.
                Button(action: play) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Format.clock(row.block.start))
                            .font(.metaSmall)
                            .fontWeight(isCurrent ? .semibold : .medium)
                            .foregroundStyle(isCurrent ? Color.jText : Color.jText3)
                            .frame(height: 28)
                        if !isLast {
                            DashedThread().frame(width: 1).frame(maxHeight: .infinity).padding(.leading, 12)
                        }
                    }
                    .frame(width: Self.gutter, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play from \(Format.clock(row.block.start))")

                VStack(alignment: .leading, spacing: 6) {
                    // With speakers (your own API key), who is talking.
                    if row.showSpeaker {
                        Text(Format.speaker(row.block.speaker))
                            .font(.speaker)
                            .foregroundStyle(Color.jText)
                            .frame(height: 22)
                    }
                    if !starting.isEmpty {
                        HStack(spacing: 6) { ForEach(starting) { HighlightChip(highlight: $0) } }
                            .padding(.top, 3)
                    }
                    TranscriptText(text: text, time: row.block.start, onTap: moveHere, onHighlight: highlight)
                        .padding(.top, row.showSpeaker || !starting.isEmpty ? 0 : 3)
                }
                .padding(.bottom, 22)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: NSAttributedString {
        let block = row.block
        let out = NSMutableAttributedString()
        func add(_ string: String, _ color: Color, struck: Bool = false) {
            var attributes = TranscriptText.base
            attributes[.foregroundColor] = UIColor(color)
            if struck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if marked { attributes[.backgroundColor] = UIColor(Color.jMarker) }
            out.append(NSAttributedString(string: string, attributes: attributes))
        }
        if block.backchannel == true {
            add(block.text, .jText4)
        } else if let clean = block.clean {
            if showOriginal {
                for piece in Fillers.diff(raw: block.text, clean: block.trimmed ?? clean).pieces {
                    add(piece.text, piece.removed ? .jText4 : .jText, struck: piece.removed)
                }
            } else {
                add(clean, .jText)
            }
        } else {
            // Not cleaned up yet: show what was said, a step quieter.
            add(block.text, .jText2)
        }
        return out
    }
}

/// The dashed line that links one paragraph's time to the next.
private struct DashedThread: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0.5, y: 0))
                p.addLine(to: CGPoint(x: 0.5, y: geo.size.height))
            }
            .stroke(Color.jText5, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .accessibilityHidden(true)
    }
}

/// A paragraph as UIKit text, so it can be selected word by word and its
/// menu can carry our own actions: Copy with time and Highlight, beside
/// the system's Copy, Look Up and Share. A tap (not a selection) moves the
/// playhead to the paragraph.
struct TranscriptText: UIViewRepresentable {
    let text: NSAttributedString
    let time: Double
    let onTap: () -> Void
    let onHighlight: () -> Void

    static var base: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 11
        return [
            .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17)),
            .paragraphStyle: style,
        ]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = true
        view.tintColor = UIColor(Color.jText)
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.attributedText != text { view.attributedText = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: TranscriptText
        init(_ parent: TranscriptText) { self.parent = parent }

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view as? UITextView, view.selectedRange.length == 0 else { return }
            parent.onTap()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let selected = (textView.text as NSString).substring(with: range)
            let time = Format.clock(parent.time)
            let copyWithTime = UIAction(title: "Copy with time", image: UIImage(systemName: "clock")) { _ in
                UIPasteboard.general.string = "[\(time)] \(selected)"
            }
            let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                self?.parent.onHighlight()
                textView.selectedRange = NSRange(location: 0, length: 0)
            }
            // After the system's Copy (first), before Look Up, Share and the rest.
            var children = suggestedActions
            children.insert(contentsOf: [copyWithTime, highlight], at: min(1, children.count))
            return UIMenu(children: children)
        }
    }
}

/// "★ 0:52" or "[ ] 0:14 – 0:40": a small inverted capsule at the end
/// of the time row where a highlight starts, and over each one in the
/// Highlights tab.
struct HighlightChip: View {
    let highlight: Highlight

    var body: some View {
        HStack(spacing: 5) {
            GlyphView(glyph: highlight.isSection ? .brackets : .star, color: .jBg)
                .frame(width: 11, height: 11)
            Text(highlight.isSection
                 ? "\(Format.clock(highlight.start)) – \(Format.clock(highlight.end))"
                 : Format.clock(highlight.at))
                .font(.scaled(12, .semibold, relativeTo: .caption1).monospacedDigit())
                .foregroundStyle(Color.jBg)
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(Color.jText, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(highlight.isSection
                            ? "Section from \(Format.clock(highlight.start)) to \(Format.clock(highlight.end))"
                            : "Moment at \(Format.clock(highlight.at))")
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
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.ink50)
                            .frame(width: 46, height: 36)
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

/// Peaks across the recording, with the play position as a line.
///
/// Short recordings fit the pill: drag anywhere to scrub, tap to jump.
/// Longer ones draw a bar every two seconds and scroll: drag the track
/// to look around, drag the line to scrub, tap a spot to jump there.
/// While playing, the track pages along to keep the line in view.
struct Waveform: View {
    let player: RecordingPlayer

    private static let barArea: CGFloat = 28
    /// Spacing between bars when the track scrolls.
    private static let step: CGFloat = 3.6
    /// How close to the line a touch counts as grabbing it.
    private static let grab: CGFloat = 22

    /// Seconds at the left edge, when the track scrolls.
    @State private var left: Double = 0
    @State private var following = true
    @State private var drag: DragKind?
    @State private var refollow: Task<Void, Never>?

    private enum DragKind {
        case undecided(left: Double)
        case scrub
        case scroll(left: Double)
    }

    private struct Layout {
        let width: CGFloat
        let count: Int
        let duration: Double
        var secondsPerBar: Double { duration / Double(count) }
        var scrolls: Bool { CGFloat(count) * Waveform.step > width }
        var step: CGFloat { scrolls ? Waveform.step : width / CGFloat(count) }
        /// Points per second.
        var scale: Double { Double(step) / secondsPerBar }
        var window: Double { Double(width) / scale }
        func clampLeft(_ value: Double) -> Double { scrolls ? min(max(0, value), duration - window) : 0 }
    }

    var body: some View {
        GeometryReader { geo in
            let duration = max(player.duration, 0.001)
            let count = max(player.levels.count, RecordingPlayer.bars(for: duration))
            let layout = Layout(width: geo.size.width, count: count, duration: duration)
            let shown = min(player.shownTime, duration)
            let scrubbing = player.scrubTime != nil
            let left = layout.clampLeft(self.left)
            let headX = CGFloat((shown - left) * layout.scale)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let levels = player.levels
                    let first = max(0, Int(left / layout.secondsPerBar) - 1)
                    let last = min(count - 1, Int((left + layout.window) / layout.secondsPerBar) + 1)
                    guard first <= last else { return }
                    let barWidth = max(1.5, layout.step * 0.5)
                    for i in first...last {
                        let level = i < levels.count ? CGFloat(levels[i]) : 0.1
                        let height = max(2, level * Self.barArea)
                        let x = CGFloat((Double(i) * layout.secondsPerBar - left) * layout.scale) + (layout.step - barWidth) / 2
                        let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                        let played = Double(i) * layout.secondsPerBar < shown
                        context.fill(Capsule().path(in: rect), with: .color(played ? .ink50 : .ink600))
                    }
                }
                .scaleEffect(y: scrubbing ? 1.25 : 1)
                .mask {
                    // Bars fade at the edges when there is more to scroll to.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(layout.scrolls && left > 0 ? 0 : 1), location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94),
                        .init(color: .black.opacity(layout.scrolls && left < duration - layout.window ? 0 : 1), location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                }

                // The line, with a knob that says it can be dragged.
                VStack(spacing: 0) {
                    Circle().fill(Color.ink50).frame(width: 8, height: 8)
                    Capsule().fill(Color.ink50).frame(width: 2, height: scrubbing ? 40 : 32)
                }
                .offset(x: headX - 4, y: scrubbing ? 3 : 7)
                .opacity(headX < -2 || headX > geo.size.width + 2 ? 0 : 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in changed(value, layout: layout, headX: headX) }
                .onEnded { value in ended(value, layout: layout) }
            )
            .overlay(alignment: .topLeading) {
                if scrubbing {
                    bubble.position(x: bubbleX(headX, in: geo), y: -28)
                }
            }
            .animation(.spring(duration: 0.25), value: scrubbing)
            .onChange(of: player.time) { _, time in follow(time, layout: layout) }
            .onAppear { self.left = layout.clampLeft(player.time - layout.window * 0.15) }
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

    // MARK: Gestures

    private func time(atX x: CGFloat, layout: Layout) -> Double {
        min(max(0, layout.clampLeft(left) + Double(x) / layout.scale), layout.duration)
    }

    private func changed(_ value: DragGesture.Value, layout: Layout, headX: CGFloat) {
        switch drag {
        case nil:
            refollow?.cancel()
            if !layout.scrolls || abs(value.startLocation.x - headX) < Self.grab {
                drag = .scrub
                player.scrub(to: time(atX: value.location.x, layout: layout))
            } else {
                drag = .undecided(left: layout.clampLeft(left))
            }
        case let .undecided(start):
            // A tap until it moves; then it scrolls the track.
            if abs(value.translation.width) > 6 {
                following = false
                drag = .scroll(left: start)
            }
        case let .scroll(start):
            left = layout.clampLeft(start - Double(value.translation.width) / layout.scale)
        case .scrub:
            // Near an edge, the track moves along with the finger.
            if layout.scrolls {
                let edge: CGFloat = 16
                if value.location.x > layout.width - edge { left = layout.clampLeft(left + layout.window * 0.02) }
                if value.location.x < edge { left = layout.clampLeft(left - layout.window * 0.02) }
            }
            player.scrub(to: time(atX: value.location.x, layout: layout))
        }
    }

    private func ended(_ value: DragGesture.Value, layout: Layout) {
        switch drag {
        case .undecided:
            player.seek(to: time(atX: value.location.x, layout: layout), play: player.isPlaying)
            following = true
        case .scrub:
            player.endScrub()
            following = true
        case .scroll:
            // Back to following the line a moment after looking around.
            refollow = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                following = true
                follow(player.time, layout: layout, force: true)
            }
        case nil:
            break
        }
        left = layout.clampLeft(left)
        drag = nil
    }

    /// Pages the track so the line stays between 15% and 85% of the width.
    private func follow(_ time: Double, layout: Layout, force: Bool = false) {
        guard layout.scrolls, following, player.scrubTime == nil else { return }
        let x = (time - layout.clampLeft(left)) * layout.scale
        if force || x < 0 || x > Double(layout.width) * 0.85 {
            withAnimation(.easeInOut(duration: 0.35)) { left = layout.clampLeft(time - layout.window * 0.15) }
        }
    }

    // MARK: Bubble

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

    /// Over the line. The pill's right side leaves room; only the very
    /// start of the wave needs holding back from the screen edge.
    private func bubbleX(_ x: CGFloat, in geo: GeometryProxy) -> CGFloat {
        let halfBubble: CGFloat = player.duration >= 3600 ? 85 : 66
        return max(x, 16 + halfBubble - geo.frame(in: .global).minX)
    }
}

/// Where the text will be, while it is being written: a few faint
/// lines that breathe. Still with Reduce Motion.
struct PendingLines: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    private static let widths: [CGFloat] = [1, 0.92, 0.97, 0.6, 0, 1, 0.85, 0.4]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, width in
                if width == 0 {
                    Color.clear.frame(height: 8)
                } else {
                    GeometryReader { geo in
                        Capsule().fill(Color.jFill).frame(width: geo.size.width * width)
                    }
                    .frame(height: 12)
                }
            }
        }
        .opacity(dim ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement()
        .accessibilityLabel("The text is on its way")
    }
}
