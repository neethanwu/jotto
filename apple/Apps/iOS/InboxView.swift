import AVFoundation
import SwiftUI

/// Spike 0 phone UI: lists what arrived from the watch, plays clips,
/// and exports everything for the Spike 1 transcription bake-off.
struct InboxView: View {
    let inbox: Inbox
    @State private var player: AVAudioPlayer?
    @State private var playing: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Watch", value: inbox.watchStatus)
                    LabeledContent("Audio segments", value: "\(inbox.items.filter(\.isAudio).count)")
                }

                Section("Received") {
                    ForEach(inbox.items) { item in
                        row(item)
                    }
                    .onDelete { offsets in
                        offsets.map { inbox.items[$0] }.forEach(inbox.delete)
                    }
                }
            }
            .navigationTitle("Jotto · Spike 0")
            .refreshable { inbox.reload() }
            .toolbar {
                if !inbox.items.isEmpty {
                    ShareLink(items: inbox.items.map(\.url)) {
                        Label("Export all", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Inbox.Item) -> some View {
        if item.isAudio {
            Button {
                toggle(item.url)
            } label: {
                HStack {
                    Image(systemName: playing == item.url ? "stop.circle.fill" : "play.circle")
                    Text(item.url.lastPathComponent)
                    Spacer()
                    Text(item.size.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            NavigationLink(item.url.lastPathComponent) {
                ScrollView {
                    Text((try? String(contentsOf: item.url, encoding: .utf8)) ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding()
                }
                .toolbar { ShareLink(item: item.url) }
            }
        }
    }

    private func toggle(_ url: URL) {
        if playing == url {
            player?.stop()
            playing = nil
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        playing = url
    }
}
