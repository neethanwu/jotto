import SwiftUI

/// The Settings tab: this month's numbers on the one card, then plain
/// rows grouped under small labels. Rows appear as their
/// features land (prompts, templates, highlights; see docs/06).
struct SettingsView: View {
    let router: Router
    private var config: AppConfig { .shared }
    private var inbox: Inbox { .shared }
    private var library: Library { .shared }

    var body: some View {
        // No large title: the tab bar already says Settings.
        TabPage {
            VStack(alignment: .leading, spacing: 0) {
                MonthCard(entries: library.entries)
                    .padding(.top, 16)

                SettingsSection("Transcribe and polish") {
                    NavigationLink(value: Route.processing) {
                        SettingsRow("Processing", value: "On this iPhone")
                    }
                    NavigationLink(value: Route.language) {
                        SettingsRow("Languages", value: config.languages.count == 1
                                    ? LanguageView.name(config.languages[0])
                                    : config.languages.map(LanguageView.shortName).joined(separator: ", "))
                    }
                    if Editor.isAvailable {
                        SettingsToggle("Tidy up the text", isOn: Bindable(config).tidiesText)
                    }
                    if Describer.isAvailable {
                        SettingsToggle("Titles and summaries", isOn: Bindable(config).writesTitles)
                    }
                    SettingsToggle("Notify when ready", isOn: Bindable(config).notifiesWhenReady)
                }

                SettingsSection("Highlights") {
                    NavigationLink(value: Route.moments) {
                        SettingsRow("A star covers", value: Moments.label(config.momentSeconds))
                    }
                }

                SettingsSection("Storage") {
                    NavigationLink(value: Route.keepAudio) {
                        SettingsRow("Keep audio", value: KeepAudio.label(config.keepAudioDays))
                    }
                    NavigationLink(value: Route.openIn) {
                        SettingsRow("Open transcripts in", value: config.opensOriginal ? "Original" : "Clean")
                    }
                }

                SettingsSection("Beta") {
                    SettingsRow("Apple Watch", value: inbox.watchStatus.capitalizedFirst, chevron: false)
                    NavigationLink(value: Route.inbox) {
                        SettingsRow("Files from the watch", value: "\(inbox.items.count)")
                    }
                }

                Text("Jotto \(Bundle.main.version) · built by neethan")
                    .font(.scaled(11, .medium, relativeTo: .caption2).monospacedDigit())
                    .foregroundStyle(Color.jText4)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 140)
        }
        .task { await library.refresh() }
        .onChange(of: config.notifiesWhenReady) { _, on in
            if on { Task { await Notifier.shared.askIfNeeded(fromSwitch: true) } }
        }
    }
}

// MARK: - Building blocks

/// Back button, then a 34-pt title and an optional line under it.
struct PageHeader: View {
    let title: String
    var detail: String?
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CircleIconButton(glyph: .back, label: "Back", action: back)
                Spacer()
            }
            .frame(height: 52)
            .padding(.leading, -4)

            Text(title)
                .font(.transcriptTitle)
                .tracking(-0.68)
                .foregroundStyle(Color.jText)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.summary)
                    .foregroundStyle(Color.jText2)
                    .padding(.top, 8)
            }
        }
    }
}

/// A small grey label, then its rows.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.scaled(11, .medium, relativeTo: .caption2))
                .foregroundStyle(Color.jText3)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            SettingsGroup { content }
        }
        .padding(.top, 32)
    }
}

/// Rows with a hairline between them, none above the first or below the
/// last: whitespace and the label do the grouping. Kept flat so the month
/// card stays the page's only card.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 {
                        Rectangle().fill(Color.jHairline.opacity(0.7)).frame(height: 1)
                    }
                    row
                }
            }
        }
    }
}

struct SettingsRow: View {
    let label: String
    var value: String = ""
    var chevron = true

    init(_ label: String, value: String = "", chevron: Bool = true) {
        self.label = label
        self.value = value
        self.chevron = chevron
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.reading).foregroundStyle(Color.jText)
            Spacer(minLength: 12)
            Text(value)
                .font(.scaled(15, .medium, relativeTo: .subheadline))
                .foregroundStyle(Color.jText2)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.jText4)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).font(.reading).foregroundStyle(Color.jText)
        }
        .toggleStyle(JottoToggleStyle())
        .frame(minHeight: 52)
    }
}

/// One option in a pick-one list, with a check on the chosen one.
struct ChoiceRow: View {
    let label: String
    var detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.reading).foregroundStyle(Color.jText)
                    if let detail {
                        Text(detail).font(.scaled(13, .regular, relativeTo: .footnote)).foregroundStyle(Color.jText3)
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.jText)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Pick-one pages

/// How long audio stays after a recording is transcribed.
enum KeepAudio {
    static let options = [7, 30, 365, 0]

    static func label(_ days: Int) -> String {
        switch days {
        case 0: "Forever"
        case 365: "1 year"
        default: "\(days) days"
        }
    }
}

struct KeepAudioView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: AppConfig = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Keep audio", detail: "Transcripts stay until you delete them. Audio is removed this long after a recording is transcribed.") { dismiss() }
                SettingsGroup {
                    ForEach(KeepAudio.options, id: \.self) { days in
                        ChoiceRow(label: KeepAudio.label(days), selected: config.keepAudioDays == days) {
                            config.keepAudioDays = days
                        }
                    }
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 20)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: config.keepAudioDays)
    }
}

/// How far back a moment (the star) reaches.
enum Moments {
    static func label(_ seconds: Int) -> String {
        seconds >= 60 ? "Last \(seconds / 60) min" : "Last \(seconds) s"
    }
}

struct MomentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: AppConfig = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "A star covers", detail: "You mark a moment after you hear it, so a star reaches back from the tap, and \(Int(Highlight.after)) seconds past it. Sections cover exactly what you marked.") { dismiss() }
                SettingsGroup {
                    ForEach(Highlight.beforeChoices, id: \.self) { seconds in
                        ChoiceRow(label: Moments.label(seconds), detail: seconds == Highlight.defaultBefore ? "A sentence or two" : nil,
                                  selected: config.momentSeconds == seconds) {
                            config.momentSeconds = seconds
                        }
                    }
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 20)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: config.momentSeconds)
    }
}

struct OpenInView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: AppConfig = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Open transcripts in", detail: "You can always switch between them on the transcript.") { dismiss() }
                SettingsGroup {
                    ChoiceRow(label: "Clean", detail: "Tidied into sentences, fillers taken out", selected: !config.opensOriginal) { config.opensOriginal = false }
                    ChoiceRow(label: "Original", detail: "Every word, with the cuts struck through", selected: config.opensOriginal) { config.opensOriginal = true }
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 20)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: config.opensOriginal)
    }
}

/// This month at a glance: time recorded, how many recordings on how many
/// days, and a bar per day sized by minutes, orange for today.
struct MonthCard: View {
    let entries: [TimelineEntry]

    var body: some View {
        let calendar = Calendar.current
        let now = Date.now
        let month = calendar.dateInterval(of: .month, for: now)
        let inMonth = entries.filter { month?.contains($0.startedAt) ?? false }
        let seconds = inMonth.compactMap(\.length).reduce(0, +)
        let perDay = Dictionary(grouping: inMonth) { calendar.component(.day, from: $0.startedAt) }
            .mapValues { $0.compactMap(\.length).reduce(0, +) }
        let busiest = max(perDay.values.max() ?? 0, 1)
        let days = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let today = calendar.component(.day, from: now)
        let monthName = now.formatted(.dateTime.month(.wide))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recorded in \(monthName)")
                Spacer()
                Text("\(Format.plural(inMonth.count, "recording")) · \(Format.plural(perDay.count, "day"))")
            }
            .font(.scaled(11, .medium, relativeTo: .caption2).monospacedDigit())
            .foregroundStyle(Color.jText3)

            Self.amount(seconds)
                .accessibilityLabel(Format.length(seconds))

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(1...days, id: \.self) { day in
                    let length = perDay[day] ?? 0
                    Capsule()
                        .fill(day == today ? Color.jLive : length > 0 ? Color.jText : Color.jText5.opacity(0.6))
                        .frame(width: 6, height: length > 0 ? max(6, 36 * length / busiest) : 6)
                        // The rest of the month stays as a faint ruler.
                        .opacity(day > today ? 0.4 : 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 36, alignment: .bottom)
            .padding(.top, 12)
            .padding(.horizontal, -2)
            .accessibilityHidden(true)

            HStack {
                Text(edge(of: month, last: false))
                Spacer()
                Text(edge(of: month, last: true))
            }
            .font(.scaled(11, .medium, relativeTo: .caption2))
            .foregroundStyle(Color.jText4)
            .accessibilityHidden(true)
        }
        .padding(18)
        .card(radius: 24)
        .accessibilityElement(children: .combine)
    }

    /// "Nov 1" or "Nov 30" under the ends of the bars.
    private func edge(of month: DateInterval?, last: Bool) -> String {
        guard let month else { return "" }
        let day = last ? month.end.addingTimeInterval(-1) : month.start
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "12 h 40 min", numbers large and units small.
    static func amount(_ seconds: TimeInterval) -> some View {
        let minutes = Int(seconds / 60)
        let h = minutes / 60, m = minutes % 60
        let number = Font.scaled(40, .semibold, relativeTo: .largeTitle).monospacedDigit()
        let unit = Font.scaled(20, .medium, relativeTo: .title3)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if h > 0 {
                Text("\(h)").font(number).tracking(-0.8).foregroundStyle(Color.jText)
                Text("h").font(unit).foregroundStyle(Color.jText3).padding(.trailing, 6)
            }
            if m > 0 || h == 0 {
                Text("\(m)").font(number).tracking(-0.8).foregroundStyle(Color.jText)
                Text("min").font(unit).foregroundStyle(Color.jText3)
            }
        }
    }
}

extension Format {
    /// "3 h 18", "46 min".
    static func hours(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60)"
    }
}

extension Bundle {
    var version: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
