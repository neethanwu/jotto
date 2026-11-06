import SwiftUI

/// Home: one day at a time. Wordmark, the day's name, a week strip to move
/// between days, and the day's recordings on a timeline.
struct DaysView: View {
    let router: Router
    @State private var day = Calendar.current.startOfDay(for: .now)
    private var library: Library { .shared }
    private var config: AppConfig { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image("Wordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 28)
                    .frame(height: 52)
                    .padding(.horizontal, 20)
                    .accessibilityLabel("Jotto")

                header
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                WeekStrip(selection: $day, marked: library.daysWithRecordings, liveDay: liveDay)
                    .padding(.top, 20)

                content
                    .padding(.top, 28)
            }
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .background(Color.jBg)
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

    private var liveDay: Date? {
        library.liveEntry.map { Calendar.current.startOfDay(for: $0.startedAt) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.formatted(.dateTime.weekday(.wide)))
                .dayTitleStyle()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(meta)
                .font(.meta)
                .foregroundStyle(Color.jText3)
        }
        .accessibilityElement(children: .combine)
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
        if !config.isReady {
            EmptyDay(
                title: "Connect to a server",
                detail: "Add the server address and token in Account, then record on your watch"
            ) {
                Button("Open Account") { router.tab = .account }
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
            Timeline(entries: entries) { entry in
                router.days.append(entry.state == .live ? .live(id: entry.id) : .transcript(id: entry.id))
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
    @State private var week: Date?
    @State private var weeks = WeekStrip.makeWeeks()
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

    private static func makeWeeks() -> [Week] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return (-26...1).compactMap { offset -> Week? in
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
            if weeks.last.map({ $0.id < Calendar.current.startOfDay(for: .now).addingTimeInterval(-7 * 86400) }) ?? true {
                weeks = Self.makeWeeks()
            }
            week = weekStart(selection)
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
            withAnimation(.spring(duration: 0.32, bounce: 0.15)) { selection = day.date }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.label)
        .accessibilityValue(hasRecordings ? "Has recordings" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selection = day.date }
    }
}

// MARK: - Timeline

struct Timeline: View {
    let entries: [TimelineEntry]
    let open: (TimelineEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                Button { open(entry) } label: {
                    TimelineRow(entry: entry, isLast: i == entries.count - 1)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: entries)
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
                Text(Format.length(length)).font(.metaSmall).foregroundStyle(Color.jText3)
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
                        .offset(x: -15)
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
