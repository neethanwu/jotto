import Foundation
import UIKit

/// Does on the phone what the server used to: each segment from the watch
/// is transcribed as it arrives; when the recording ends and every part is
/// in, the text is cleaned up and given a title.
///
/// Runs whenever there is work: on arrival (the system wakes the app for
/// watch transfers), on launch and on coming to the foreground. Each step
/// asks for background time, so a locked phone keeps going for a while.
@MainActor
final class Pipeline {
    static let shared = Pipeline()

    private var store: LocalStore { .shared }
    private var running = false
    /// Titles that failed this run (rate limit, refusal); retried next run.
    private var describeFailed: Set<String> = []
    /// Transcription can't run yet (model not downloaded); retried next run.
    private var transcriberNotReady = false

    /// Give up on segments that haven't arrived this long after the end.
    private static let missingTimeout: TimeInterval = 30 * 60

    // MARK: - From the watch

    func started(_ id: String, at startedAt: Date) {
        store.update(id, startedAt: startedAt) { _ in }
        changed()
    }

    /// The audio is already at `Uploader.audioURL(session:index:)`.
    func segmentArrived(_ id: String, startedAt: Date, index: Int, offset: Double, duration: Double) {
        store.update(id, startedAt: startedAt) { r in
            if r.segments[index] == nil {
                r.segments[index] = LocalSegment(index: index, offset: offset, duration: duration)
            }
        }
        changed()
        run()
    }

    func finished(_ id: String, startedAt: Date, endedAt: Date, segmentCount: Int) {
        store.update(id, startedAt: startedAt) { r in
            r.endedAt = endedAt
            r.segmentCount = segmentCount
        }
        changed()
        run()
    }

    func marked(_ id: String, startedAt: Date, offset: Double) {
        store.update(id, startedAt: startedAt) { r in
            if !r.marks.contains(offset) { r.marks.append(offset) }
        }
    }

    // MARK: - Work

    /// Starts working through everything outstanding, unless already running.
    func run() {
        guard !running else {
            // Something changed mid-run (came to the front, model ready): go again after.
            rerun = true
            return
        }
        running = true
        Task {
            repeat {
                rerun = false
                describeFailed = []
                transcriberNotReady = false
                await prepareIfNeeded()
                while let step = nextStep() {
                    await perform(step)
                }
            } while rerun
            running = false
        }
    }

    private var rerun = false

    private var prepared = false

    /// The language model download needs the app in front; try once per launch.
    private func prepareIfNeeded() async {
        guard !prepared, UIApplication.shared.applicationState == .active else { return }
        prepared = true
        await OnDeviceTranscriber.shared.prepare()
    }

    private enum Step {
        case transcribe(id: String, index: Int)
        case polish(id: String)
        case describe(id: String)
    }

    private func nextStep() -> Step? {
        let all = store.recordings.values.sorted { $0.startedAt < $1.startedAt }
        // Oldest untranscribed segment first.
        for r in all where !transcriberNotReady {
            if let s = r.segments.values.filter({ $0.phrases == nil && $0.failed == nil }).min(by: { $0.index < $1.index }) {
                return .transcribe(id: r.id, index: s.index)
            }
        }
        // Not while segments wait for the model: they'd be polished as missing.
        for r in all where r.polishedAt == nil && r.isEnded
            && !r.segments.values.contains(where: { $0.phrases == nil && $0.failed == nil }) {
            if r.allTranscribed || giveUpOnMissing(r) { return .polish(id: r.id) }
        }
        // Titles: the on-device model is rate-limited in the background.
        if Describer.isAvailable, UIApplication.shared.applicationState != .background {
            for r in all where r.polishedAt != nil && r.describedAt == nil && !r.titleByUser && !describeFailed.contains(r.id) {
                return .describe(id: r.id)
            }
        }
        return nil
    }

    private func giveUpOnMissing(_ r: LocalRecording) -> Bool {
        guard let ended = r.endedAt, let count = r.segmentCount,
              Date.now.timeIntervalSince(ended) > Self.missingTimeout else { return false }
        let have = r.segments.count
        if have < count {
            store.update(r.id, startedAt: r.startedAt) { $0.missing = count - have }
        }
        return true
    }

    private func perform(_ step: Step) async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "jotto.pipeline")
        defer { UIApplication.shared.endBackgroundTask(task) }

        switch step {
        case let .transcribe(id, index):
            guard let r = store.recordings[id] else { return }
            let url = Uploader.audioURL(session: id, index: index)
            let began = Date.now
            do {
                let phrases = try await OnDeviceTranscriber.shared.transcribe(url)
                store.update(id, startedAt: r.startedAt) { $0.segments[index]?.phrases = phrases }
                PhoneLog.shared.note("asr_done", "segment \(index) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s phrases=\(phrases.count)")
            } catch OnDeviceTranscriber.Failure.notReady(let why) {
                transcriberNotReady = true
                PhoneLog.shared.note("asr_not_ready", why)
            } catch {
                store.update(id, startedAt: r.startedAt) { $0.segments[index]?.failed = error.localizedDescription }
                PhoneLog.shared.note("asr_failed", "segment \(index) \(error.localizedDescription)")
            }

        case let .polish(id):
            guard let r = store.recordings[id] else { return }
            var clean: [String: String] = [:]
            for b in LocalStore.blocks(r) where !b.backchannel {
                clean[b.text] = Cleanup.clean(b.text)
            }
            store.update(id, startedAt: r.startedAt) {
                $0.clean = clean
                $0.polishedAt = .now
            }
            PhoneLog.shared.note("polished", id)

        case let .describe(id):
            guard let r = store.recordings[id] else { return }
            let paragraphs = LocalStore.blocks(r).filter { !$0.backchannel }.map { r.clean[$0.text] ?? $0.text }
            guard !paragraphs.joined().isEmpty else {
                store.update(id, startedAt: r.startedAt) { $0.describedAt = .now }
                return
            }
            do {
                let d = try await Describer.describe(paragraphs)
                store.update(id, startedAt: r.startedAt) {
                    if !$0.titleByUser { $0.title = d.title }
                    $0.titleSuggestions = d.suggestions
                    $0.summary = d.summary
                    $0.describedAt = .now
                }
            } catch {
                // Rate-limited or refused: try again next time we're in front.
                describeFailed.insert(id)
                PhoneLog.shared.note("describe_failed", error.localizedDescription)
                return
            }
        }
        changed()
    }

    private func changed() {
        Task { await Library.shared.refresh() }
    }
}

#if DEBUG
import AVFoundation

extension Pipeline {
    /// Simulator: feeds a folder of .m4a files through as if the watch sent
    /// them. `SIMCTL_CHILD_JOTTO_SIMULATE_RECORDING=/path/to/dir xcrun simctl launch …`
    func simulateRecordingIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["JOTTO_SIMULATE_RECORDING"] else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".m4a") }.sorted()
        let id = UUID().uuidString.lowercased()
        let startedAt = Date.now.addingTimeInterval(-Double(files.count) * 120)
        started(id, at: startedAt)
        var offset = 0.0
        for (index, name) in files.enumerated() {
            let source = URL(fileURLWithPath: dir).appending(path: name)
            let destination = Uploader.audioURL(session: id, index: index)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source, to: destination)
            let duration = (try? AVAudioFile(forReading: destination)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 120
            segmentArrived(id, startedAt: startedAt, index: index, offset: offset, duration: duration)
            offset += duration
        }
        finished(id, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(offset), segmentCount: files.count)
    }
}
#endif
