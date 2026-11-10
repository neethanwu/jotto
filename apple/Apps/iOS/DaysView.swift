import SwiftUI

/// Home: one day at a time. Wordmark and Search, the day's
/// name (tap for a month calendar), a week strip to move between days,
/// and the day's recordings on a timeline.
struct DaysView: View {
    let router: Router
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var scroll = ScrollPosition(edge: .top)
    /// The week strip has reached the top and is pinned there.
    @State private var stripPinned = false
    @State private var picking = false
    /// The row swiped open, if any; one at a time.
    @State private var swiped: String?
    @State private var sharing: SessionDetail?
    @State private var renaming: SessionDetail?
    @State private var deleting: TimelineEntry?
    @State private var actionError: String?
    private var library: Library { .shared }
    private var config: AppConfig { .shared }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                BrandBar {
                    HStack(spacing: 8) {
                        if !isToday {
                            Button("Today", action: goToToday)
                                .buttonStyle(BarPillStyle())
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                        CircleIconButton(glyph: .search, label: "Search") { router.days.append(.search) }
                    }
                }
                // Wordmark on the title's edge; buttons on the same 16 as every top bar.
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .animation(.easeOut(duration: 0.2), value: isToday)

                header
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                Section {
                    content
                        .padding(.top, 28)
                } header: {
                    // Stays at the top while the day scrolls under it.
                    WeekStrip(selection: $day, marked: library.daysWithRecordings, liveDay: liveDay, earliest: library.earliest)
                        .padding(.vertical, 8)
                        .background(Color.jBg)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.jHairline).frame(height: 1)
                                .opacity(stripPinned ? 1 : 0)
                        }
                        .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY <= 0.5 } action: { stripPinned = $0 }
                        .animation(.easeOut(duration: 0.15), value: stripPinned)
                }
            }
            .padding(.bottom, 140)
        }
        .scrollPosition($scroll)
        .onScrollPhaseChange { _, phase in
            if phase == .interacting, swiped != nil { withAnimation(.spring(duration: 0.3)) { swiped = nil } }
        }
        .scrollIndicators(.hidden)
        .statusBarCover()
        .background(Color.jBg)
        .onChange(of: router.daysReselected) { goToToday() }
        .sheet(item: $sharing) { detail in
            ShareSheet(detail: detail, title: detail.title ?? Format.provisionalTitle(detail.startedAt))
        }
        .sheet(item: $renaming) { detail in
            RenameSheet(detail: detail, current: detail.title ?? Format.provisionalTitle(detail.startedAt)) { title in
                Task { await rename(detail.id, to: title) }
            }
        }
        .confirmationDialog("Delete this recording?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { entry in
            Button("Delete recording and audio", role: .destructive) { Task { await delete(entry.id) } }
        } message: { _ in
            Text(config.processesLocally ? "The text and audio are removed from your iPhone" : "The text and audio are removed from your iPhone and the server")
        }
        .alert("Couldn't do that", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {} message: { Text(actionError ?? "") }
        .sheet(isPresented: $picking) {
            DayPicker(selection: $day, marked: library.daysWithRecordings, earliest: library.earliest)
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await library.refresh() }
        .task {
            // Fast while anything is recording or processing, slow otherwise.
            while !Task.isCancelled {
                await library.refresh()
                try? await Task.sleep(for: .seconds(library.isBusy ? 5 : 30))
            }
        }
    }

    private var entries: [TimelineEntry] { library.entries(on: day) }

    // MARK: - Row actions

    private func share(_ id: String) async {
        do { sharing = try await API.session(id) } catch { actionError = error.localizedDescription }
    }

    private func startRename(_ id: String) async {
        do { renaming = try await API.session(id) } catch { actionError = error.localizedDescription }
    }

    private func rename(_ id: String, to title: String) async {
        do {
            try await API.rename(id, to: title)
            library.applyRename(id, title: title)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func delete(_ id: String) async {
        do {
            try await API.delete(id)
            withAnimation(.spring(duration: 0.35)) { library.remove(id) }
            try? FileManager.default.removeItem(at: Uploader.sessionsDirectory.appending(path: id))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    /// Back to today and the top, from the Today button or tapping Days again.
    private func goToToday() {
        withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
            day = Calendar.current.startOfDay(for: .now)
            scroll.scrollTo(edge: .top)
        }
    }

    private var liveDay: Date? {
        library.liveEntry.map { Calendar.current.startOfDay(for: $0.startedAt) }
    }

    /// The day's name; tapping it opens the month calendar.
    private var header: some View {
        Button { picking = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.wide)))
                        .dayTitleStyle()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    GlyphView(glyph: .down, color: .jText4)
                        .frame(width: 18, height: 18)
                        .padding(.top, 6)
                }
                Text(meta)
                    .font(.meta)
                    .foregroundStyle(Color.jText3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Pick another day")
    }

    private var meta: String {
        var parts = [Format.dayMonth(day)]
        if entries.isEmpty, Calendar.current.isDateInToday(day) {
            parts.append("nothing yet")
        } else if !entries.isEmpty {
            parts.append(Format.plural(entries.count, "recording"))
            let total = entries.compactMap(\.length).reduce(0, +)
            if total > 0 { parts.append(Format.length(total)) }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if !config.isReady && !config.processesLocally {
            EmptyDay(
                title: "Connect to a server",
                detail: "Add the server address and token in Settings, then record on your watch"
            ) {
                Button("Open Settings") { router.tab = .settings; router.settings = [.processing] }
                    .buttonStyle(PrimaryPillStyle())
            }
        } else if entries.isEmpty {
            if Calendar.current.isDateInToday(day) {
                EmptyDay(title: "Tap the dot when it matters", detail: "Recordings from your watch land here, cleaned up, a minute after each part.")
            } else if day > .now {
                EmptyDay(title: "Not yet", detail: nil)
            } else {
                EmptyDay(title: "No recordings", detail: library.loadError)
            }
        } else {
            Timeline(entries: entries, swiped: $swiped, actions: .init(
                share: { entry in Task { await share(entry.id) } },
                rename: { entry in Task { await startRename(entry.id) } },
                delete: { entry in deleting = entry }
            )) { entry in
                if entry.state == .live {
                    router.live = Router.Live(id: entry.id)
                } else {
                    router.days.append(.transcript(id: entry.id))
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 20)
            if let error = library.loadError {
                Text(error).font(.summary).foregroundStyle(Color.jText3).padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - Week strip

/// Seven days per page, paging by week. Cells 50×64; neighbouring weeks
/// peek in at both edges so it reads as scrollable.
struct WeekStrip: View {
    @Binding var selection: Date
    let marked: Set<Date>
    let liveDay: Date?
    /// The first recording, so the strip reaches back at least that far.
    let earliest: Date?
    @State private var week: Date?
    @State private var weeks: [Week] = []
    @Namespace private var highlight

    private static let cell = CGSize(width: 50, height: 64)

    /// One cell's fixed text, worked out once rather than on every render.
    struct Day: Hashable {
        let date: Date
        let letter: String
        let number: String
        let label: String
    }

    struct Week: Identifiable, Hashable {
        let id: Date
        let days: [Day]
    }

    /// From 26 weeks back (or the first recording, if older) to this week.
    /// Nothing after this week: future days can't hold recordings.
    private static func makeWeeks(earliest: Date?) -> [Week] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let back = earliest.flatMap {
            calendar.dateComponents([.weekOfYear], from: $0, to: thisWeek).weekOfYear.map { $0 + 1 }
        } ?? 0
        return (-max(26, back)...0).compactMap { offset -> Week? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: offset, to: thisWeek) else { return nil }
            let days = (0..<7).compactMap { i -> Day? in
                guard let date = calendar.date(byAdding: .day, value: i, to: start) else { return nil }
                return Day(
                    date: date,
                    letter: date.formatted(.dateTime.weekday(.narrow)),
                    number: date.formatted(.dateTime.day()),
                    label: date.formatted(date: .complete, time: .omitted)
                )
            }
            return Week(id: start, days: days)
        }
    }

    var body: some View {
        let now = Date.now
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(weeks) { week in
                    HStack(spacing: 0) {
                        ForEach(week.days, id: \.date) { day in
                            cell(day, now: now)
                        }
                    }
                    .id(week.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, sideMargin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $week, anchor: .center)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(height: Self.cell.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            sideMargin = max(0, (width - Self.cell.width * 7) / 2)
        }
        .onAppear {
            // Rebuild after a week boundary, or if the app sat in the background for days.
            if weeks.last?.id != weekStart(.now) || weeks.isEmpty {
                weeks = Self.makeWeeks(earliest: earliest)
            }
            week = weekStart(selection)
        }
        .onChange(of: earliest.map(weekStart)) { _, _ in
            let older = earliest.map { weekStart($0) < (weeks.first?.id ?? .distantFuture) } ?? false
            if older { weeks = Self.makeWeeks(earliest: earliest) }
        }
        .onChange(of: selection) { _, day in
            let start = weekStart(day)
            if week != start { withAnimation(.smooth(duration: 0.35)) { week = start } }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    @State private var sideMargin: CGFloat = 0

    private func weekStart(_ day: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: day)?.start ?? day
    }

    private func cell(_ day: Day, now: Date) -> some View {
        let selected = Calendar.current.isDate(day.date, inSameDayAs: selection)
        let hasRecordings = marked.contains(day.date)
        let future = day.date > now
        let live = liveDay == day.date
        let dayColor: Color = selected ? .jBg : hasRecordings ? .jText : future ? .jText5 : .jText4

        return VStack(spacing: 4) {
            Text(day.letter)
                .font(.weekday)
                .foregroundStyle(selected ? Color.jBg.opacity(0.6) : future ? Color.jText5 : Color.jText4)
            Text(day.number)
                .font(.system(size: 16, weight: selected ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(dayColor)
            Circle()
                .fill(live ? Color.jLive : selected ? Color.jBg : Color.jText)
                .frame(width: 4, height: 4)
                .opacity(hasRecordings || live ? 1 : 0)
        }
        .frame(width: Self.cell.width, height: Self.cell.height)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.jText)
                    .matchedGeometryEffect(id: "selected", in: highlight)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Future days hold nothing yet, so they can't be picked.
            guard !future else { return }
            withAnimation(.spring(duration: 0.32, bounce: 0.15)) { selection = day.date }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.label)
        .accessibilityValue(hasRecordings ? "Has recordings" : future ? "Upcoming" : "")
        .accessibilityAddTraits(future ? [] : selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if !future { selection = day.date } }
    }
}

// MARK: - Timeline

struct Timeline: View {
    struct Actions {
        let share: (TimelineEntry) -> Void
        let rename: (TimelineEntry) -> Void
        let delete: (TimelineEntry) -> Void
    }

    let entries: [TimelineEntry]
    @Binding var swiped: String?
    let actions: Actions
    let open: (TimelineEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                let finished = entry.state == .done
                SwipeRow(id: entry.id, swiped: $swiped, enabled: finished,
                         share: { actions.share(entry) }, delete: { actions.delete(entry) }) {
                    Button {
                        // A tap on an open row just closes it.
                        if swiped != nil {
                            withAnimation(.spring(duration: 0.3)) { swiped = nil }
                        } else {
                            open(entry)
                        }
                    } label: {
                        TimelineRow(entry: entry, isLast: i == entries.count - 1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if finished {
                            Button("Share", systemImage: "square.and.arrow.up") { actions.share(entry) }
                            Button("Rename", systemImage: "pencil") { actions.rename(entry) }
                            Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(entry) }
                        }
                    }
                }
                .accessibilityAction(named: "Share") { if finished { actions.share(entry) } }
                .accessibilityAction(named: "Delete") { if finished { actions.delete(entry) } }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: entries)
    }
}

/// Swipe a row left to show Share and Delete behind it. The whole row
/// slides, like a system list. Only horizontal drags count, so the page
/// still scrolls.
struct SwipeRow<Content: View>: View {
    let id: String
    @Binding var swiped: String?
    let enabled: Bool
    let share: () -> Void
    let delete: () -> Void
    @ViewBuilder let content: Content

    @State private var drag: CGFloat = 0
    private static var reveal: CGFloat { 116 }

    private var offset: CGFloat {
        let base: CGFloat = swiped == id ? -Self.reveal : 0
        let raw = base + drag
        // Resists past the actions, and never opens to the right.
        if raw < -Self.reveal { return -Self.reveal + (raw + Self.reveal) * 0.3 }
        return min(0, raw)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content.offset(x: offset)
            // Only there while the row is moved, so hidden ones can't be hit.
            if enabled, offset < 0 {
                HStack(spacing: 12) {
                    action("Share", glyph: .share, fill: .jText, ink: .jBg, run: share)
                    action("Delete", glyph: .trash, fill: .jDestructive, ink: .white, run: delete)
                }
                .padding(.trailing, 4)
                // Centred on the title line, so it fits rows without a summary.
                .offset(y: -9)
                .opacity(min(1, Double(-offset / Self.reveal) * 1.4))
            }
        }
        .gesture(HorizontalPan(
            enabled: enabled,
            changed: { dx in
                if swiped != nil, swiped != id { withAnimation(.spring(duration: 0.3)) { swiped = nil } }
                drag = dx
            },
            ended: { dx, velocity in
                let final = (swiped == id ? -Self.reveal : 0) + dx
                let open = final < -Self.reveal / 2 || velocity < -600
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    swiped = open ? id : (swiped == id ? nil : swiped)
                    drag = 0
                }
            }
        ))
        .sensoryFeedback(.selection, trigger: swiped == id)
    }

    private func action(_ label: String, glyph: Glyph, fill: Color, ink: Color, run: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { swiped = nil }
            run()
        } label: {
            GlyphView(glyph: glyph, color: ink)
                .frame(width: 18, height: 18)
                .frame(width: 44, height: 44)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A pan that only starts when the finger moves sideways, so it never
/// takes a vertical scroll from the page.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var enabled = true
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = enabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let dx = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed: changed(dx)
        case .ended, .cancelled, .failed: ended(dx, pan.velocity(in: pan.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.2
        }
    }
}

/// Three columns: time (48), spine with the state dot (24), content.
struct TimelineRow: View {
    let entry: TimelineEntry
    let isLast: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !typeSize.isAccessibilitySize {
                Text(Format.time(entry.startedAt))
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText3)
                    .frame(width: 48, alignment: .leading)
                    .padding(.top, 3)
            }
            spine
            VStack(alignment: .leading, spacing: 6) {
                if typeSize.isAccessibilitySize {
                    Text(Format.time(entry.startedAt)).font(.metaSmall).foregroundStyle(Color.jText3)
                }
                titleLine
                detail
            }
            .padding(.leading, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var spine: some View {
        VStack(spacing: 0) {
            StateDot(state: entry.state)
                .padding(.top, 4)
                .animation(.easeInOut(duration: 0.25), value: entry.state)
            if !isLast {
                Rectangle()
                    .fill(Color.jSpine)
                    .frame(width: 1)
                    .padding(.top, 8)
            }
        }
        .frame(width: 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.title)
                .font(.rowTitle)
                .foregroundStyle(Color.jText)
                .lineLimit(2)
            Spacer(minLength: 8)
            if entry.state == .live {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(context.date.timeIntervalSince(entry.startedAt)))
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.jText3)
            } else if let length = entry.length {
                HStack(spacing: 4) {
                    if entry.highlights > 0 {
                        GlyphView(glyph: .star).frame(width: 11, height: 11)
                        Text("\(entry.highlights)").foregroundStyle(Color.jText)
                        Text("·").foregroundStyle(Color.jText3)
                    }
                    Text(Format.length(length)).foregroundStyle(Color.jText3)
                }
                .font(.metaSmall)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch entry.state {
        case .live:
            liveCard
        case let .processing(done, total, polishing):
            Text(processingText(done: done, total: total, polishing: polishing))
                .font(.metaSmall)
                .foregroundStyle(Color.jText3)
        case let .onWatch(parts):
            Text("On your watch · \(Format.plural(parts, "part")) to send")
                .font(.metaSmall)
                .foregroundStyle(Color.jText3)
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                if let summary = entry.summary {
                    Text(summary)
                        .font(.summary)
                        .foregroundStyle(Color.jText2)
                        .lineLimit(3)
                        .lineSpacing(3)
                }
                if entry.missing > 0 {
                    Text("\(Format.plural(entry.missing, "part")) never arrived")
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                }
            }
        }
    }

    private var liveCard: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let blink = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            (Text(entry.lastLine ?? "Listening") .foregroundStyle(entry.lastLine == nil ? Color.jText3 : Color.jText)
                + Text(" ▍").foregroundStyle(Color.jLive.opacity(blink ? 1 : 0)))
                .font(.summary)
                .lineSpacing(3)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.jSurface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func processingText(done: Int, total: Int?, polishing: Bool) -> String {
        guard let total, total > 0 else { return "Transcribing" }
        return polishing ? "Cleaning up" : "Transcribing · \(min(done, total)) of \(total) parts"
    }

    private var accessibilityText: String {
        var parts = [entry.title, Format.time(entry.startedAt)]
        if let length = entry.length { parts.append(Format.length(length)) }
        switch entry.state {
        case .live: parts.append("Recording")
        case .processing: parts.append("Processing")
        case .onWatch: parts.append("On your watch")
        case .done: parts.append("Done")
        }
        return parts.joined(separator: ", ")
    }
}

/// The timeline mark: live (orange with halo), waiting (dashed ring),
/// done (solid ring). The same marks appear on the watch.
struct StateDot: View {
    let state: TimelineEntry.State

    var body: some View {
        ZStack {
            switch state {
            case .live:
                Circle().fill(Color.jLiveHalo).frame(width: 20, height: 20)
                BreathingDot(size: 12)
            case .processing, .onWatch:
                Circle()
                    .strokeBorder(Color.jText4, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.2]))
                    .frame(width: 12, height: 12)
            case .done:
                Circle().fill(Color.jBg).frame(width: 12, height: 12)
                Circle().strokeBorder(Color.jText, lineWidth: 1.5).frame(width: 12, height: 12)
            }
        }
        .frame(width: 20, height: 20)
        .padding(.top, -4)
    }
}

// MARK: - Empty

struct EmptyDay<Actions: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var actions: Actions

    init(title: String, detail: String?, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            // The watch is drawn at 680×485 and bleeds past both edges; it
            // takes 293 pt of height, the rest overlaps the space around it.
            Color.clear
                .frame(height: 293)
                .overlay {
                    Image("WatchArt")
                        .resizable()
                        .frame(width: 680, height: 485)
                        .offset(x: -15, y: 14)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)

            VStack(spacing: 8) {
                Text(title)
                    .font(.scaled(22, .semibold, relativeTo: .title2))
                    .tracking(-0.44)
                    .foregroundStyle(Color.jText)
                if let detail {
                    Text(detail)
                        .font(.summary)
                        .foregroundStyle(Color.jText2)
                        .lineSpacing(4)
                        .frame(maxWidth: 300)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.top, 20)

            actions.padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52 - 28)
        .padding(.horizontal, 20)
    }
}
