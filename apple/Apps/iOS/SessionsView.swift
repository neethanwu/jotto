import SwiftUI

/// Home: every recording, newest first, with upload status on top.
struct SessionsView: View {
    let config: AppConfig
    let uploader: Uploader
    @State private var sessions: [SessionSummary] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if !uploader.jobs.isEmpty || uploader.lastError != nil {
                    Section {
                        uploadStatus
                    }
                }

                if !config.isReady {
                    ContentUnavailableView {
                        Label("Not connected to a server", systemImage: "server.rack")
                    } description: {
                        Text("Add the server address and token in Settings.")
                    } actions: {
                        NavigationLink("Settings") { SettingsView(config: config) }
                    }
                } else if sessions.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "waveform",
                        description: Text(error ?? "Start recording on your watch; transcripts show up here.")
                    )
                } else {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section(group.day.formatted(.dateTime.month().day().weekday())) {
                            ForEach(group.sessions) { session in
                                NavigationLink(value: session) { row(session) }
                            }
                            .onDelete { offsets in
                                let doomed = offsets.map { group.sessions[$0] }
                                Task { await delete(doomed) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Jotto")
            .navigationDestination(for: SessionSummary.self) { session in
                SessionDetailView(summary: session)
            }
            .toolbar {
                NavigationLink { SettingsView(config: config) } label: {
                    Image(systemName: "gearshape")
                }
            }
            .refreshable { await load() }
            .task {
                // Keep the list fresh while recordings are being processed.
                while !Task.isCancelled {
                    await load()
                    let busy = sessions.contains { $0.status != "ready" } || !uploader.jobs.isEmpty
                    try? await Task.sleep(for: .seconds(busy ? 5 : 30))
                }
            }
        }
    }

    private var uploadStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if uploader.jobs.isEmpty {
                Label("All uploaded", systemImage: "checkmark.circle")
            } else {
                Label("\(uploader.jobs.count) waiting to upload", systemImage: "arrow.up.circle")
            }
            if let message = uploader.lastError {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ session: SessionSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.headline)
                if let ended = session.endedAt {
                    Text(Duration.seconds(ended.timeIntervalSince(session.startedAt))
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusBadge(status: session.status)
        }
    }

    private var groupedByDay: [(day: Date, sessions: [SessionSummary])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    private func load() async {
        guard config.isReady else { return }
        do {
            sessions = try await API.sessions()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ doomed: [SessionSummary]) async {
        for session in doomed {
            try? await API.delete(session.id)
        }
        await load()
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        switch status {
        case "recording": Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
        case "processing": Label("Processing", systemImage: "hourglass").foregroundStyle(.orange)
        default: EmptyView()
        }
    }
}
