import SwiftUI

/// One recording: title jotto wrote (tap to rename), the transcript in its
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
    /// The tab the switch shows; `shown` is the one on the page, which
    /// changes once the old page has slid out.
    @State private var tab: Tab = AppConfig.shared.opensOriginal ? .original : .clean
    @State private var shown: Tab = AppConfig.shared.opensOriginal ? .original : .clean
    /// How far the page is pushed sideways while swiping between tabs.
    @State private var slide: CGFloat = 0
    /// The pages beside the shown one, moved up or down so the paragraph
    /// you're reading lines up with itself as they slide in.
    @State private var shifts: [Tab: CGFloat] = [:]
    /// A sideways swipe holds the page still: no scrolling until it lets go.
    @State private var swiping = false
    /// True while a finger is on the page; a swipe the system cancels never
    /// gets its end, so this is what lets the page scroll again.
    @GestureState private var touching = false
    /// Each page's rows and paragraphs, worked out once per change to the
    /// recording rather than on every frame of a slide.
    @State private var models: [Tab: PageModel] = [:]
    @State private var modelVersion = 0
    @State private var fillersGone = 0
    /// Bumped by Rename in the menu: scroll up to the title, then edit it.
    @State private var renameRequests = 0
    @State private var pageWidth: CGFloat = 400
    @State private var player = RecordingPlayer()
    @State private var scroll = ScrollPosition(edge: .top)
    /// The paragraph playing on each page, changed only when it moves on.
    @State private var playing = Playing()
    @State private var sharing = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool
    @State private var confirmDelete = false
    @State private var scrolledToStart = false
    @State private var pickingLanguages = false
    /// Where each paragraph starts and ends in the body, for scrolling to it.
    @State private var spans: [Tab: [Int: TranscriptBodyView.Span]] = [:]
    /// Where things are on screen, kept outside SwiftUI's state so that
    /// following the scroll doesn't redraw the page every frame.
    @State private var where_ = Whereabouts()
    /// The title has scrolled away and text runs under the view switch.
    @State private var pinned = false
    @State private var headHeight: CGFloat = 0
    @Namespace private var tabLine
    /// Bumped to start polling again after a redo.
    @State private var polls = 0

    private var isImported: Bool { LocalStore.shared.recordings[id]?.imported != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                if let detail {
                    // Meta and title scroll away; the view switch stays
                    // at the top, so more of the screen is the text.
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        head(detail)
                            .padding(.horizontal, 20)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headHeight = $0 }
                            .background { ScrollViewHook { where_.scrollView = $0 } }
                        Section {
                            pages(detail)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { where_.bodyTop = $0 }
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
            .scrollPosition($scroll)
            .scrollDisabled(swiping)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > headHeight - 1
            } action: { _, now in pinned = now }
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geo in
                where_.offset = geo.contentOffset.y
                where_.minOffset = -geo.contentInsets.top
                where_.maxOffset = max(where_.minOffset, geo.contentSize.height + geo.contentInsets.bottom - geo.containerSize.height)
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { where_.scrollTop = $0 }
            // Swipe sideways to move between the tabs: the page follows
            // the finger and slides over. Not from the left edge, which
            // goes back, and not past the first or last tab.
            .simultaneousGesture(DragGesture(minimumDistance: 14)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in swipeChanged(value) }
                .onEnded { value in swipeEnded(value) })
            .onChange(of: touching) { _, now in
                guard !now, swiping, tab == shown else { return }
                where_.swipeAxis = nil
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) { slide = 0 } completion: { shifts = [:] }
                swiping = false
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .sensoryFeedback(.selection, trigger: tab)
            .onChange(of: detail?.blocks.count) { _, _ in scrollToStart() }
            .onScrollPhaseChange { _, phase in
                where_.moving = phase != .idle
                // Scrolling by hand: playback leaves the page alone for a bit.
                if phase == .interacting { where_.followPausedUntil = .now.addingTimeInterval(4) }
            }
            .onChange(of: renameRequests) {
                // Rename from the menu with the title scrolled away: the
                // field isn't there to focus until it's back on screen.
                withAnimation(Self.editMotion) { scroll.scrollTo(edge: .top) }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    titleFocused = true
                }
            }
            .sensoryFeedback(.selection, trigger: playing) { _, _ in player.scrubTime != nil }
        }
        // Watches the player so this page doesn't have to: it redraws when
        // the paragraph playing changes, not on every tick or scrub step.
        .background {
            if let detail {
                PlayFollower(player: player, blocks: detail.blocks) { now, seeked in follow(now, seeked: seeked) }
            }
        }
        .background(Color.jBg)
        .overlay(alignment: .bottom) {
            if let detail {
                PlayerBar(player: player, hasAudio: !detail.segments.isEmpty)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                        where_.playerTop = $0 + PlayerBar.lead
                    }
            }
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

    /// The bar going away is gone before the other arrives: crossed over
    /// the same stretch, the dark Done pill showed through the round
    /// buttons as a grey smear.
    private static let barSwap = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.09)),
        removal: .opacity.animation(.easeIn(duration: 0.09))
    )

    /// One bar or the other in the same 52 points, so nothing reflows.
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
                .transition(Self.barSwap)
            } else {
                browsingBar
                    .transition(Self.barSwap)
            }
        }
        .frame(height: 52)
    }

    private var browsingBar: some View {
        HStack(spacing: 10) {
            CircleIconButton(glyph: .back, label: "Back") { dismiss() }
            Spacer()
            Menu {
                Button { renameRequests += 1 } label: { Label { Text("Rename") } icon: { Glyph.pen.image() } }
                if detail?.status == "ready", detail?.segments.contains(where: \.hasAudio) == true, !isImported, Cloud.isOn || AppConfig.shared.usesQwen {
                    // Your own key's service, or Qwen3-ASR, hears the language itself.
                    Button("Transcribe again", systemImage: "arrow.clockwise") {
                        Pipeline.shared.redo(id)
                        polls += 1
                    }
                } else if detail?.status == "ready", detail?.segments.contains(where: \.hasAudio) == true, !isImported {
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
            // The same circle as Back and More: the player's play button is
            // this screen's one inverted control.
            CircleIconButton(glyph: .sendFilled, label: "Send") { sharing = true }
                .disabled(detail == nil)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - Content

    /// Meta and title, scrolling with the text.
    private func head(_ detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(meta(detail))
                .font(.meta)
                .foregroundStyle(Color.jText3)
                .padding(.top, 12)
            placeLine(detail)

            titleField

            // The hint and the underline share one slot, so starting a
            // rename changes nothing below the title.
            ZStack(alignment: .topLeading) {
                if detail.titleByUser != true {
                    Button { titleFocused = true } label: {
                        HStack(spacing: 6) {
                            GlyphView(glyph: .pen, color: .jText3).frame(width: 14, height: 14)
                            Text(detail.title == nil ? "jotto names it once there is enough to go on" : "Title by jotto · tap to rename")
                        }
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { where_.header = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { where_.headerBottom = $0 }
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
            // Clear of the date and place above, which read as one block.
            .padding(.top, 14)
            .accessibilityHint(renaming ? "" : "Rename")
    }

    @ViewBuilder
    private func suggestions(_ detail: SessionDetail) -> some View {
        let suggestions = ([detail.titleByUser == true ? nil : detail.title] + (detail.titleSuggestions ?? []).map { $0 })
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("jotto suggests")
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

    // MARK: - Moving between tabs

    private func tabs(_ detail: SessionDetail) -> [Tab] {
        (detail.highlights ?? []).isEmpty ? [.clean, .original] : [.clean, .original, .highlights]
    }

    /// The pages sit side by side, a screen apart, and slide together:
    /// the next one comes in attached to the one going out. The switch
    /// above moves as the pages do. The next page arrives lined up on the
    /// paragraph you were reading, and stays there.
    private func go(to next: Tab, then: (() -> Void)? = nil) {
        guard let detail, next != shown else {
            tab = next
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { slide = 0 }
            swiping = false
            then?()
            return
        }
        let order = tabs(detail)
        let from = order.firstIndex(of: shown) ?? 0
        let to = order.firstIndex(of: next) ?? 0
        if shifts.isEmpty { shifts = alignments() }
        let lift = -(shifts[next] ?? 0)
        tab = next
        withAnimation(.spring(duration: 0.36, bounce: 0.04)) {
            slide = -CGFloat(to - from) * pageWidth
        } completion: {
            // The page that arrived becomes the shown one, where it already
            // is: its shift turns into scrolling, all in the same frame.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                shown = next
                slide = 0
                shifts = [:]
                swiping = false
                if lift != 0 { scroll.scrollTo(y: min(max(where_.offset + lift, where_.minOffset), where_.maxOffset + abs(lift))) }
            }
            then?()
        }
    }

    /// How far each neighbouring page must move so the paragraph at the
    /// top of the screen is in the same place on it. Formatted drops the
    /// "嗯"s and the fillers, so the same paragraph sits higher there.
    private func alignments() -> [Tab: CGFloat] {
        guard let here = spans[shown], !here.isEmpty else { return [:] }
        // The first paragraph still showing under the switch.
        let line = where_.headerBottom - where_.bodyTop
        guard line > 0 else { return [:] }
        let order = here.sorted { $0.value.top < $1.value.top }
        guard let anchor = order.first(where: { $0.value.bottom > line }) else { return [:] }
        var out: [Tab: CGFloat] = [:]
        for t in [Tab.clean, .original] where t != shown {
            guard let there = spans[t] else { continue }
            // A paragraph only Original has: use the next one both have.
            let match = order.drop { $0.key != anchor.key }.first { there[$0.key] != nil }
            guard let match, let span = there[match.key] else { continue }
            out[t] = match.value.top - span.top
        }
        return out
    }

    private func swipeChanged(_ value: DragGesture.Value) {
        guard let detail, value.startLocation.x > 32 else { return }
        let dx = value.translation.width, dy = value.translation.height
        // Decide once per swipe whether it's sideways or a scroll. Sideways
        // holds the page still until the finger lets go.
        if where_.swipeAxis == nil || hypot(dx, dy) < 20 {
            where_.swipeAxis = abs(dx) > abs(dy) * 1.5 ? .horizontal : .vertical
        }
        guard where_.swipeAxis == .horizontal, tab == shown else { return }
        if !swiping {
            swiping = true
            shifts = alignments()
            // The scroll already under way stops here: turning the scroll
            // off only keeps a new one from starting.
            if let pan = where_.scrollView?.panGestureRecognizer {
                pan.isEnabled = false
                pan.isEnabled = true
            }
        }
        let order = tabs(detail)
        let i = order.firstIndex(of: shown) ?? 0
        let n = dx < 0 ? i + 1 : i - 1
        if order.indices.contains(n) {
            slide = dx
        } else {
            // Nothing further that way: it gives a little and springs back.
            slide = dx * 0.18
        }
    }

    private func swipeEnded(_ value: DragGesture.Value) {
        defer { where_.swipeAxis = nil }
        guard where_.swipeAxis == .horizontal, let detail, tab == shown else { return }
        let dx = value.translation.width
        let flung = value.predictedEndTranslation.width
        let order = tabs(detail)
        let i = order.firstIndex(of: shown) ?? 0
        let next = dx < 0 ? i + 1 : i - 1
        if order.indices.contains(next), abs(dx) > pageWidth * 0.3 || (abs(flung) > pageWidth * 0.5 && flung.sign == dx.sign) {
            go(to: order[next])
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { slide = 0 } completion: { shifts = [:] }
            swiping = false
        }
    }

    private func viewSwitch(_ detail: SessionDetail) -> some View {
        // Original strikes out what the rules took; the model's rewording
        // isn't counted.
        let fillers = tab == .original ? fillersGone : 0
        let marked = detail.highlights?.count ?? 0
        return VStack(spacing: 0) {
            HStack(spacing: 20) {
                tabButton("Formatted", selected: tab == .clean) { go(to: .clean) }
                tabButton("Original", selected: tab == .original) { go(to: .original) }
                if marked > 0 {
                    tabButton("Highlights", count: marked, selected: tab == .highlights) { go(to: .highlights) }
                }
                Spacer(minLength: 8)
                if fillers > 0 {
                    // Only when it fits on one line beside the tabs.
                    ViewThatFits(in: .horizontal) {
                        Text("\(fillers) \(fillers == 1 ? "filler" : "fillers") gone").lineLimit(1)
                        Text("−\(fillers) \(fillers == 1 ? "filler" : "fillers")").lineLimit(1)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText3)
                }
            }
            // A hairline only once text runs under the switch; at rest the
            // sliding underline is enough.
            Rectangle().fill(Color.jHairline).frame(height: 1).opacity(pinned ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: pinned)
        }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: tab)
    }

    private func tabButton(_ label: String, count: Int? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            (Text(label) + Text(count.map { " \($0)" } ?? "").fontWeight(.medium))
                .font(.label)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? Color.jText : Color.jText3)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    // One underline that slides to the chosen tab.
                    if selected {
                        Capsule().fill(Color.jText).frame(height: 2.5)
                            .matchedGeometryEffect(id: "tabLine", in: tabLine)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func status(_ detail: SessionDetail) -> some View {
        let heard = detail.segments.filter { $0.status == "done" || $0.status == "failed" }.count
        let failed = detail.segments.filter { $0.status == "failed" }.count
        let tidying = detail.status == "ready" ? detail.tidying : nil
        let working = detail.status == "processing" || tidying != nil
        let note: String? = if let tidying {
            "Formatting · \(tidying.done) of \(tidying.total)"
        } else { switch detail.status {
        case "recording": "Still recording. Text arrives about a minute behind"
        case "processing":
            if let waiting = Pipeline.shared.waiting, heard < (detail.segmentCount ?? 1) {
                waiting
            } else if let total = detail.segmentCount, total > 0 {
                heard >= total ? "Cleaning up" : "Transcribing · \(heard) of \(total) parts"
            } else { "Transcribing" }
        default:
            if failed > 0 {
                "\(Format.plural(failed, "part")) couldn't be transcribed"
            } else if (detail.missingSegments ?? 0) > 0 {
                "\(Format.plural(detail.missingSegments ?? 0, "part")) never reached your iPhone, so there are gaps"
            } else { nil }
        } }
        if let note {
            HStack(spacing: 8) {
                if working { ProcessingRing(size: 12) }
                Text(note)
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText3)
                    .contentTransition(.numericText())
                if failed > 0, detail.status == "ready", tidying == nil {
                    Button("Try again") { Pipeline.shared.retryFailed(detail.id) }
                        .font(.metaSmall.weight(.semibold))
                        .foregroundStyle(Color.jText)
                        .buttonStyle(.plain)
                        .contentShape(.rect.inset(by: -10))
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
            .animation(.easeOut(duration: 0.2), value: note)
        }
    }

    /// One page's paragraphs, ready for the body.
    struct PageModel {
        let rows: [Row]
        let items: [TranscriptParagraph]
    }

    /// Works out both text pages from the recording. Runs when the recording
    /// changes (a poll, a rename, a highlight), not while sliding; the body
    /// is only told about it if a paragraph actually changed.
    private func rebuildModels(_ detail: SessionDetail) {
        var next: [Tab: PageModel] = [:]
        let highlights = detail.highlights ?? []
        for t in [Tab.clean, .original] {
            let original = t == .original
            let rows = rows(detail, original: original)
            // Each highlight is named on the first paragraph it covers.
            let starts = Dictionary(grouping: highlights) { h in rows.first { h.covers($0.block) }?.id ?? -1 }
            let marked = Set(rows.filter { r in highlights.contains { $0.covers(r.block) } }.map(\.id))
            let moves = Places.changes(rows.map(\.block), marks: detail.places ?? [])
            let items = rows.map { row in
                TranscriptParagraph(
                    id: row.id, start: row.block.start,
                    speaker: row.showSpeaker ? Format.speaker(row.block.speaker) : nil,
                    newSection: row.newSection, chips: starts[row.id] ?? [],
                    text: Self.text(row.block, marked: marked.contains(row.id), original: original),
                    place: moves[row.id]
                )
            }
            next[t] = PageModel(rows: rows, items: items)
        }
        let changed = [Tab.clean, .original].contains { models[$0]?.items != next[$0]?.items }
        guard changed || models.isEmpty else { return }
        models = next
        modelVersion += 1
        fillersGone = detail.blocks.reduce(0) { n, b in
            n + ((b.trimmed ?? b.clean).map { Self.fillers(raw: b.text, clean: $0).removedRuns } ?? 0)
        }
    }

    /// Every page is always there, side by side a screen apart; only the
    /// shown one sets the height. Nothing has to be built when a slide
    /// starts, which is what made it catch before moving.
    private func pages(_ detail: SessionDetail) -> some View {
        let order = tabs(detail)
        let here = order.firstIndex(of: shown) ?? 0
        return SlidingPages(slide: $slide, here: here, width: pageWidth) {
            ForEach(order, id: \.self) { t in
                pageIfNeeded(detail, t, order: order)
                    .padding(.horizontal, 20)
                    .offset(y: t == shown ? 0 : shifts[t] ?? 0)
                    .allowsHitTesting(t == shown)
                    .accessibilityHidden(t != shown)
            }
        }
    }

    /// Highlights only while it's the page, or the one coming or going.
    /// Off to the side it was still drawn again on every frame of a slide,
    /// a scroll or the title opening for a rename, wherever its text moved
    /// on the screen: a couple of dozen paragraphs each time, which made
    /// long recordings with highlights drag. The text pages draw once and
    /// stay drawn, so they stay.
    @ViewBuilder
    private func pageIfNeeded(_ detail: SessionDetail, _ t: Tab, order: [Tab]) -> some View {
        let distance = abs((order.firstIndex(of: t) ?? 0) - (order.firstIndex(of: shown) ?? 0))
        if t != .highlights || t == shown || t == tab || (swiping && distance == 1) {
            page(detail, t)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    @ViewBuilder
    private func page(_ detail: SessionDetail, _ t: Tab) -> some View {
        if detail.blocks.isEmpty {
            if detail.status == "ready" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing to write down")
                        .font(.rowTitle)
                        .foregroundStyle(Color.jText)
                    Text("jotto couldn't make out any words. If people spoke another language, change it in Settings → Language.")
                        .font(.summary)
                        .foregroundStyle(Color.jText2)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                PendingLines()
            }
        } else if t == .highlights {
            highlightList(detail)
        } else if let model = models[t] {
            let rows = model.rows
            VStack(alignment: .leading, spacing: 0) {
                TranscriptBody(
                    paragraphs: model.items, version: modelVersion, current: currentBlock(on: t),
                    play: { id in
                        reveal(id)
                        if let b = rows.first(where: { $0.id == id })?.block { player.seek(to: b.start) }
                    },
                    // Tapping the text moves the playhead; it only plays if it already was.
                    moveHere: { id in
                        reveal(id)
                        if let b = rows.first(where: { $0.id == id })?.block { player.seek(to: b.start, play: player.isPlaying) }
                    },
                    highlight: { first, last in highlight(from: first, to: last, in: rows) },
                    anchors: { found in
                        guard spans[t] != found else { return }
                        spans[t] = found
                        if t == shown, let id = where_.pending, found[id] != nil {
                            where_.pending = nil
                            reveal(id, animated: false)
                        }
                    }
                )
                // More is on its way: the next part's place, as lines.
                if t != .highlights, let from = Self.textComing(detail) {
                    PendingPart(start: from)
                        .padding(.top, 22)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: Self.textComing(detail))
        }
    }

    /// Where the text still to come starts, while some of it is in: the
    /// first part not yet heard, or the end of what's in while the watch
    /// is still recording or parts are still on their way. Nil once every
    /// part is heard (or given up), even while it's being cleaned up.
    static func textComing(_ detail: SessionDetail) -> Double? {
        guard detail.status != "ready" else { return nil }
        let parts = detail.segments.sorted { $0.index < $1.index }
        if let first = parts.first(where: { $0.status == "pending" }) { return first.offset }
        let end = parts.last.map { $0.offset + $0.duration } ?? 0
        if detail.status == "recording" { return end }
        if let total = detail.segmentCount, parts.count < total { return end }
        return nil
    }

    /// What the rules took out of each paragraph, worked out once: the
    /// page is built again whenever one paragraph is formatted, and a
    /// long recording has a couple of hundred to compare word by word.
    private static var fillerCache: [String: Fillers.Result] = [:]

    static func fillers(raw: String, clean: String) -> Fillers.Result {
        let key = raw + "\u{0}" + clean
        if let known = fillerCache[key] { return known }
        if fillerCache.count > 2000 { fillerCache = [:] }
        let result = Fillers.diff(raw: raw, clean: clean)
        fillerCache[key] = result
        return result
    }

    /// A paragraph's text as the body draws it: clean, or the original with
    /// what the rules took struck through, shaded where it's marked.
    static func text(_ block: TranscriptBlock, marked: Bool, original: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ string: String, _ color: Color, struck: Bool = false) {
            var attributes: [NSAttributedString.Key: Any] = [.font: TranscriptBodyView.font, .foregroundColor: UIColor(color)]
            if struck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if marked { attributes[.backgroundColor] = UIColor(Color.jMarker) }
            out.append(NSAttributedString(string: string, attributes: attributes))
        }
        if block.backchannel == true {
            add(block.text, .jText4)
        } else if let clean = block.clean {
            if original {
                for piece in Self.fillers(raw: block.text, clean: block.trimmed ?? clean).pieces {
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

    /// "Highlight" in the text's menu: the paragraphs selected become one section.
    private func highlight(from first: Int, to last: Int, in rows: [Row]) {
        guard let detail, let a = rows.first(where: { $0.id == first })?.block,
              let b = rows.first(where: { $0.id == last })?.block else { return }
        Pipeline.shared.markedSection(id, startedAt: detail.startedAt, start: a.start, end: max(a.end, b.end))
        Task {
            self.detail = try? await API.session(id)
            if let detail = self.detail { rebuildModels(detail) }
        }
    }

    /// Each highlight with what was said in it, in order. Tapping one
    /// shows it in place in Clean, ready to play from there.
    private func highlightList(_ detail: SessionDetail) -> some View {
        let highlights = detail.highlights ?? []
        let spoken = detail.blocks.filter { $0.backchannel != true }
        return VStack(alignment: .leading, spacing: 30) {
            ForEach(highlights) { h in
                highlightItem(h, said: spoken.filter(h.covers))
            }
        }
    }

    private func highlightItem(_ h: Highlight, said: [TranscriptBlock]) -> some View {
        let open = {
            player.seek(to: h.start, play: false)
            go(to: .clean) {
                guard let id = said.first?.id else { return }
                // Once Clean is the page and laid out.
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    reveal(id, force: true)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
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
                ForEach(said) { block in highlightLine(block) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // A tap rather than a button: a sideways swipe across it should
        // change tabs, not open it.
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityHint("Shows it in the transcript")
    }

    private func highlightLine(_ block: TranscriptBlock) -> some View {
        let speaker: Text = block.speaker == nil ? Text("") : Text(Format.speaker(block.speaker) + "  ").font(.speaker)
        let said: Text = Text(block.clean ?? block.text).font(.reading)
        return (speaker + said)
            .foregroundStyle(Color.jText)
            .lineSpacing(11)
            .multilineTextAlignment(.leading)
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

    private func rows(_ detail: SessionDetail, original: Bool) -> [Row] {
        let visible = detail.blocks.filter { original || $0.backchannel != true }
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

    /// The paragraph playing, among those the shown page has: Formatted
    /// leaves out the "嗯"s, so one of those never counts there.
    private var currentBlock: Int? { currentBlock(on: shown) }

    private func currentBlock(on t: Tab, in now: Playing? = nil) -> Int? {
        let now = now ?? playing
        return t == .original ? now.original : now.clean
    }

    /// From the player: the paragraph moved on, or the playhead was moved
    /// by hand (the wave, the line, the text).
    private func follow(_ now: Playing, seeked: Bool) {
        if now != playing { playing = now }
        guard shown != .highlights, let block = currentBlock(on: shown, in: now) else { return }
        if seeked {
            // Moved by hand: always show where it went.
            where_.followPausedUntil = .distantPast
            reveal(block, quick: player.scrubTime != nil)
        } else if player.isPlaying, player.scrubTime == nil, Date.now > where_.followPausedUntil {
            // Playing on: follow, unless the reader is scrolling about by hand.
            reveal(block)
        }
    }

    /// Positions read off the screen as it scrolls, all in screen points.
    final class Whereabouts {
        /// Top of the transcript body.
        var bodyTop: CGFloat = 0
        /// Top of the scroll view, under the top bar.
        var scrollTop: CGFloat = 0
        /// Bottom of the view switch (and status line), pinned or not.
        var headerBottom: CGFloat = 0
        /// Height of the view switch and status line.
        var header: CGFloat = 60
        /// Top of the player.
        var playerTop: CGFloat = 800
        var offset: CGFloat = 0
        var minOffset: CGFloat = 0
        var maxOffset: CGFloat = 0
        var swipeAxis: Axis?
        /// The page is being scrolled, or is still gliding.
        var moving = false
        weak var scrollView: UIScrollView?
        /// Playback doesn't scroll the page for a moment after a scroll by hand.
        var followPausedUntil = Date.distantPast
        /// A paragraph to show once its page has been laid out.
        var pending: Int?
        /// The last paragraph scrolled to, and when: a scrub asks again
        /// and again while the page is still on its way there.
        var revealed: (id: Int, at: Date)?
    }

    /// Scrolls so the whole paragraph is in view, between the pinned switch
    /// and the player; a long one starts just under the switch. One already
    /// all in view stays where it is, so reading along is a page turn now
    /// and then, not a page that moves under you.
    private func reveal(_ id: Int, quick: Bool = false, animated: Bool = true, force: Bool = false) {
        guard let span = spans[shown]?[id] else {
            where_.pending = id
            return
        }
        let top = where_.bodyTop + span.top
        let bottom = where_.bodyTop + span.bottom
        let upper = where_.headerBottom + 12
        let lower = where_.playerTop - 16
        if !force, top >= upper, bottom <= lower { return }
        if !force, let last = where_.revealed, last.id == id, Date.now.timeIntervalSince(last.at) < 0.6 { return }
        // Where its top lands once the switch is pinned: a little under it,
        // leaving the end of the paragraph before for context, unless that
        // would push this one's end under the player.
        let pinnedUpper = where_.scrollTop + where_.header + 12
        let room = lower - pinnedUpper
        let target = pinnedUpper + max(0, min(room * 0.12, room - (bottom - top)))
        let y = min(max(where_.offset + top - target, where_.minOffset), where_.maxOffset)
        guard abs(y - where_.offset) > 1 else { return }
        where_.revealed = (id, .now)
        if animated {
            withAnimation(.smooth(duration: quick ? 0.25 : 0.42)) { scroll.scrollTo(y: y) }
        } else {
            scroll.scrollTo(y: y)
        }
    }

    private func title(_ detail: SessionDetail) -> String {
        detail.title ?? Format.provisionalTitle(detail.startedAt)
    }

    /// Where it was said, under the date; opens the start in Maps.
    @ViewBuilder
    private func placeLine(_ detail: SessionDetail) -> some View {
        if let marks = detail.places, let start = marks.first(where: { $0.name != nil }),
           let label = Places.route(marks)?.end == nil ? Places.fullName(start) : Places.label(marks) {
            Button { Places.openInMaps(start) } label: {
                HStack(spacing: 5) {
                    GlyphView(glyph: .pin, color: .jText3).frame(width: 13, height: 13)
                    Text(label)
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                        .lineLimit(1)
                }
                .contentShape(.rect.inset(by: -6))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityLabel("Recorded at \(label)")
            .accessibilityHint("Opens in Maps")
        }
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
        var seen: Int?
        while !Task.isCancelled {
            // Only when something changed: rebuilding a long recording's
            // page every two seconds made scrolling and typing stutter.
            let stamp = API.sessionStamp(id)
            // A paragraph formatted while the page is moving under the
            // finger, or while the title is being typed, waits for it to
            // stop: laying a long transcript out again takes a moment.
            if detail != nil, stamp != seen, where_.moving || swiping || renaming {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            if stamp == nil || stamp != seen || detail == nil {
                seen = stamp
                do {
                    let fresh = try await API.session(id)
                    detail = fresh
                    rebuildModels(fresh)
                    error = nil
                    await player.load(fresh)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            // Done, unless the text is still being tidied.
            if detail?.status == "ready", detail?.tidying == nil { return }
            try? await Task.sleep(for: .seconds(detail?.tidying == nil ? 4 : 2))
        }
    }

    /// Opened from search: the moment found, in view, with the playhead on it.
    private func scrollToStart() {
        guard let startAt, !scrolledToStart, let detail,
              let block = detail.blocks.last(where: { $0.start <= startAt + 0.5 }) else { return }
        scrolledToStart = true
        reveal(block.id, animated: false, force: true)
        Task {
            // Once the audio is there to seek in.
            for _ in 0..<40 where player.availability == .loading { try? await Task.sleep(for: .milliseconds(100)) }
            player.seek(to: block.start, play: false)
        }
    }

    private func rename(to newTitle: String) async {
        do {
            try await API.rename(id, to: newTitle)
            Library.shared.applyRename(id, title: newTitle)
            let fresh = try await API.session(id)
            detail = fresh
            rebuildModels(fresh)
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
    /// Room above the pill, where the text fades out under it.
    static let lead: CGFloat = 28

    var body: some View {

        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.jBg)
                    .frame(width: 48, height: 48)
                    .background(Color.jText, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.availability != .ready)
            .opacity(player.availability == .ready ? 1 : 0.4)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            switch player.availability {
            case .ready:
                Waveform(player: player)

                HStack(spacing: 8) {
                    Text(Format.clock(player.time))
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                        .fixedSize()
                        .frame(minWidth: 36, alignment: .trailing)
                    Button(action: player.cycleRate) {
                        Text(rateLabel)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.jText)
                            .frame(width: 46, height: 36)
                            .background(Color.jSheetFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(rateLabel)
                }
                .sensoryFeedback(.selection, trigger: player.rate)
            case .loading:
                Text(hasAudio ? "Loading audio" : "No audio yet")
                    .font(.metaSmall).foregroundStyle(Color.jText3)
                Spacer()
            case let .unavailable(reason):
                Text(reason).font(.metaSmall).foregroundStyle(Color.jText3)
                Spacer()
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .frame(height: 62)
        .playerPill()
        .padding(.horizontal, 16)
        .padding(.top, Self.lead)
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
    /// While scrubbing with the finger held at an end: which way the track
    /// runs (−1, 0, 1), and where the finger is.
    @State private var edge = 0
    @State private var edgeRun: Task<Void, Never>?
    @State private var fingerX: CGFloat = 0

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
                        context.fill(Capsule().path(in: rect), with: .color(played ? .jText : .jWaveRest))
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
                    Circle().fill(Color.jText).frame(width: 8, height: 8)
                    Capsule().fill(Color.jText).frame(width: 2, height: scrubbing ? 40 : 32)
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
            // The line stays on the track: the finger can wander off either
            // end, but the line stops there, and held at an end the track
            // runs on under it.
            let x = min(max(value.location.x, 0), layout.width)
            fingerX = x
            if layout.scrolls {
                let inset: CGFloat = 20
                let wanted = value.location.x > layout.width - inset ? 1 : value.location.x < inset ? -1 : 0
                if wanted != edge {
                    edge = wanted
                    runAtEdge(layout)
                }
            }
            player.scrub(to: time(atX: x, layout: layout))
        }
    }

    /// Moves the track along while the finger is held at an end.
    private func runAtEdge(_ layout: Layout) {
        edgeRun?.cancel()
        guard edge != 0 else { return }
        edgeRun = Task {
            while !Task.isCancelled, edge != 0 {
                left = layout.clampLeft(layout.clampLeft(left) + Double(edge) * layout.window * 0.015)
                player.scrub(to: time(atX: fingerX, layout: layout))
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func ended(_ value: DragGesture.Value, layout: Layout) {
        switch drag {
        case .undecided:
            player.seek(to: time(atX: value.location.x, layout: layout), play: player.isPlaying)
            following = true
        case .scrub:
            edge = 0
            edgeRun?.cancel()
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

/// The part still to come under the text so far: its time in the gutter
/// and three lines where its paragraph will be, breathing like
/// `PendingLines`, so a transcript partway through doesn't read as whole.
struct PendingPart: View {
    let start: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    private static let widths: [CGFloat] = [1, 0.92, 0.56]
    private static let bar: CGFloat = 12
    /// One line of the body's text: its font and line spacing.
    private static let line = TranscriptBodyView.font.lineHeight + 11

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(Format.clock(start))
                .font(.metaSmall)
                .foregroundStyle(Color.jText4)
                .frame(width: TranscriptBodyView.gutter, alignment: .leading)
                .frame(height: TranscriptBodyView.font.lineHeight)
            VStack(alignment: .leading, spacing: Self.line - Self.bar) {
                ForEach(Array(Self.widths.enumerated()), id: \.offset) { _, width in
                    GeometryReader { geo in
                        Capsule().fill(Color.jFill).frame(width: geo.size.width * width)
                    }
                    .frame(height: Self.bar)
                }
            }
            .padding(.top, (TranscriptBodyView.font.lineHeight - Self.bar) / 2)
            .opacity(dim ? 0.45 : 1)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement()
        .accessibilityLabel("More text is on its way")
    }
}

/// The transcript's pages in a row, a screen apart, moved together by
/// `slide`. Sized by the page that's shown, so a longer neighbour adds no
/// space below. Only this redraws as a finger drags the pages, and the
/// slide is an offset, so nothing is laid out again while it moves.
private struct SlidingPages<Content: View>: View {
    @Binding var slide: CGFloat
    let here: Int
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        PagesLayout(here: here, width: width) { content }
            .offset(x: slide)
    }
}

private struct PagesLayout: Layout {
    let here: Int
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? width
        guard subviews.indices.contains(here) else { return CGSize(width: w, height: 0) }
        let h = subviews[here].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let x = bounds.minX + CGFloat(i - here) * width
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: bounds.width, height: size.height))
        }
    }
}

/// The paragraph playing on each page. Formatted leaves out the "嗯"s,
/// so one of those never counts there.
struct Playing: Equatable {
    var clean: Int?
    var original: Int?

    init() {}

    init(time: Double, blocks: [TranscriptBlock]) {
        guard time > 0 else { return }
        // A seek can land a hair before the paragraph it was aimed at.
        let t = time + 0.3
        original = blocks.last { $0.start <= t }?.id
        clean = blocks.last { $0.backchannel != true && $0.start <= t }?.id
    }
}

/// Reads the player on every tick and scrub step, so the transcript page
/// around it doesn't: it hears only when the paragraph changes, or when
/// the playhead is moved by hand.
private struct PlayFollower: View {
    let player: RecordingPlayer
    let blocks: [TranscriptBlock]
    let changed: (_ now: Playing, _ seeked: Bool) -> Void

    var body: some View {
        let now = Playing(time: player.shownTime, blocks: blocks)
        Color.clear
            .onChange(of: now, initial: true) { _, now in changed(now, false) }
            .onChange(of: player.seeks) { changed(now, true) }
            .accessibilityHidden(true)
    }
}

/// Hands over the UIScrollView a SwiftUI ScrollView is drawn with, for the
/// one thing SwiftUI can't do: stop a scroll the finger has already started.
private struct ScrollViewHook: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> Finder {
        let view = Finder()
        view.found = found
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Finder, context: Context) {}

    final class Finder: UIView {
        var found: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let v = view {
                if let scroll = v as? UIScrollView {
                    found?(scroll)
                    return
                }
                view = v.superview
            }
        }
    }
}
