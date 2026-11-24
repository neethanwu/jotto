import StoreKit
import SwiftUI

/// The Settings tab, in the order a recording goes: how it becomes text
/// first, then what happens while you record, then the transcripts, then
/// this month. Each setting is one row; what it does is on its own page.
struct SettingsView: View {
    let router: Router
    private var config: AppConfig { .shared }
    private var inbox: Inbox { .shared }
    private var library: Library { .shared }
    private var places: PlaceTracker { .shared }
    @State private var isBeta = false
    /// The row open in place, if any: one at a time.
    @State private var open: Open?
    enum Open { case openIn, keepAudio }

    /// A build from Xcode or TestFlight, not the App Store.
    static func isBetaBuild() async -> Bool {
        #if DEBUG
        return true
        #else
        if let result = try? await AppTransaction.shared, case let .verified(transaction) = result {
            return transaction.environment != .production
        }
        // No answer from the App Store: TestFlight builds carry a sandbox receipt.
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    var body: some View {
        // No large title: the tab bar already says Settings.
        TabPage {
            VStack(alignment: .leading, spacing: 0) {
                FlowCard(change: { router.settings.append(.processing) })
                    .padding(.top, 16)

                CardSection("While you record", inset: 56) {
                    NavigationLink(value: Route.highlights) {
                        CardRow("Highlights", icon: "star", value: "\(config.momentBefore) s · \(config.momentAfter) s")
                    }
                    NavigationLink(value: Route.places) {
                        CardRow("Location", icon: "pin", value: placesValue,
                                warns: places.isDenied && places.wantsPlaces)
                    }
                }

                CardSection("Transcripts", inset: 56) {
                    ExpandRow(title: "Open in", icon: "doc.text", value: config.opensOriginal ? "Original" : "Formatted",
                              open: openBinding(.openIn)) {
                        ChoiceLine(name: "Formatted", detail: "Tidied into sentences, fillers taken out",
                                   selected: !config.opensOriginal, first: true, underIcon: true) { pick { config.opensOriginal = false } }
                        ChoiceLine(name: "Original", detail: "Every word, with the cuts struck through",
                                   selected: config.opensOriginal, underIcon: true) { pick { config.opensOriginal = true } }
                    }
                    ExpandRow(title: "Keep audio", icon: "waveform", value: KeepAudio.label(config.keepAudioDays),
                              open: openBinding(.keepAudio)) {
                        ForEach(Array(KeepAudio.options.enumerated()), id: \.element) { i, days in
                            ChoiceLine(name: KeepAudio.label(days),
                                       selected: config.keepAudioDays == days, first: i == 0, underIcon: true) {
                                pick { config.keepAudioDays = days }
                            }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: config.opensOriginal)
                .sensoryFeedback(.selection, trigger: config.keepAudioDays)

                VStack(alignment: .leading, spacing: 0) {
                    CardSectionTitle("Your month")
                    MonthCard(entries: library.entries)
                }
                .padding(.top, 28)

                CardSection("About") {
                    Link(destination: Links.support) { CardRow("Help and feedback", accessory: .outside) }
                    Link(destination: Links.privacy) { CardRow("Privacy policy", accessory: .outside) }
                    Link(destination: Links.source) { CardRow("Source code", value: "GitHub", accessory: .outside) }
                    NavigationLink(value: Route.acknowledgements) {
                        CardRow("Acknowledgements")
                    }
                }

                // For testing: gone in the App Store build.
                if isBeta {
                    CardSection("Beta") {
                        CardRow("Apple Watch", value: inbox.watchStatus.capitalizedFirst, accessory: .none)
                        NavigationLink(value: Route.inbox) {
                            CardRow("Files from the watch", value: "\(inbox.items.count)")
                        }
                    }
                }

                VStack(spacing: 10) {
                    Image("Wordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 22)
                        .accessibilityLabel("jotto")
                    Text("jotto \(Bundle.main.version) · built by neethan")
                        .font(.scaled(11, .medium, relativeTo: .caption2).monospacedDigit())
                        .foregroundStyle(Color.jText4)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 140)
        }
        .task { await library.refresh() }
        .task { isBeta = await Self.isBetaBuild() }
    }

    private func openBinding(_ row: Open) -> Binding<Bool> {
        Binding(get: { open == row }, set: { open = $0 ? row : (open == row ? nil : open) })
    }

    /// Picked: a beat to see the check move, then fold away.
    private func pick(_ change: () -> Void) {
        change()
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(ExpandRow<EmptyView>.fold) { open = nil }
        }
    }

    private var placesValue: String {
        if places.isDenied, places.wantsPlaces { return "Not allowed" }
        return places.isOn ? "On" : "Off"
    }
}

// MARK: - How a recording becomes text

/// The page's centre: the three things that happen to a recording and
/// who does each, with Notify when ready at its end. Change goes to
/// Processing, where the last two are picked.
struct FlowCard: View {
    let change: () -> Void
    @Bindable private var config: AppConfig = .shared

    var body: some View {
        VStack(spacing: 0) {
            // The whole picture opens Processing, not only "Change".
            Button(action: change) {
                VStack(spacing: 0) {
                    HStack {
                        Text("How a recording becomes text")
                            .font(.scaled(13, .medium, relativeTo: .footnote))
                            .foregroundStyle(Color.jText2)
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            Text("Change")
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        }
                        .font(.scaled(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Color.jText)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                    FlowSteps(steps: [
                        .init(icon: .symbol("applewatch"), label: "Records", value: "Apple Watch"),
                        .init(icon: .symbol("iphone"), label: "Transcribes", value: transcribes),
                        .init(icon: .symbol("text.alignleft"), label: "Tidies and titles", value: tidies ?? "Off", off: tidies == nil),
                    ])
                    .padding(.top, 18)
                    .padding(.bottom, 18)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Highlight())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Change processing")

            Rectangle().fill(Color.jHairline).frame(height: 1)
            HStack(spacing: 12) {
                RowIcon("bell")
                Toggle(isOn: $config.notifiesWhenReady) {
                    Text("Notify when ready").font(.reading).foregroundStyle(Color.jText)
                }
                .toggleStyle(JottoToggleStyle())
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
        }
        .card()
        .onChange(of: config.notifiesWhenReady) { _, on in
            if on { Task { await Notifier.shared.askIfNeeded(fromSwitch: true) } }
        }
    }

    /// Pressed, the picture dims a touch, like a row in a list.
    private struct Highlight: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: Radius.card, topTrailingRadius: Radius.card, style: .continuous)
                        .fill(Color.jText.opacity(configuration.isPressed ? 0.05 : 0))
                )
                .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.2), value: configuration.isPressed)
        }
    }

    private var transcribes: String {
        Cloud.isOn ? Cloud.sendsTo : "This iPhone"
    }

    /// Nil when nothing on this iPhone can: no Apple Intelligence here.
    private var tidies: String? {
        if Cloud.isOn { return Cloud.sendsTo }
        return Editor.isAvailable ? "Apple" : nil
    }
}

/// Steps in a row on a thin line: a round icon, what happens, and who or
/// what does it. Used for a recording's way to text and for a shortcut.
struct FlowSteps: View {
    struct Step: Identifiable {
        enum Icon { case symbol(String), app }
        let icon: Icon
        let label: String
        let value: String
        var off = false
        var id: String { label }
    }

    let steps: [Step]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(steps) { step in
                VStack(spacing: 10) {
                    icon(step)
                        .frame(width: 40, height: 40)
                        .background(Color.jFill, in: Circle())
                    VStack(spacing: 2) {
                        Text(step.label)
                            .font(.scaled(11, .medium, relativeTo: .caption2))
                            .foregroundStyle(Color.jText3)
                        Text(step.value)
                            .font(.scaled(15, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(step.off ? Color.jText4 : Color.jText)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 10)
        // The line runs from the first circle's centre to the last's, under them.
        .background(alignment: .top) {
            GeometryReader { geo in
                let inset = (geo.size.width - 20) / CGFloat(steps.count) / 2 + 10
                Rectangle().fill(Color.jHairline)
                    .frame(width: max(0, geo.size.width - inset * 2), height: 1)
                    .offset(x: inset, y: 20)
            }
        }
    }

    @ViewBuilder
    private func icon(_ step: Step) -> some View {
        switch step.icon {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(step.off ? Color.jText4 : Color.jText)
        case .app:
            // jotto's own mark: the dot on black.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.ink950)
                .overlay(Circle().fill(Color.jLive).frame(width: 7, height: 7))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.jChromeStroke))
                .frame(width: 20, height: 20)
        }
    }
}

// MARK: - Cards of rows

/// A small grey label over a card.
struct CardSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.scaled(13, .medium, relativeTo: .footnote))
            .foregroundStyle(Color.jText2)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A label, then its rows in one card.
struct CardSection<Content: View>: View {
    let title: String
    /// Rows with icons: hairlines start after the icon.
    var inset: CGFloat
    @ViewBuilder var content: Content

    init(_ title: String, inset: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.inset = inset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionTitle(title)
            CardGroup(inset: inset) { content }
        }
        .padding(.top, 28)
    }
}

/// Rows in a card, a hairline between them that starts where the text does.
struct CardGroup<Content: View>: View {
    var inset: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 {
                        Rectangle().fill(Color.jHairline)
                            .frame(height: 1)
                            .padding(.leading, inset)
                    }
                    row
                }
            }
        }
        .card()
    }
}

/// A row's icon: an outline symbol in a fixed slot, so the labels line up.
struct RowIcon: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Group {
            // A place has jotto's own pin, as on Days.
            if name == "pin" {
                GlyphView(glyph: .pin, color: .jText2).frame(width: 18, height: 18)
            } else {
                Image(systemName: name)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.jText2)
            }
        }
        .frame(width: 28)
        .accessibilityHidden(true)
    }
}

/// One setting: an optional icon, its name, its value, and where a tap goes.
struct CardRow: View {
    enum Accessory { case chevron, outside, none }

    let label: String
    var icon: String?
    var value: String
    var accessory: Accessory
    /// The value is something to fix.
    var warns: Bool

    init(_ label: String, icon: String? = nil, value: String = "", accessory: Accessory = .chevron, warns: Bool = false) {
        self.label = label
        self.icon = icon
        self.value = value
        self.accessory = accessory
        self.warns = warns
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon { RowIcon(icon) }
            Text(label).font(.reading).foregroundStyle(Color.jText)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text(value)
                    .font(.scaled(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(warns ? Color.jLive : Color.jText2)
                    .lineLimit(1)
                switch accessory {
                case .chevron:
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.jText4)
                case .outside:
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.jText4)
                case .none:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: icon == nil ? 52 : 56)
        .contentShape(Rectangle())
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
            // Big enough to find a group by, quiet enough not to compete with the rows.
            Text(title)
                .font(.scaled(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(Color.jText2)
                .padding(.bottom, 2)
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
    /// Leaves jotto for the browser: an arrow out instead of the chevron.
    var opensOutside = false
    /// The value is something to fix (location not allowed).
    var warns = false

    init(_ label: String, value: String = "", chevron: Bool = true, opensOutside: Bool = false, warns: Bool = false) {
        self.label = label
        self.value = value
        self.chevron = chevron
        self.opensOutside = opensOutside
        self.warns = warns
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.reading).foregroundStyle(Color.jText)
            Spacer(minLength: 12)
            Text(value)
                .font(.scaled(15, .medium, relativeTo: .subheadline))
                .foregroundStyle(warns ? Color.jLive : Color.jText2)
                .lineLimit(1)
            if chevron {
                Image(systemName: opensOutside ? "arrow.up.right" : "chevron.right")
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
        .card()
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
