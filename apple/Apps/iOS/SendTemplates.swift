import Observation
import SwiftUI

// MARK: - Model

/// What goes out when a recording is sent: an instruction for whoever
/// receives it (usually someone's own agent), then the transcript in the
/// chosen form. No model is involved; it's text put together (docs/06 §4).
struct SendTemplate: Codable, Identifiable, Hashable {
    enum Content: String, Codable, CaseIterable {
        case clean, original, highlights

        var label: String {
            switch self {
            case .clean: "Clean"
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
        var out = ""

        let instruction = template.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            out += "\(instruction)\n\n---\n\n"
        }

        out += md ? "# \(title)\n\n" : "\(title)\n"
        var meta = [Format.weekdayDayMonth(detail.startedAt), Format.time(detail.startedAt)]
        if let end = detail.endedAt { meta.append(Format.length(end.timeIntervalSince(detail.startedAt))) }
        out += md ? "_\(meta.joined(separator: " · "))_\n\n" : "\(meta.joined(separator: " · "))\n\n"

        if template.content != .original, let summary = detail.summary {
            out += md ? "> \(summary)\n\n" : "\(summary)\n\n"
        }

        switch template.content {
        case .clean, .original:
            out += paragraphs(detail.blocks, original: template.content == .original, markdown: md,
                              highlights: marksHighlights ? detail.highlights ?? [] : [])
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
                out += md ? "## \(heading)\n\n" : "\(heading)\n"
                out += paragraphs(spoken.filter(h.covers), original: false, markdown: md, times: false)
            }
        }

        out += md ? "—\nRecorded with Jotto\n" : "Recorded with Jotto\n"
        return out
    }

    private static func paragraphs(_ blocks: [TranscriptBlock], original: Bool, markdown md: Bool, times: Bool = true,
                                   highlights: [Highlight] = []) -> String {
        var out = ""
        var previous: TranscriptBlock?
        let shown = blocks.filter { original || $0.backchannel != true }
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

/// What goes out with a recording, and where it can go by itself.
/// Automations sit first: there will only ever be a few. Templates follow.
struct SendView: View {
    let router: Router
    private var templates: SendTemplates { .shared }
    @State private var editing: SendTemplate?

    var body: some View {
        // No large title: the tab bar already says Send.
        TabPage {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Automations", top: 16)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("When a transcript is ready").font(.rowTitle).foregroundStyle(Color.jText)
                        Spacer(minLength: 8)
                        Text("Coming soon")
                            .font(.scaled(12, .semibold, relativeTo: .caption1))
                            .foregroundStyle(Color.jText2)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Color.jFill, in: Capsule())
                    }
                    Text("Jotto posts a notice. A Shortcuts automation can pick it up and send the transcript to ChatGPT, Notes, Things or a webhook, with any template.")
                        .font(.summary)
                        .foregroundStyle(Color.jText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .card()

                sectionTitle("Templates", count: templates.all.count) { newTemplate }
                VStack(spacing: 10) {
                    ForEach(templates.all) { template in
                        Button { editing = template } label: { card(template) }
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

    /// Section titles here are headings, not labels: the page is two lists.
    /// The add button sits on the list it adds to.
    private func sectionTitle<Trailing: View>(_ text: String, count: Int? = nil, top: CGFloat = 36,
                                              @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text)
                    .font(.scaled(20, .semibold, relativeTo: .title3))
                    .tracking(-0.3)
                    .foregroundStyle(Color.jText)
                if let count {
                    Text("\(count)").font(.meta).foregroundStyle(Color.jText3)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 32)
        .padding(.top, top)
        .padding(.bottom, 12)
    }
    private func card(_ t: SendTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.name).font(.rowTitle).foregroundStyle(Color.jText)
                Spacer(minLength: 8)
                Text(t.summary).font(.metaSmall).foregroundStyle(Color.jText3)
            }
            Text(t.instruction.isEmpty ? "No instruction" : t.instruction)
                .font(.summary)
                .foregroundStyle(t.instruction.isEmpty ? Color.jText4 : Color.jText2)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(usage(t.id))
                .font(.metaSmall)
                .foregroundStyle(Color.jText4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }

    private func usage(_ id: UUID) -> String {
        guard let use = templates.uses[id], use.count > 0, let last = use.last else { return "Not used yet" }
        let calendar = Calendar.current
        let when: String
        if calendar.isDateInToday(last) {
            when = "today"
        } else if calendar.isDateInYesterday(last) {
            when = "yesterday"
        } else if let days = calendar.dateComponents([.day], from: last, to: .now).day, days < 7 {
            when = last.formatted(.dateTime.weekday(.wide))
        } else {
            when = last.formatted(.dateTime.day().month(.abbreviated))
        }
        return "Used \(Format.plural(use.count, "time")) · last \(when)"
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
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                Rectangle().fill(Color.jText).frame(height: 1.5)

                label("Instruction, at the top")
                TextField("Optional. For example: list every to-do, with who owns it.", text: $draft.instruction, axis: .vertical)
                    .font(.reading)
                    .lineSpacing(4)
                    .foregroundStyle(Color.jText)
                    .lineLimit(4...10)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.jSheetFill, in: RoundedRectangle(cornerRadius: 20))

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
                    .background(Color.jSheetWell, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.jSheetHairline, lineWidth: 1))

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
        }
        .scrollDismissesKeyboard(.interactively)
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
