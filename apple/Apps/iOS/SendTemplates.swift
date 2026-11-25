import Observation
import SwiftUI

// MARK: - Model

/// What goes out when a recording is sent: an instruction for whoever
/// receives it (usually someone's own agent), then the transcript in the
/// chosen form. No model is involved; it's text put together.
struct SendTemplate: Codable, Identifiable, Hashable {
    enum Content: String, Codable, CaseIterable {
        case clean, original, highlights

        var label: String {
            switch self {
            case .clean: "Formatted"
            case .original: "Original"
            case .highlights: "Highlights"
            }
        }
    }

    enum Format: String, Codable, CaseIterable {
        case markdown, text

        var label: String { self == .markdown ? "Markdown" : "Plain text" }
        var short: String { self == .markdown ? ".md" : "text" }
    }

    var id = UUID()
    var name: String
    var instruction: String
    var content: Content
    var format: Format
    /// Where it was said goes with it (the Send panel's Add the place,
    /// kept per template). Nil, as in templates saved before places, is on.
    var addsPlace: Bool?

    var placeOn: Bool { addsPlace ?? true }
    var summary: String { "\(content.label) · \(format.short)" }
}

@MainActor @Observable
final class SendTemplates {
    static let shared = SendTemplates()

    private(set) var all: [SendTemplate]
    /// The one picked last in the share sheet, picked again next time.
    var lastUsed: UUID? {
        didSet { UserDefaults.standard.set(lastUsed?.uuidString, forKey: Self.lastKey) }
    }

    private static let key = "sendTemplates"
    private static let lastKey = "sendTemplates.lastUsed"
    private static let usesKey = "sendTemplates.uses"

    struct Use: Codable {
        var count = 0
        var last: Date?
    }

    /// How often each template was copied or sent, for its card.
    private(set) var uses: [UUID: Use]

    func recordUse(_ id: UUID) {
        var use = uses[id] ?? Use()
        use.count += 1
        use.last = .now
        uses[id] = use
        UserDefaults.standard.set(try? JSONEncoder().encode(uses), forKey: Self.usesKey)
    }

    static let builtIn: [SendTemplate] = [
        SendTemplate(name: "Just the transcript", instruction: "", content: .clean, format: .markdown),
        SendTemplate(name: "Original, word for word", instruction: "", content: .original, format: .markdown),
        SendTemplate(
            name: "To-dos for my agent",
            instruction: "List every to-do in this conversation, with who owns it and when it is due. Reply as a checklist.",
            content: .clean, format: .markdown
        ),
        SendTemplate(
            name: "Highlights as notes",
            instruction: "Turn each highlight into a short note. Keep the exact quote under it.",
            content: .highlights, format: .text
        ),
    ]

    private init() {
        let defaults = UserDefaults.standard
        all = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SendTemplate].self, from: $0) } ?? Self.builtIn
        lastUsed = defaults.string(forKey: Self.lastKey).flatMap(UUID.init(uuidString:))
        uses = defaults.data(forKey: Self.usesKey).flatMap { try? JSONDecoder().decode([UUID: Use].self, from: $0) } ?? [:]
    }

    /// The share sheet's starting choice.
    var preferred: SendTemplate {
        all.first { $0.id == lastUsed } ?? all.first ?? Self.builtIn[0]
    }

    func save(_ template: SendTemplate) {
        if let i = all.firstIndex(where: { $0.id == template.id }) {
            all[i] = template
        } else {
            all.append(template)
        }
        persist()
    }

    /// The last one stays: sharing always needs a template.
    func delete(_ id: UUID) {
        guard all.count > 1 else { return }
        all.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.key)
    }
}

// MARK: - Putting it together

enum Composer {
    /// `marksHighlights`: in Clean and Original, the marked stretches are
    /// quoted, each under its star or [ ] and time, so whoever reads it
    /// (a person or an agent) sees what was marked.
    static func compose(_ detail: SessionDetail, title: String, with template: SendTemplate, marksHighlights: Bool = true) -> String {
        let md = template.format == .markdown
        var out = instruction(template)
        out += md ? "# \(title)\n\n" : "\(title)\n"
        out += body(detail, with: template, marksHighlights: marksHighlights, headings: 2)
        out += md ? "—\nRecorded with jotto\n" : "Recorded with jotto\n"
        return out
    }

    /// A whole day: the instruction once, then each recording in order,
    /// under its time and title.
    static func composeDay(_ details: [(detail: SessionDetail, title: String)], day: Date, with template: SendTemplate,
                           marksHighlights: Bool = true) -> String {
        let md = template.format == .markdown
        var out = instruction(template)
        let heading = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        out += md ? "# \(heading)\n\n" : "\(heading)\n"
        let total = details.compactMap { d in d.detail.endedAt.map { $0.timeIntervalSince(d.detail.startedAt) } }.reduce(0, +)
        let meta = [Format.plural(details.count, "recording"), total > 0 ? Format.length(total) : nil].compactMap { $0 }
            .joined(separator: " · ")
        out += md ? "_\(meta)_\n\n" : "\(meta)\n\n"
        for (detail, title) in details.sorted(by: { $0.detail.startedAt < $1.detail.startedAt }) {
            let name = "\(Format.time(detail.startedAt)) · \(title)"
            out += md ? "## \(name)\n\n" : "\(name)\n"
            out += body(detail, with: template, marksHighlights: marksHighlights, headings: 3, showsTime: false)
        }
        out += md ? "—\nRecorded with jotto\n" : "Recorded with jotto\n"
        return out
    }

    private static func instruction(_ template: SendTemplate) -> String {
        let instruction = template.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return instruction.isEmpty ? "" : "\(instruction)\n\n---\n\n"
    }

    /// One recording under its title: when and how long, the summary, then
    /// what the template asks for. Highlights get headings at `headings`.
    private static func body(_ detail: SessionDetail, with template: SendTemplate, marksHighlights: Bool,
                             headings: Int, showsTime: Bool = true) -> String {
        let md = template.format == .markdown
        var out = ""
        var meta = showsTime ? [Format.weekdayDayMonth(detail.startedAt), Format.time(detail.startedAt)] : []
        if let end = detail.endedAt { meta.append(Format.length(end.timeIntervalSince(detail.startedAt))) }
        if !meta.isEmpty {
            out += md ? "_\(meta.joined(separator: " · "))_\n\n" : "\(meta.joined(separator: " · "))\n\n"
        }
        let marks = template.placeOn ? detail.places ?? [] : []
        if let place = placeLine(marks) {
            out += md ? "_\(place)_\n\n" : "\(place)\n\n"
        }

        if template.content != .original, let summary = detail.summary {
            out += md ? "> \(summary)\n\n" : "\(summary)\n\n"
        }

        switch template.content {
        case .clean, .original:
            out += paragraphs(detail.blocks, original: template.content == .original, markdown: md,
                              highlights: marksHighlights ? detail.highlights ?? [] : [], marks: marks)
        case .highlights:
            let highlights = detail.highlights ?? []
            if highlights.isEmpty {
                out += "No highlights were marked in this recording.\n\n"
            }
            let spoken = detail.blocks.filter { $0.backchannel != true }
            for h in highlights {
                let heading = h.isSection
                    ? "[ ] \(Format.clock(h.start)) – \(Format.clock(h.end))"
                    : "★ \(Format.clock(h.at))"
                out += md ? "\(String(repeating: "#", count: headings)) \(heading)\n\n" : "\(heading)\n"
                out += paragraphs(spoken.filter(h.covers), original: false, markdown: md, times: false)
            }
        }
        return out
    }

    /// "At Lumen Café, San Francisco", or "From Lumen Café to Willow Park".
    static func placeLine(_ marks: [PlaceMark]) -> String? {
        guard let route = Places.route(marks), let start = marks.first(where: { $0.name != nil }) else { return nil }
        if let end = route.end { return "From \(route.start) to \(end)" }
        return "At \(Places.fullName(start) ?? route.start)"
    }

    private static func paragraphs(_ blocks: [TranscriptBlock], original: Bool, markdown md: Bool, times: Bool = true,
                                   highlights: [Highlight] = [], marks: [PlaceMark] = []) -> String {
        var out = ""
        var previous: TranscriptBlock?
        let shown = blocks.filter { original || $0.backchannel != true }
        let moves = Places.changes(shown, marks: marks)
        // Each highlight is labelled at the first paragraph it covers.
        let starts = Dictionary(grouping: highlights) { h in shown.first { h.covers($0) }?.id ?? -1 }
        for block in shown {
            var text = original ? block.text : (block.clean ?? block.text)
            if highlights.contains(where: { $0.covers(block) }) {
                let labels = (starts[block.id] ?? []).map { h in
                    let label = h.isSection
                        ? "[ ] \(Format.clock(h.start)) – \(Format.clock(h.end)) · Section"
                        : "★ \(Format.clock(h.at)) · Moment"
                    return md ? "> **\(label)**\n" : "> \(label)\n"
                }
                text = labels.joined() + "> " + text
            }
            if let name = moves[block.id]?.name {
                out += md ? "_At \(name)_\n\n" : "At \(name)\n\n"
            }
            let newSpeaker = previous == nil || block.speaker != previous?.speaker
            if newSpeaker {
                var head: [String] = []
                if block.speaker != nil { head.append(md ? "**\(Format.speaker(block.speaker))**" : Format.speaker(block.speaker)) }
                if times { head.append(Format.clock(block.start)) }
                if !head.isEmpty { out += head.joined(separator: " · ") + "\n" }
            }
            out += "\(text)\n\n"
            previous = block
        }
        return out
    }
}

// MARK: - The Send tab

/// What goes out with a recording: the templates are the page. Sending
/// by itself is one row on top, set up on its own page.
struct SendView: View {
    let router: Router
    private var templates: SendTemplates { .shared }
    @State private var editing: SendTemplate?

    var body: some View {
        // No large title: the tab bar already says Send.
        TabPage {
            VStack(alignment: .leading, spacing: 0) {
                NavigationLink(value: Route.sendAutomatically) {
                    HStack(spacing: 12) {
                        // A plain line icon, like every row in Settings.
                        RowIcon("paperplane")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Send automatically").font(.reading).foregroundStyle(Color.jText)
                            Text("With the Shortcuts app")
                                .font(.scaled(13, .regular, relativeTo: .footnote))
                                .foregroundStyle(Color.jText3)
                        }
                        Spacer(minLength: 8)
                        Text("Set up")
                            .font(.scaled(15, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Color.jText2)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.jText4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                    .card()
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Templates")
                                .font(.scaled(20, .semibold, relativeTo: .title3))
                                .tracking(-0.3)
                                .foregroundStyle(Color.jText)
                            Text("\(templates.all.count)").font(.meta).foregroundStyle(Color.jText3)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        Text("Pick one each time you send.")
                            .font(.scaled(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(Color.jText3)
                    }
                    Spacer(minLength: 8)
                    newTemplate
                }
                .padding(.top, 28)
                .padding(.bottom, 12)

                CardGroup {
                    ForEach(templates.all) { template in
                        Button { editing = template } label: { row(template) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 140)
        }
        .sheet(item: $editing) { TemplateEditor(template: $0) }
    }

    /// "+ New" on the Templates heading: a filled capsule, quieter than
    /// a button with a ring, and says what it makes.
    private var newTemplate: some View {
        Button {
            editing = SendTemplate(name: "", instruction: "", content: .clean, format: .markdown)
        } label: {
            HStack(spacing: 5) {
                GlyphView(glyph: .plus, color: .jText)
                    .frame(width: 13, height: 13)
                Text("New")
                    .font(.scaled(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText)
            }
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .frame(height: 32)
            .background(Color.jFill, in: Capsule())
            .contentShape(Capsule().inset(by: -6))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("New template")
    }

    /// Name, the first line of its instruction, then what it sends.
    private func row(_ t: SendTemplate) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name).font(.reading).foregroundStyle(Color.jText)
                if !t.instruction.isEmpty {
                    Text(t.instruction)
                        .font(.scaled(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Color.jText2)
                        .lineLimit(1)
                }
                Text([t.summary, usage(t.id)].compactMap { $0 }.joined(separator: " · "))
                    .font(.scaled(12, .medium, relativeTo: .caption1))
                    .foregroundStyle(Color.jText3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.jText4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func usage(_ id: UUID) -> String? {
        guard let use = templates.uses[id], use.count > 0 else { return nil }
        return "used \(Format.plural(use.count, "time"))"
    }
}

/// Send → Send automatically: the two things to do, then a picture of
/// the shortcut they make. The shortcut starts from Notify when ready.
struct SendAutomaticallyPage: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var config: AppConfig = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Send automatically", detail: "When a transcript is ready, a shortcut sends it on. Nothing to tap.") { dismiss() }

                CardSectionTitle("Two steps").padding(.top, 28)
                VStack(spacing: 0) {
                    step(done: config.notifiesWhenReady, number: 1,
                         title: "Notify when ready", detail: "The shortcut starts from it") {
                        if config.notifiesWhenReady {
                            Text("On")
                                .font(.scaled(15, .medium, relativeTo: .subheadline))
                                .foregroundStyle(Color.jText2)
                        } else {
                            pill("Turn on") {
                                config.notifiesWhenReady = true
                                Task { await Notifier.shared.askIfNeeded(fromSwitch: true) }
                            }
                        }
                    }
                    Rectangle().fill(Color.jHairline).frame(height: 1).padding(.leading, 52)
                    step(done: false, number: 2,
                         title: "Make the automation", detail: "In Shortcuts, under Automation") {
                        pill("Open", outside: true) {
                            if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                        }
                    }
                }
                .card()

                VStack(spacing: 0) {
                    HStack {
                        Text("What you\u{2019}ll build")
                            .font(.scaled(13, .medium, relativeTo: .footnote))
                            .foregroundStyle(Color.jText2)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    FlowSteps(steps: [
                        .init(icon: .app, label: "Notifies", value: "jotto"),
                        .init(icon: .symbol("doc.text"), label: "Formats with", value: "A template"),
                        .init(icon: .symbol("paperplane"), label: "Sends to", value: "Files or Mail"),
                    ])
                    .padding(.vertical, 18)
                }
                .card()
                .padding(.top, 28)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func step(done: Bool, number: Int, title: String, detail: String,
                      @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if done {
                    Circle().fill(Color.jText)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.jBg)
                } else {
                    Circle().strokeBorder(Color.jText5, lineWidth: 1.5)
                    Text("\(number)")
                        .font(.scaled(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Color.jText2)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.reading).foregroundStyle(Color.jText)
                Text(detail)
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func pill(_ title: String, outside: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.scaled(14, .semibold, relativeTo: .subheadline))
                if outside { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(Color.jText)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(Color.jFill, in: Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Settings: one template

/// A sheet like Rename: Cancel and Done on top, the name as a big field,
/// then the instruction, what to send, the format, and how it starts.
struct TemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SendTemplate
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    @FocusState private var instructionFocused: Bool
    private let isNew: Bool

    init(template: SendTemplate) {
        _draft = State(initialValue: template)
        isNew = !SendTemplates.shared.all.contains { $0.id == template.id }
    }

    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.jText5).frame(width: 36, height: 5).padding(.top, 10)
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.label)
                    .foregroundStyle(Color.jText2)
                Spacer()
                Button("Done") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    SendTemplates.shared.save(draft)
                    dismiss()
                }
                .buttonStyle(PrimaryPillStyle(height: 36))
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .padding(.top, 6)
            editorBody
        }
        .background(Color.jSheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(32)
        .presentationBackground(Color.jSheet)
        .sensoryFeedback(.selection, trigger: draft.content)
        .sensoryFeedback(.selection, trigger: draft.format)
        .confirmationDialog("Delete \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete template", role: .destructive) {
                SendTemplates.shared.delete(draft.id)
                dismiss()
            }
        }
        .onAppear { if isNew { nameFocused = true } }
    }

    private var editorBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Name", text: $draft.name, axis: .vertical)
                    .font(.transcriptTitle)
                    .tracking(-0.68)
                    .foregroundStyle(Color.jText)
                    .tint(Color.jLive)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    // Wraps when long, but Return means done with the name.
                    .onChange(of: draft.name) { _, text in
                        if text.contains("\n") {
                            draft.name = text.replacingOccurrences(of: "\n", with: "")
                            nameFocused = false
                        }
                    }
                    // Room for the clear button even when it's hidden, so the
                    // name never rewraps as it comes and goes.
                    .padding(.trailing, 32)
                    .overlay(alignment: .trailing) {
                        ClearButton(text: $draft.name, visible: nameFocused, label: "Clear name") { nameFocused = true }
                            .padding(.trailing, -4)
                    }
                    .animation(.easeOut(duration: 0.15), value: nameFocused && !draft.name.isEmpty)
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                Rectangle().fill(Color.jText).frame(height: 1.5)

                label("Instruction, at the top")
                TextField("Optional. For example: list every to-do, with who owns it.", text: $draft.instruction, axis: .vertical)
                    .font(.reading)
                    .lineSpacing(4)
                    .foregroundStyle(Color.jText)
                    .lineLimit(4...10)
                    .focused($instructionFocused)
                    .padding(.leading, 16)
                    .padding(.trailing, 40)
                    .padding(.vertical, 14)
                    .fieldBackground(.jSheetFill)
                    .overlay(alignment: .topTrailing) {
                        ClearButton(text: $draft.instruction, visible: instructionFocused, label: "Clear instruction") { instructionFocused = true }
                            .padding(.top, 4)
                            .padding(.trailing, 8)
                    }
                    .animation(.easeOut(duration: 0.15), value: instructionFocused && !draft.instruction.isEmpty)

                label("Send")
                HStack(spacing: 8) {
                    ForEach(SendTemplate.Content.allCases, id: \.self) { content in
                        chip(content.label, on: draft.content == content) { draft.content = content }
                    }
                }

                label("As")
                HStack(spacing: 8) {
                    ForEach(SendTemplate.Format.allCases, id: \.self) { format in
                        chip(format.label, on: draft.format == format) { draft.format = format }
                    }
                }

                label("Starts like this")
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.jText)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.jSheetWell, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.jSheetHairline, lineWidth: 1))

                if !isNew, SendTemplates.shared.all.count > 1 {
                    Button("Delete template", role: .destructive) { confirmDelete = true }
                        .font(.label)
                        .foregroundStyle(Color.jDestructive)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .keyboardFriendly()
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.scaled(11, .medium, relativeTo: .caption2))
            .foregroundStyle(Color.jText3)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.label)
                .foregroundStyle(on ? Color.jBg : Color.jText2)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(on ? Color.jText : Color.jSheetFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The first lines of what a send looks like, on a made-up recording.
    private var preview: String {
        let md = draft.format == .markdown
        var lines: [String] = []
        let instruction = draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty { lines += [instruction, "", "---", ""] }
        lines.append(md ? "# Coffee with Priya" : "Coffee with Priya")
        lines.append(md ? "_Thu 31 Oct · 08:30 · 46 min_" : "Thu 31 Oct · 08:30 · 46 min")
        lines.append("")
        switch draft.content {
        case .clean: lines.append(md ? "**You** · 0:00\nThanks for making time." : "You · 0:00\nThanks for making time.")
        case .original: lines.append(md ? "**You** · 0:00\nUm, thanks for, like, making time." : "You · 0:00\nUm, thanks for, like, making time.")
        case .highlights: lines.append(md ? "## ★ 0:52\n\nAnd who reads the feedback?" : "★ 0:52\nAnd who reads the feedback?")
        }
        lines.append("…")
        return lines.joined(separator: "\n")
    }
}
