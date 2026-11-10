import AVFoundation
import SwiftUI
import UIKit

// MARK: - Send

/// The drawer every Send opens (swipe on Days, the transcript, the long
/// press menu): pick a template, see how it starts, then copy it or hand
/// it to the system share sheet to choose the app.
struct SendPanel: View {
    let detail: SessionDetail
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDrawer) private var closeDrawer
    private var templates: SendTemplates { .shared }
    @State private var selectedID = SendTemplates.shared.preferred.id
    @State private var withAudio = false
    @State private var audioFile: URL?
    @State private var exporting = false
    @State private var copied = false
    @State private var presenting = false
    @State private var editing: SendTemplate?

    private var template: SendTemplate {
        templates.all.first { $0.id == selectedID } ?? templates.preferred
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send")
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
                CircleIconButton(glyph: .close, label: "Close", fill: .jSheet) {
                    if let closeDrawer { closeDrawer() } else { dismiss() }
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(templates.all) { row($0) }
                        .animation(.spring(duration: 0.38, bounce: 0.08), value: selectedID)
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
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.top, 8)

            if !detail.segments.isEmpty {
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
                        GlyphView(glyph: .send, color: .jBg).frame(width: 18, height: 18)
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
        .task(id: withAudio) { if withAudio { await exportAudio() } }
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
        let length = detail.endedAt.map { Format.length($0.timeIntervalSince(detail.startedAt)) }
        return [title, length].compactMap { $0 }.joined(separator: " · ")
    }

    private func select(_ id: UUID) {
        guard id != selectedID else { return }
        withAnimation(.spring(duration: 0.38, bounce: 0.08)) { selectedID = id }
        templates.lastUsed = id
    }

    private func row(_ t: SendTemplate) -> some View {
        let on = t.id == selectedID
        return Button { select(t.id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().strokeBorder(Color.jText5, lineWidth: 1.5).opacity(on ? 0 : 1)
                        Circle().fill(Color.jText).opacity(on ? 1 : 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.jBg)
                            .opacity(on ? 1 : 0)
                    }
                    .frame(width: 22, height: 22)
                    Text(t.name)
                        .font(.scaled(17, on ? .semibold : .regular, relativeTo: .body))
                        .foregroundStyle(Color.jText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(t.summary).font(.metaSmall).foregroundStyle(Color.jText3)
                }
                if on {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.jText2)
                        .lineSpacing(2)
                        .lineLimit(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.jSheetWell, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.jSheetHairline, lineWidth: 1))
                        .padding(.leading, 34)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -8)).animation(.easeOut(duration: 0.25).delay(0.06)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        ))
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Color.jSheetHairline).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The first lines of what goes out with the chosen template.
    private var preview: String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.prefix(7).joined(separator: "\n")
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
        Composer.compose(detail, title: title, with: template)
    }

    /// One m4a of the whole recording, built from its segments.
    private func exportAudio() async {
        guard audioFile == nil else { return }
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
        let safe = title.replacingOccurrences(of: "/", with: "-")
        let out = URL.temporaryDirectory.appending(path: "\(safe).m4a")
        try? FileManager.default.removeItem(at: out)
        do {
            try await session.export(to: out, as: .m4a)
            audioFile = out
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
