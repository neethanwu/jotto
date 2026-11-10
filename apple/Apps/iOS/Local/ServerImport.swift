import Foundation
import Observation
import UIKit

/// Copies finished recordings from the test server onto the phone, so the
/// server can be retired (docs/06, step 2). The server's transcript,
/// speakers, title and summary come as they are; audio comes only for
/// recordings still inside the "Keep audio" window. Recordings already on
/// the phone are left alone, so running it again picks up what's new.
@MainActor @Observable
final class ServerImport {
    static let shared = ServerImport()

    enum State: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(imported: Int, unfinished: Int, failed: Int)
        case failed(String)
    }

    private(set) var state = State.idle

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func start() {
        guard !isRunning else { return }
        state = .running(done: 0, total: 0)
        Task { await run() }
    }

    private func run() async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "jotto.import")
        defer { UIApplication.shared.endBackgroundTask(task) }
        PhoneLog.shared.note("import_begin")

        let list: [SessionSummary]
        do {
            list = try await API.serverSessions()
        } catch {
            state = .failed(error.localizedDescription)
            PhoneLog.shared.note("import_failed", error.localizedDescription)
            return
        }

        let store = LocalStore.shared
        let new = list.filter { store.recordings[$0.id] == nil }
        let ready = new.filter { $0.status == "ready" }
        let unfinished = new.count - ready.count
        var imported = 0, failed = 0
        state = .running(done: 0, total: ready.count)

        for summary in ready.sorted(by: { $0.startedAt > $1.startedAt }) {
            do {
                try await importOne(summary.id)
                imported += 1
            } catch {
                failed += 1
                PhoneLog.shared.note("import_one_failed", "\(summary.id) \(error.localizedDescription)")
            }
            state = .running(done: imported + failed, total: ready.count)
            // Newest first, and the list fills in as it goes.
            if (imported + failed) % 5 == 0 { await Library.shared.refresh() }
        }

        await Library.shared.refresh()
        state = .finished(imported: imported, unfinished: unfinished, failed: failed)
        PhoneLog.shared.note("import_end", "imported=\(imported) unfinished=\(unfinished) failed=\(failed)")
    }

    private func importOne(_ id: String) async throws {
        let detail = try await API.serverSession(id)
        let ended = detail.endedAt ?? detail.startedAt

        // Audio past the keep window would be purged straight away.
        let keepDays = AppConfig.shared.keepAudioDays
        let wantsAudio = keepDays == 0 || Date.now.timeIntervalSince(ended) < Double(keepDays) * 86_400
        if wantsAudio {
            for segment in detail.segments where segment.hasAudio {
                let url = Uploader.audioURL(session: id, index: segment.index)
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                // Missing audio isn't worth failing the recording over.
                guard let data = try? await API.serverAudio(session: id, index: segment.index) else { continue }
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
        }

        LocalStore.shared.update(id, startedAt: detail.startedAt) { r in
            r.endedAt = ended
            r.segmentCount = detail.segmentCount ?? detail.segments.count
            // Empty phrases mark every segment done, so the pipeline leaves it be.
            for s in detail.segments {
                r.segments[s.index] = LocalSegment(index: s.index, offset: s.offset, duration: s.duration, phrases: [])
            }
            r.missing = detail.missingSegments ?? 0
            r.imported = detail.blocks
            r.title = detail.title
            r.titleByUser = detail.titleByUser ?? false
            r.titleSuggestions = detail.titleSuggestions ?? []
            r.summary = detail.summary
            // Dated by when it ended, so "Keep audio" counts from then.
            r.polishedAt = ended
            r.describedAt = ended
        }
    }
}
