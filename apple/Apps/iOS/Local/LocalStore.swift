import Foundation
import Observation

/// Every recording the phone processes itself, and the same read API the
/// server offers (`API`), so the screens don't care where the work happens.
@MainActor @Observable
final class LocalStore {
    static let shared = LocalStore()

    private(set) var recordings: [String: LocalRecording] = [:]

    nonisolated static let directory = URL.documentsDirectory.appending(path: "Recordings")

    private init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let r = try? decoder.decode(LocalRecording.self, from: data) {
                recordings[r.id] = r
            }
        }
    }

    // MARK: - Writing

    func update(_ id: String, startedAt: Date, _ change: (inout LocalRecording) -> Void) {
        var r = recordings[id] ?? LocalRecording(id: id, startedAt: startedAt)
        change(&r)
        recordings[id] = r
        save(r)
    }

    private func save(_ r: LocalRecording) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        // Readable after first unlock, so background work can use it while locked.
        try? data.write(to: Self.directory.appending(path: "\(r.id).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - The API the screens use

    func sessions() -> [SessionSummary] {
        recordings.values.sorted { $0.startedAt > $1.startedAt }.map { r in
            SessionSummary(
                id: r.id, startedAt: r.startedAt, endedAt: r.endedAt, status: r.status,
                title: r.title, summary: r.summary, segmentCount: r.segmentCount, missingSegments: r.missing,
                segmentsDone: r.transcribed.count, segmentsReceived: r.segments.count,
                lastLine: Self.transcript(r).last { $0.backchannel != true }?.text
            )
        }
    }

    func session(_ id: String) throws -> SessionDetail {
        guard let r = recordings[id] else { throw CocoaError(.fileNoSuchFile) }
        let segments = r.segments.values.sorted { $0.index < $1.index }.map { s in
            SessionDetail.Segment(
                index: s.index,
                status: s.phrases != nil ? "done" : s.failed != nil ? "failed" : "pending",
                offset: s.offset, duration: s.duration,
                hasAudio: FileManager.default.fileExists(atPath: Uploader.audioURL(session: id, index: s.index).path)
            )
        }
        let blocks = Self.transcript(r)
        return SessionDetail(
            id: r.id, status: r.status, startedAt: r.startedAt, endedAt: r.endedAt,
            title: r.title, titleByUser: r.titleByUser, titleSuggestions: r.titleSuggestions,
            summary: r.summary, segmentCount: r.segmentCount, missingSegments: r.missing,
            segments: segments, blocks: blocks
        )
    }

    func rename(_ id: String, to title: String) {
        guard let r = recordings[id] else { return }
        update(id, startedAt: r.startedAt) { $0.title = title; $0.titleByUser = true }
    }

    func delete(_ id: String) {
        recordings[id] = nil
        try? FileManager.default.removeItem(at: Self.directory.appending(path: "\(id).json"))
        try? FileManager.default.removeItem(at: Uploader.sessionsDirectory.appending(path: id))
    }

    /// Deletes the audio of recordings that were transcribed more than
    /// `days` ago. The text stays. 0 keeps everything.
    func purgeAudio(keepingDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        for r in recordings.values {
            guard let done = r.polishedAt, done < cutoff else { continue }
            let dir = Uploader.sessionsDirectory.appending(path: r.id)
            if FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    func search(_ query: String) -> SearchResults {
        var sessions: [SearchResults.Session] = []
        var matches = 0
        for r in recordings.values.sorted(by: { $0.startedAt > $1.startedAt }) {
            var hits: [SearchResults.Hit] = []
            for b in Self.transcript(r) where b.backchannel != true {
                let text = b.clean ?? b.text
                if text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    hits.append(.init(start: b.start, text: text))
                }
            }
            let titleHit = r.title?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            guard !hits.isEmpty || titleHit else { continue }
            matches += max(hits.count, 1)
            sessions.append(.init(id: r.id, title: r.title, startedAt: r.startedAt, endedAt: r.endedAt, hits: Array(hits.prefix(5))))
        }
        return SearchResults(query: query, matches: matches, sessions: sessions)
    }

    func stats() -> Stats {
        let lengths = recordings.values.compactMap { r in r.endedAt.map { ($0, $0.timeIntervalSince(r.startedAt)) } }
        let weekAgo = Date.now.addingTimeInterval(-7 * 86400)
        let recent = lengths.filter { $0.0 > weekAgo }
        return Stats(
            recordings: recordings.count,
            seconds: Int(lengths.map(\.1).reduce(0, +)),
            lastSevenDays: .init(recordings: recent.count, seconds: Int(recent.map(\.1).reduce(0, +))),
            audioRetentionDays: AppConfig.shared.keepAudioDays
        )
    }

    // MARK: - Paragraphs

    static func blocks(_ r: LocalRecording) -> [Paragraphs.Block] {
        Paragraphs.blocks(Paragraphs.stitch(r.transcribed))
    }

    /// What the screens show: the server's transcript for an imported
    /// recording, else the phone's own paragraphs with their clean text.
    static func transcript(_ r: LocalRecording) -> [TranscriptBlock] {
        if let imported = r.imported { return imported }
        return blocks(r).map { b in
            TranscriptBlock(
                id: b.id, section: b.section, speaker: nil, start: b.start, end: b.end, text: b.text,
                clean: b.backchannel ? b.text : r.clean[b.text], backchannel: b.backchannel
            )
        }
    }
}
