import SwiftUI

/// Home: one day at a time. Wordmark and Search, the day's
/// name (tap for a month calendar), a week strip to move between days,
/// and the day's recordings on a timeline. Search opens right here: the
/// title folds away, the strip shows which days match, results replace
/// the timeline.
struct DaysView: View {
    let router: Router
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var scroll = ScrollPosition(edge: .top)
    /// The week the strip shows; may differ from `day` after a swipe.
    @State private var stripWeek: Date?
    @State private var picking = false
    /// The header has had its real size at least once.
    @State private var headerPlaced = false
    /// The row swiped open, if any; one at a time.
    @State private var swiped: String?
    @State private var sharing: SessionDetail?
    @State private var sharingDay: DaySend?
    @State private var deleting: TimelineEntry?
    @State private var searching = false
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var searchError: String?
    /// A day picked in the strip while searching; nil is every day.
    @State private var searchDay: Date?
    @FocusState private var searchFocused: Bool
    @State private var actionError: String?
    @State private var askingPlaces = false
    private var library: Library { .shared }
    private var places: PlaceTracker { .shared }
    private var config: AppConfig { .shared }

    var body: some View {
        VStack(spacing: 0) {
            // Wordmark, the day and the week strip stay put; only the
            // recordings scroll.
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if searching {
                        searchBar
                    } else {
                        BrandBar {
                            HStack(spacing: 8) {
                                if showsToday {
                                    Button("Today", action: goToToday)
                                        .buttonStyle(BarPillStyle())
                                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                }
                                CircleIconButton(glyph: .search, label: "Search") { startSearching() }
                            }
                        }
                        .animation(.easeOut(duration: 0.2), value: showsToday)
                    }
                }
                .padding(.horizontal, 20)

                if searching {
                    searchMeta
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                } else {
                    header
                }

                WeekStrip(
                    selection: searching ? searchStripBinding : $day,
                    marked: searching && results != nil ? matchedDays : library.daysWithRecordings,
                    liveDay: searching ? nil : liveDay,
                    earliest: library.earliest,
                    showsSelection: !searching || searchDay != nil,
                    fadesUnmarked: searching && results != nil,
                    week: $stripWeek
                )
                .padding(.vertical, 8)
            }
            .background(Color.jBg)
            .zIndex(1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if searching {
                        searchContent
                    } else {
                        // Another day: the list cross-fades in place, quickly,
                        // instead of its rows springing along with the strip.
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) { content }
                                .id(day)
                                .transition(.opacity)
                        }
                        .animation(.easeOut(duration: 0.16), value: day)
                    }
                }
                .padding(.top, searching ? 12 : 20)
                .padding(.bottom, 140)
                .keyboardFriendly()
            }
            .scrollPosition($scroll)
            .scrollDismissesKeyboard(.immediately)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, swiped != nil { withAnimation(.spring(duration: 0.3)) { swiped = nil } }
            }
            .scrollIndicators(.hidden)
            .refreshable { await library.refresh() }
        }
        .statusBarCover()
        .background(Color.jBg)
        .onChange(of: router.daysReselected) { goToToday() }
        .drawer(item: $sharing) { detail in
            SendPanel(detail: detail, title: detail.title ?? Format.provisionalTitle(detail.startedAt))
        }
        .drawer(item: $sharingDay) { send in
            SendPanel(day: send.day, items: send.items)
        }
        .drawer(isPresented: $picking) {
            DayPicker(selection: $day, marked: library.daysWithRecordings, earliest: library.earliest)
        }
        .drawer(isPresented: $askingPlaces) {
            PlacesSheet { places.cardDismissed = true }
        }
        .task(id: query) { await search() }
        .alert("Delete this recording?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete(entry.id) } }
        } message: { entry in
            Text(DeleteCopy.message(entry.title))
        }
        .alert("Couldn't do that", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {} message: { Text(actionError ?? "") }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            // Fast while anything is recording or processing, slow otherwise.
            while !Task.isCancelled {
                await library.refresh()
                try? await Task.sleep(for: .seconds(library.isBusy ? 5 : 30))
            }
        }
    }

    private var entries: [TimelineEntry] { library.entries(on: day) }

    /// On today, and on the day of the recording that waited.
    private var showsPlacesCard: Bool {
        guard places.showsCard else { return false }
        if Calendar.current.isDateInToday(day) { return true }
        guard let id = places.waitedRecording, let entry = library.entries.first(where: { $0.id == id }) else { return false }
        return Calendar.current.isDate(entry.startedAt, inSameDayAs: day)
    }

    // MARK: - Search

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func startSearching() {
        swiped = nil
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
            searching = true
            scroll.scrollTo(edge: .top)
        }
        searchFocused = true
    }

    private func stopSearching() {
        searchFocused = false
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
            searching = false
            query = ""
            results = nil
            searchDay = nil
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                GlyphView(glyph: .search, color: .jText3).frame(width: 16, height: 16)
                TextField("Search every recording", text: $query)
                    .font(.rowTitle)
                    .foregroundStyle(Color.jText)
                    .tint(Color.jLive)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { RecentSearches.add(trimmed) }
                ClearButton(text: $query) {
                    searchDay = nil
                    searchFocused = true
                }
                .padding(.trailing, -6)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .fieldBackground()

            Button("Cancel", action: stopSearching)
                .font(.label)
                .foregroundStyle(Color.jText2)
        }
        .frame(height: 52)
        .transition(.opacity)
    }

    @ViewBuilder
    private var searchMeta: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(searchSummary)
                .font(.meta)
                .foregroundStyle(Color.jText3)
            Spacer()
            if searchDay != nil {
                Button("All days") { withAnimation(.spring(duration: 0.3)) { searchDay = nil } }
                    .font(.scaled(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Color.jText)
            }
        }
    }

    private var searchSummary: String {
        if trimmed.count < 2 { return "Words, names, anything someone said" }
        if let searchError { return searchError }
        guard let results else { return "Searching" }
        let shown = visibleSessions(results)
        let matches = shown.reduce(0) { $0 + max(1, $1.hits.count) }
        if matches == 0 { return "No matches" }
        let noun = matches == 1 ? "match" : "matches"
        if let searchDay {
            return "\(matches) \(noun) on \(searchDay.formatted(.dateTime.weekday(.wide)))"
        }
        return "\(matches) \(noun) in \(Format.plural(shown.count, "recording"))"
    }

    private var matchedDays: Set<Date> {
        Set((results?.sessions ?? []).map { Calendar.current.startOfDay(for: $0.startedAt) })
    }

    /// In search, the strip picks a day to narrow to, and tapping it again
    /// lets go. With no day picked it shows the week of the newest match.
    private var searchStripBinding: Binding<Date> {
        Binding(
            get: { searchDay ?? matchedDays.max() ?? day },
            set: { picked in
                withAnimation(.spring(duration: 0.3)) {
                    searchDay = searchDay.map { Calendar.current.isDate($0, inSameDayAs: picked) } == true ? nil : picked
                }
            }
        )
    }

    private func visibleSessions(_ results: SearchResults) -> [SearchResults.Session] {
        guard let searchDay else { return results.sessions }
        return results.sessions.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: searchDay) }
    }

    @ViewBuilder
    private var searchContent: some View {
        if trimmed.count < 2 {
            let recent = RecentSearches.all
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent")
                        .font(.scaled(11, .medium, relativeTo: .caption2))
                        .foregroundStyle(Color.jText3)
                    FlowLayout(spacing: 8) {
                        ForEach(recent, id: \.self) { q in
                            Button { query = q } label: {
                                Text(q)
                                    .font(.summary)
                                    .foregroundStyle(Color.jText)
                                    .padding(.horizontal, 14)
                                    .frame(height: 36)
                                    .background(Color.jFill, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        } else if let results {
            let byDay = Dictionary(grouping: visibleSessions(results)) { Calendar.current.startOfDay(for: $0.startedAt) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(byDay.keys.sorted(by: >), id: \.self) { date in
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.speaker)
                        .foregroundStyle(Color.jText)
                        .padding(.top, 20)
                        .padding(.bottom, 6)
                    ForEach(byDay[date] ?? []) { session in
                        result(session)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func result(_ session: SearchResults.Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                RecentSearches.add(trimmed)
                router.days.append(.transcript(id: session.id))
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title ?? Format.provisionalTitle(session.startedAt))
                        .font(.rowTitle)
                        .foregroundStyle(Color.jText)
                    Spacer()
                    Text(Format.time(session.startedAt))
                        .font(.meta)
                        .foregroundStyle(Color.jText3)
                }
            }
            .buttonStyle(.plain)
            ForEach(session.hits, id: \.self) { hit in
                Button {
                    RecentSearches.add(trimmed)
                    router.days.append(.transcript(id: session.id, at: hit.start))
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(Format.clock(hit.start))
                            .font(.metaSmall)
                            .foregroundStyle(Color.jText3)
                            .frame(width: 48, alignment: .leading)
                        highlighted(hit.text)
                            .font(.summary)
                            .lineSpacing(3)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    /// The query in `text` Semibold, the rest in `text-2`.
    private func highlighted(_ text: String) -> Text {
        var out = AttributedString(text)
        out.foregroundColor = Color.jText2
        var range = out.startIndex..<out.endIndex
        while let hit = out[range].range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[hit].foregroundColor = Color.jText
            out[hit].font = .system(size: 15, weight: .semibold)
            range = hit.upperBound..<out.endIndex
        }
        return Text(out)
    }

    private func search() async {
        guard searching, trimmed.count >= 2 else {
            results = nil
            searchError = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            let found = try await API.search(trimmed)
            withAnimation(.easeOut(duration: 0.2)) { results = found }
            searchError = nil
            if let searchDay, !matchedDays.contains(searchDay) { self.searchDay = nil }
        } catch {
            if !Task.isCancelled { searchError = error.localizedDescription }
        }
    }

    // MARK: - Row actions

    struct DaySend: Identifiable {
        let day: Date
        let items: [(detail: SessionDetail, title: String)]
        var id: Date { day }
    }

    private func shareDay() async {
        var items: [(detail: SessionDetail, title: String)] = []
        for entry in entries where entry.state != .live {
            // One where nothing was said would only be a heading.
            guard let detail = try? await API.session(entry.id), !detail.blocks.isEmpty else { continue }
            items.append((detail, detail.title ?? Format.provisionalTitle(detail.startedAt)))
        }
        guard !items.isEmpty else { return }
        sharingDay = DaySend(day: day, items: items)
    }

    private func share(_ id: String) async {
        do { sharing = try await API.session(id) } catch { actionError = error.localizedDescription }
    }


    private func delete(_ id: String) async {
        do {
            try await API.delete(id)
            withAnimation(.spring(duration: 0.35)) { library.remove(id) }
            try? FileManager.default.removeItem(at: AudioFiles.directory.appending(path: id))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    /// Off today, or the strip swiped to another week: a way straight back.
    private var showsToday: Bool {
        let thisWeek = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start
        return !isToday || (stripWeek != nil && stripWeek != thisWeek)
    }

    /// Back to today and the top, from the Today button or tapping Days again.
    private func goToToday() {
        withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
            day = Calendar.current.startOfDay(for: .now)
            scroll.scrollTo(edge: .top)
        }
        // Today may already be picked with the strip swiped elsewhere.
        withAnimation(.smooth(duration: 0.35)) {
            stripWeek = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start
        }
    }

    private var liveDay: Date? {
        library.liveEntry.map { Calendar.current.startOfDay(for: $0.startedAt) }
    }

    /// The day's name; tapping it opens the month calendar.
    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            dayButton
            if entries.contains(where: { $0.state != .live }) {
                // Everything from this day in one go: the template's
                // instruction once, then each recording in order.
                CircleIconButton(glyph: .send, label: "Send the day") { Task { await shareDay() } }
                    .padding(.leading, 12)
                    .padding(.trailing, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        // Only once the header is in place: at launch the page is first
        // laid out at no size, before the recordings have loaded, and
        // animating their arrival would fly the day's name in from the
        // corner.
        .animation(headerPlaced ? .easeOut(duration: 0.2) : nil, value: entries.isEmpty)
        .onGeometryChange(for: Bool.self) { $0.size.width > 200 } action: { if $0 { headerPlaced = true } }
    }

    private var dayButton: some View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            // The margins are inside the button, so the whole band
            // between the wordmark and the week strip takes the tap, to
            // the screen's edge: a thumb aimed at the chevron lands
            // well wide of an 18-pt glyph.
            .padding(.leading, 20)
            .padding(.trailing, entries.contains(where: { $0.state != .live }) ? 0 : 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(DayTitleStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Pick another day")
    }

    /// Dims while held, so a tap anywhere on the name, the chevron or
    /// the line under them shows it was taken.
    private struct DayTitleStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.5 : 1)
                .animation(.easeOut(duration: configuration.isPressed ? 0.06 : 0.2), value: configuration.isPressed)
        }
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
        if showsPlacesCard {
            PlacesCard(waitedTitle: places.waitedRecording.flatMap { id in library.entries.first { $0.id == id }?.title }) {
                if places.needsAsking { askingPlaces = true } else { places.turnOn() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 26)
            .transition(.opacity)
        }
        if entries.isEmpty {
            if Calendar.current.isDateInToday(day) {
                EmptyDay(title: "Tap the dot when it matters", detail: "Recordings from your watch land here, cleaned up, a minute after each part.")
            } else if day > .now {
                EmptyDay(title: "Not yet", detail: nil)
            } else {
                EmptyDay(title: "No recordings", detail: library.loadError)
            }
        } else {
            Timeline(entries: entries, swiped: $swiped, actions: .init(
                send: { entry in Task { await share(entry.id) } },
                rename: { entry in router.days.append(.transcript(id: entry.id, rename: true)) },
                delete: { entry in deleting = entry }
            )) { entry in
                if entry.state == .live {
                    router.live = Router.Live(id: entry.id)
                } else {
                    router.days.append(.transcript(id: entry.id))
                }
            }
            .padding(.horizontal, 20)
            if let error = library.loadError {
                Text(error).font(.summary).foregroundStyle(Color.jText3).padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - Week strip

/// Seven days per page, on the same 20 pt edges as the title, paging by
/// week. In search, days without a match fade and nothing need be picked.
struct WeekStrip: View {
    @Binding var selection: Date
    let marked: Set<Date>
    let liveDay: Date?
    /// The first recording, so the strip reaches back at least that far.
    let earliest: Date?
    var showsSelection = true
    var fadesUnmarked = false
    /// The week in view, shared so Days knows when it's been swiped away.
    @Binding var week: Date?
    @State private var weeks: [Week] = []
    @Namespace private var highlight

    private static let height: CGFloat = 64

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
                        ForEach(Array(week.days.enumerated()), id: \.element.date) { i, day in
                            cell(day, now: now)
                            if i < week.days.count - 1 { Spacer(minLength: 0) }
                        }
                    }
                    .padding(.horizontal, 20)
                    .containerRelativeFrame(.horizontal)
                    .id(week.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $week)
        .scrollIndicators(.hidden)
        .frame(height: Self.height)
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


    private func weekStart(_ day: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: day)?.start ?? day
    }

    private func cell(_ day: Day, now: Date) -> some View {
        let selected = showsSelection && Calendar.current.isDate(day.date, inSameDayAs: selection)
        let hasRecordings = marked.contains(day.date)
        let future = day.date > now
        let faded = future || (fadesUnmarked && !hasRecordings)
        let live = liveDay == day.date
        // Every day you can pick looks the same; the dot says which have
        // recordings. Only days still to come are faint.
        let dayColor: Color = selected ? .jBg : faded ? .jText5 : .jText

        return VStack(spacing: 4) {
            Text(day.letter)
                .font(.weekday)
                .foregroundStyle(selected ? Color.jBg.opacity(0.6) : faded ? Color.jText5 : Color.jText4)
            Text(day.number)
                // Proportional digits: a tabular "1" sits right of its
                // slot, which pushed "12" off centre in the pill.
                .font(.system(size: 16, weight: selected ? .semibold : .medium))
                .foregroundStyle(dayColor)
                .offset(x: OpticalCentre.nudge(day.number))
            Circle()
                .fill(live ? Color.jLive : selected ? Color.jBg : Color.jText)
                .frame(width: 4, height: 4)
                .opacity(hasRecordings || live ? 1 : 0)
        }
        .frame(width: 46, height: Self.height)
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

/// Day numbers centred by what the eye takes as their edges, not by
/// their box. A "1" reads from its stem: its flag is a short stroke out
/// to the left, so "13" centred by its box (or by its ink's weight) still
/// looks pushed right in the pill, with more room on the left. Each value
/// is how far right of its box centre a number's seen middle is, the
/// stem of a leading "1" counted as its left edge (SF Pro 16 Semibold,
/// measured from the rendered glyphs; Medium is within 0.1 pt).
enum OpticalCentre {
    private static let offsets: [CGFloat] = [
        1.14, 0.19, 0.18, 0.10, 0.29, 0.14, 0.11, 0.14, 0.14, 1.61,
        1.09, 1.58, 1.57, 1.62, 1.62, 1.59, 1.69, 1.60, 1.59, 0.16,
        -0.36, 0.13, 0.12, 0.18, 0.17, 0.14, 0.24, 0.15, 0.14, 0.17, -0.31,
    ]

    static func nudge(_ number: String) -> CGFloat {
        guard let n = Int(number), (1...31).contains(n) else { return 0 }
        return -offsets[n - 1]
    }
}

// MARK: - Timeline

struct Timeline: View {
    struct Actions {
        let send: (TimelineEntry) -> Void
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
                         send: { actions.send(entry) }, delete: { actions.delete(entry) }) {
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
                            Button("Send", systemImage: "paperplane") { actions.send(entry) }
                            Button { actions.rename(entry) } label: { Label { Text("Rename") } icon: { Glyph.pen.image() } }
                            Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(entry) }
                        }
                    }
                }
                .accessibilityAction(named: "Send") { if finished { actions.send(entry) } }
                .accessibilityAction(named: "Delete") { if finished { actions.delete(entry) } }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: entries)
    }
}

/// Swipe a row left to show Send and Delete behind it. The whole row
/// slides, like a system list. Only horizontal drags count, so the page
/// still scrolls.
struct SwipeRow<Content: View>: View {
    let id: String
    @Binding var swiped: String?
    let enabled: Bool
    let send: () -> Void
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
        content
            .offset(x: offset)
            // An overlay, so the 40-pt buttons never make a one-line row
            // taller and push the rows below it down.
            .overlay(alignment: .trailing) {
                // Only there while the row is moved, so hidden ones can't be hit.
                if enabled, offset < 0 {
                    HStack(spacing: 12) {
                        action("Send", glyph: .sendFilled, fill: .jText, ink: .jBg, run: send)
                        action("Delete", glyph: .trash, fill: .jDestructive, ink: .white, run: delete)
                    }
                    // Centred on the row's text: the row ends in 28 of space.
                    .padding(.bottom, 28)
                    // A one-line row is shorter than the buttons: centre on its title.
                    .frame(minHeight: 68, maxHeight: .infinity)
                    // They come in from the edge with the row, not appear in place.
                    .offset(x: max(0, Self.reveal + offset))
                    .opacity(min(1, Double(-offset / Self.reveal) * 1.6))
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
                .frame(width: 40, height: 40)
                .background(fill, in: Circle())
        }
        .buttonStyle(PressStyle())
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
                .foregroundStyle(entry.state == .naming ? Color.jText3 : Color.jText)
                .lineLimit(2)
                // The stand-in title shimmers while jotto writes the real one.
                .shimmering(entry.state == .naming)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.3), value: entry.title)
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
        case let .formatting(done, total):
            VStack(alignment: .leading, spacing: 6) {
                placeLine
                if let summary = entry.summary {
                    Text(summary)
                        .font(.summary)
                        .foregroundStyle(Color.jText2)
                        .lineLimit(3)
                        .lineSpacing(3)
                }
                Text("Formatting · \(done) of \(total)")
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText3)
                    .contentTransition(.numericText())
            }
        case .naming:
            VStack(alignment: .leading, spacing: 6) {
                placeLine
                Text("Writing a title and summary")
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText3)
            }
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                placeLine
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

    /// Where it was said, under the title: "Lumen Café", or
    /// "Lumen Café → Willow Park" when it ended somewhere else.
    @ViewBuilder
    private var placeLine: some View {
        if let place = entry.place {
            HStack(spacing: 4) {
                GlyphView(glyph: .pin, color: .jText3)
                    .frame(width: 12, height: 12)
                Text(place)
                    .font(.meta)
                    .foregroundStyle(Color.jText3)
                    .lineLimit(1)
            }
            // Tucked up to the title, as one heading with it.
            .padding(.top, -2)
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
                .card()
        }
    }

    private func processingText(done: Int, total: Int?, polishing: Bool) -> String {
        if !polishing, let waiting = Pipeline.shared.waiting { return waiting }
        guard let total, total > 0 else { return "Transcribing" }
        return polishing ? "Cleaning up" : "Transcribing · \(min(done, total)) of \(total) parts"
    }

    private var accessibilityText: String {
        var parts = [entry.title, Format.time(entry.startedAt)]
        if let length = entry.length { parts.append(Format.length(length)) }
        if let place = entry.place, entry.state != .live { parts.append(place) }
        switch entry.state {
        case .live: parts.append("Recording")
        case .processing: parts.append("Processing")
        case .formatting: parts.append("Formatting")
        case .naming: parts.append("Writing a title")
        case .onWatch: parts.append("On your watch")
        case .done: parts.append("Done")
        }
        return parts.joined(separator: ", ")
    }
}

/// A band of light passing over text, left to right, while it's being
/// worked on. Still (and just quieter text) with Reduce Motion.
struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content.overlay {
                TimelineView(.animation) { context in
                    // One pass every 1.6 s, with a pause between passes.
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.2
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.jText.opacity(0.9), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.45)
                            .offset(x: (geo.size.width * 1.45) * t - geo.size.width * 0.45)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    func shimmering(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// The dashed ring, turning: the phone is working on it. Still when
/// Reduce Motion is on.
struct ProcessingRing: View {
    var size: CGFloat = 12
    var color: Color = .jText3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            // One turn every 2.4 s.
            let turns = context.date.timeIntervalSinceReferenceDate / 2.4
            Circle()
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2.5, 2.2]))
                .rotationEffect(.degrees(reduceMotion ? 0 : turns.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The timeline mark: live (orange with halo), working (turning dashed
/// ring), waiting on the watch (still dashed ring), done (solid ring).
/// The same marks appear on the watch.
struct StateDot: View {
    let state: TimelineEntry.State

    var body: some View {
        ZStack {
            switch state {
            case .live:
                Circle().fill(Color.jLiveHalo).frame(width: 20, height: 20)
                BreathingDot(size: 12)
            case .processing, .formatting, .naming:
                ProcessingRing(size: 12)
            case .onWatch:
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

/// What deleting takes with it, said once for Days and the transcript.
enum DeleteCopy {
    static func message(_ title: String) -> String {
        "\u{201C}\(title)\u{201D} and its audio are removed from this iPhone. This can't be undone."
    }
}
