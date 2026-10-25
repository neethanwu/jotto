import SwiftUI

/// One recording's transcript. Clean (polished) by default, raw on demand.
struct SessionDetailView: View {
    let summary: SessionSummary
    @State private var detail: SessionDetail?
    @State private var showRaw = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let detail {
                    progress(detail)
                    ForEach(rows(detail)) { row in
                        rowView(row)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $showRaw) {
                    Text("Clean").tag(false)
                    Text("Original").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            if let detail {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: plainText(detail)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                do {
                    detail = try await API.session(summary.id)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                if detail?.status == "ready" { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Layout

    private struct Row: Identifiable {
        let id: Int
        let block: TranscriptBlock
        /// Show "Speaker N · time" above this paragraph.
        let showHeader: Bool
        /// Show a time divider before it (long silence).
        let newSection: Bool
    }

    private func rows(_ detail: SessionDetail) -> [Row] {
        let visible = detail.blocks.filter { showRaw || $0.backchannel != true }
        var rows: [Row] = []
        var previous: TranscriptBlock?
        for block in visible {
            let newSection = previous.map { $0.section != block.section } ?? false
            let showHeader = previous == nil || newSection || previous?.speaker != block.speaker
            rows.append(Row(id: block.id, block: block, showHeader: showHeader, newSection: newSection))
            previous = block
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        if row.newSection {
            HStack {
                VStack { Divider() }
                Text(timestamp(row.block.start)).font(.caption).foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .padding(.vertical, 6)
        }
        VStack(alignment: .leading, spacing: 4) {
            if row.showHeader {
                Text("\(speakerName(row.block.speaker)) · \(timestamp(row.block.start))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            let pending = !showRaw && row.block.clean == nil
            Text(showRaw ? row.block.text : (row.block.clean ?? row.block.text))
                .foregroundStyle(pending || row.block.backchannel == true ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func progress(_ detail: SessionDetail) -> some View {
        if detail.status != "ready" {
            let done = detail.segments.filter { $0.status == "done" || $0.status == "failed" }.count
            let total = detail.segmentCount.map(String.init) ?? "…"
            Label(
                detail.status == "recording" ? "Recording · \(done) parts transcribed" : "Processing · \(done)/\(total) parts transcribed",
                systemImage: "hourglass"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Text

    private func plainText(_ detail: SessionDetail) -> String {
        rows(detail).map { row in
            let text = showRaw ? row.block.text : (row.block.clean ?? row.block.text)
            return row.showHeader
                ? "\(speakerName(row.block.speaker)) \(timestamp(row.block.start))\n\(text)"
                : text
        }
        .joined(separator: "\n\n")
    }

    private func speakerName(_ label: String?) -> String {
        guard let label, let n = Int(label) else { return "Speaker" }
        return "Speaker \(n + 1)"
    }

    private func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
