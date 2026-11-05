import AVFoundation
import SwiftUI
import UIKit

// MARK: - Share

/// Dark sheet with a light paper preview of the Markdown that gets shared.
struct ShareSheet: View {
    let detail: SessionDetail
    let title: String

    enum Version { case clean, original }

    @Environment(\.dismiss) private var dismiss
    @State private var version = Version.clean
    @State private var withAudio = false
    @State private var audioFile: URL?
    @State private var exporting = false
    @State private var copied = false
    @State private var presenting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Share").font(.sheetTitle).tracking(-0.48).foregroundStyle(Color.ink50)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink50)
                        .frame(width: 36, height: 36)
                        .background(Color.ink700.opacity(0.6), in: Circle())
                }
                .accessibilityLabel("Close")
            }

            HStack(spacing: 8) {
                option("Clean", on: version == .clean) { version = .clean }
                option("Original", on: version == .original) { version = .original }
                option("+ Audio", on: withAudio) { withAudio.toggle() }
            }

            ScrollView {
                Text(markdown)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.inkPaperText)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .background(Color.inkPaper, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = markdown
                    copied = true
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .font(.label)
                        .foregroundStyle(Color.ink50)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.ink700.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)

                Button { presenting = true } label: {
                    Text(exporting ? "Preparing audio" : "Share…")
                        .font(.label)
                        .foregroundStyle(Color.ink950)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.ink50, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(exporting)
            }
        }
        .padding(24)
        .presentationDetents([.large])
        .presentationCornerRadius(40)
        .presentationBackground(Color.ink950)
        .preferredColorScheme(.dark)
        .task(id: withAudio) { if withAudio { await exportAudio() } }
        .sheet(isPresented: $presenting) {
            ActivityView(items: shareItems).presentationDetents([.medium, .large])
        }
    }

    private func option(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.label)
                .foregroundStyle(on ? Color.ink950 : Color.ink400)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(on ? Color.ink50 : Color.ink900, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : Color.ink700, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var shareItems: [Any] {
        var items: [Any] = [markdown]
        if withAudio, let audioFile { items.append(audioFile) }
        return items
    }

    var markdown: String {
        var out = "# \(title)\n\n"
        var meta = [Format.weekdayDayMonth(detail.startedAt), Format.time(detail.startedAt)]
        if let end = detail.endedAt { meta.append(Format.length(end.timeIntervalSince(detail.startedAt))) }
        out += "_\(meta.joined(separator: " · "))_\n\n"
        if version == .clean, let summary = detail.summary { out += "> \(summary)\n\n" }
        var previous: TranscriptBlock?
        for block in detail.blocks where version == .original || block.backchannel != true {
            let text = version == .clean ? (block.clean ?? block.text) : block.text
            if block.speaker != previous?.speaker || previous == nil {
                let who = block.speaker == nil ? "" : "**\(Format.speaker(block.speaker))** · "
                out += "\(who)\(Format.clock(block.start))\n"
            }
            out += "\(text)\n\n"
            previous = block
        }
        out += "—\nRecorded with Jotto\n"
        return out
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

// MARK: - Rename

struct RenameSheet: View {
    let detail: SessionDetail
    let current: String
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.label)
                    .foregroundStyle(Color.jText2)
                Spacer()
                Button("Done") {
                    let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty, title != current { save(title) }
                    dismiss()
                }
                .buttonStyle(PrimaryPillStyle())
            }
            .frame(height: 52)

            TextField("Title", text: $text, axis: .vertical)
                .font(.transcriptTitle)
                .tracking(-0.68)
                .foregroundStyle(Color.jText)
                .focused($focused)
                .submitLabel(.done)
                .padding(.top, 28)
                .padding(.bottom, 10)
            Rectangle().fill(Color.jText).frame(height: 1.5)

            let suggestions = ([detail.titleByUser == true ? nil : detail.title] + (detail.titleSuggestions ?? []).map { $0 })
                .compactMap { $0 }
            if !suggestions.isEmpty {
                Text("Jotto suggests")
                    .font(.speaker)
                    .foregroundStyle(Color.jText3)
                    .padding(.top, 32)
                FlowLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        let on = s == text
                        Button { text = s } label: {
                            Text(s)
                                .font(.summary)
                                .foregroundStyle(on ? Color.jBg : Color.jText)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(on ? Color.jText : Color.jFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 12)
            }

            Text("Written while the text was cleaned up, from what was said. Yours wins")
                .font(.summary)
                .foregroundStyle(Color.jText3)
                .padding(.top, 24)
            Spacer()
        }
        .padding(.horizontal, 20)
        .background(Color.jBg)
        .presentationDetents([.large])
        .onAppear {
            text = current
            focused = true
        }
    }
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
