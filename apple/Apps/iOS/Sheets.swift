import AVFoundation
import SwiftUI
import UIKit

// MARK: - Send

/// The drawer every Send opens (swipe on Days, the transcript, the long
/// press menu): pick a template, see how it starts, then copy it or hand
/// it to the system share sheet to choose the app.
struct SendPanel: View {
    /// One recording, or every one from a day (`day` set).
    let items: [(detail: SessionDetail, title: String)]
    var day: Date?

    init(detail: SessionDetail, title: String) {
        items = [(detail, title)]
    }

    init(day: Date, items: [(detail: SessionDetail, title: String)]) {
        self.day = day
        self.items = items
    }

    private var detail: SessionDetail { items[0].detail }
    private var title: String { items[0].title }
    private var highlightCount: Int { items.reduce(0) { $0 + ($1.detail.highlights?.count ?? 0) } }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDrawer) private var closeDrawer
    private var templates: SendTemplates { .shared }
    @State private var selectedID = SendTemplates.shared.preferred.id
    @State private var withAudio = false
    @State private var marksHighlights = true
    @State private var audioFile: URL?
    /// The place the file carries, so turning Add the place on or off makes it again.
    @State private var audioPlace: PlaceMark?
    @State private var exporting = false
    @State private var copied = false
    @State private var presenting = false
    @State private var editing: SendTemplate?
    @State private var listHeight: CGFloat = 0

    private var template: SendTemplate {
        templates.all.first { $0.id == selectedID } ?? templates.preferred
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day == nil ? "Send" : "Send the day")
                        .font(.sheetTitle)
                        .tracking(-0.48)
                        .foregroundStyle(Color.jText)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.meta)
                        .foregroundStyle(Color.jText3)
                        .lineLimit(1)
                }
                Spacer()
                CircleIconButton(glyph: .close, label: "Close", fill: .jSheetFill) {
                    if let closeDrawer { closeDrawer() } else { dismiss() }
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(templates.all) { row($0) }
                    Button {
                        editing = SendTemplate(name: "", instruction: "", content: .clean, format: .markdown)
                    } label: {
                        HStack(spacing: 12) {
                            GlyphView(glyph: .plus).frame(width: 16, height: 16).frame(width: 22)
                            Text("New template").font(.reading).foregroundStyle(Color.jText)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // As tall as the list, so the drawer fits it; scrolls past that.
            .frame(maxHeight: listHeight > 0 ? listHeight : nil)
            .scrollBounceBehavior(.basedOnSize)
            // Edge to edge, so the scroll bar runs down the drawer's edge
            // instead of over the rows' formats.
            .padding(.horizontal, -20)
            .padding(.top, 8)

            if highlightCount > 0, template.content != .highlights {
                Rectangle().fill(Color.jSheetHairline).frame(height: 1)
                Toggle(isOn: $marksHighlights) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mark the highlights").font(.rowTitle).foregroundStyle(Color.jText)
                        Text("\(Format.plural(highlightCount, "highlight")), quoted with ★ or [ ] and the time")
                            .font(.metaSmall).foregroundStyle(Color.jText3)
                    }
                }
                .toggleStyle(JottoToggleStyle())
                .padding(.vertical, 12)
            }

            if day == nil, !detail.segments.isEmpty {
                Rectangle().fill(Color.jSheetHairline).frame(height: 1)
                Toggle(isOn: $withAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Attach the audio").font(.rowTitle).foregroundStyle(Color.jText)
                        Text(audioDetail).font(.metaSmall).foregroundStyle(Color.jText3)
                    }
                }
                .toggleStyle(JottoToggleStyle())
                .padding(.vertical, 12)
            }

            if let placeDetail {
                Rectangle().fill(Color.jSheetHairline).frame(height: 1)
                Toggle(isOn: placeBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add the place").font(.rowTitle).foregroundStyle(Color.jText)
                        Text(placeDetail).font(.metaSmall).foregroundStyle(Color.jText3).lineLimit(1)
                    }
                }
                .toggleStyle(JottoToggleStyle())
                .padding(.vertical, 12)
            }

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = markdown
                    templates.recordUse(template.id)
                    copied = true
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .font(.label)
                        .foregroundStyle(Color.jText)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.jSheetFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(width: 140)

                Button {
                    templates.recordUse(template.id)
                    presenting = true
                } label: {
                    HStack(spacing: 8) {
                        GlyphView(glyph: .sendFilled, color: .jBg).frame(width: 18, height: 18)
                        Text(exporting ? "Preparing audio" : "Send…")
                    }
                    .font(.label)
                    .foregroundStyle(Color.jBg)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.jText, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(exporting)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .sensoryFeedback(.selection, trigger: selectedID)
        .task(id: [withAudio, template.placeOn]) { if withAudio { await exportAudio() } }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
        .onChange(of: templates.all.count) { old, new in
            // A template made from here is the one to send with.
            if new > old, let made = templates.all.last { select(made.id) }
        }
        .sheet(isPresented: $presenting) {
            ActivityView(items: shareItems).presentationDetents([.medium, .large])
        }
        .sheet(item: $editing) { TemplateEditor(template: $0) }
    }

    private var subtitle: String {
        if let day {
            let total = items.compactMap { i in i.detail.endedAt.map { $0.timeIntervalSince(i.detail.startedAt) } }.reduce(0, +)
            return [day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)), Format.plural(items.count, "recording"),
                    total > 0 ? Format.length(total) : nil].compactMap { $0 }.joined(separator: " · ")
        }
        let length = detail.endedAt.map { Format.length($0.timeIntervalSince(detail.startedAt)) }
        return [title, length].compactMap { $0 }.joined(separator: " · ")
    }

    private func select(_ id: UUID) {
        guard id != selectedID else { return }
        withAnimation(.snappy(duration: 0.2)) { selectedID = id }
        templates.lastUsed = id
    }

    /// Every row is the same shape whether picked or not: the check fills
    /// in, nothing grows or changes weight. The second line is what the
    /// template asks for, cut to one line.
    private func row(_ t: SendTemplate) -> some View {
        let on = t.id == selectedID
        let instruction = t.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button { select(t.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Color.jText5, lineWidth: 1.5).opacity(on ? 0 : 1)
                    Circle().fill(Color.jText).opacity(on ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.jBg)
                        .opacity(on ? 1 : 0)
                }
                .frame(width: 22, height: 22)
                .scaleEffect(on ? 1 : 0.92)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.name)
                            .font(.reading)
                            .foregroundStyle(Color.jText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(t.summary).font(.metaSmall).foregroundStyle(Color.jText3)
                    }
                    Text(instruction.isEmpty ? "No instruction" : instruction.replacingOccurrences(of: "\n", with: " "))
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Color.jSheetHairline).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Kept with the template picked, so a template for notes can always
    /// say where and one for an agent never does.
    private var placeBinding: Binding<Bool> {
        Binding(get: { template.placeOn }, set: { on in
            var changed = template
            changed.addsPlace = on
            templates.save(changed)
        })
    }

    /// Nil when none of it has a place, and the switch isn't shown.
    private var placeDetail: String? {
        let named = items.compactMap { Places.route($0.detail.places) }
        guard let first = named.first else { return nil }
        if day != nil { return "Where each one was said, over its text" }
        return withAudio ? "\(first.start), in the text and the audio" : "\(first.start), at the top of the text"
    }

    private var audioDetail: String {
        if exporting { return "Preparing the file" }
        let length = detail.endedAt.map { Format.length($0.timeIntervalSince(detail.startedAt)) }
        return [length, "as one m4a file"].compactMap { $0 }.joined(separator: ", ")
    }

    private var shareItems: [Any] {
        var items: [Any] = [markdown]
        if withAudio, let audioFile { items.append(audioFile) }
        return items
    }

    var markdown: String {
        if let day {
            return Composer.composeDay(items, day: day, with: template, marksHighlights: marksHighlights)
        }
        return Composer.compose(detail, title: title, with: template, marksHighlights: marksHighlights)
    }

    /// One m4a of the whole recording, built from its segments, carrying
    /// where it began when the place is added.
    private func exportAudio() async {
        let place = template.placeOn ? detail.places?.first : nil
        guard audioFile == nil || audioPlace != place else { return }
        audioFile = nil
        exporting = true
        defer { exporting = false }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        for segment in detail.segments.sorted(by: { $0.index < $1.index }) {
            guard let url = try? await API.audio(session: detail.id, index: segment.index) else { continue }
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration) else { continue }
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source,
                                       at: CMTime(seconds: segment.offset, preferredTimescale: 600))
        }
        guard composition.duration.seconds > 0,
              let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return }
        if let place {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = Places.iso6709(place) as NSString
            session.metadata = [item]
        }
        let safe = title.replacingOccurrences(of: "/", with: "-")
        let out = URL.temporaryDirectory.appending(path: "\(safe).m4a")
        try? FileManager.default.removeItem(at: out)
        do {
            try await session.export(to: out, as: .m4a)
            audioFile = out
            audioPlace = place
        } catch {
            withAudio = false
        }
    }
}

/// The system share sheet, for text plus an optional audio file.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([i], size.width, size.height)
            } else {
                current = (current.items + [i], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
