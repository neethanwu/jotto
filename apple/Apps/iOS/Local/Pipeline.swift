import Foundation
import UIKit

/// Does on the phone what the server used to: each segment from the watch
/// is transcribed as it arrives; when the recording ends and every part is
/// in, the text is cleaned up and given a title.
///
/// Runs whenever there is work: on arrival (the system wakes the app for
/// watch transfers), on launch and on coming to the foreground. Each step
/// asks for background time, so a locked phone keeps going for a while.
@MainActor @Observable
final class Pipeline {
    static let shared = Pipeline()

    /// Why recordings are waiting rather than being transcribed, for the
    /// screens: the speech model is downloading, or can't be had.
    private(set) var waiting: String?

    @ObservationIgnored private var store: LocalStore { .shared }
    @ObservationIgnored private var running = false
    /// Titles that failed this run (rate limit, refusal); retried next run.
    @ObservationIgnored private var describeFailed: Set<String> = []
    /// Same for tidying the text.
    @ObservationIgnored private var tidyFailed: Set<String> = []
    /// Transcription can't run yet (model not downloaded); retried next run.
    @ObservationIgnored private var transcriberNotReady = false

    /// Give up on segments that haven't arrived this long after the end.
    private static let missingTimeout: TimeInterval = 30 * 60

    // MARK: - From the watch

    func started(_ id: String, at startedAt: Date) {
        store.update(id, startedAt: startedAt) { _ in }
        changed()
    }

    /// The audio is already at `AudioFiles.url(session:index:)`.
    func segmentArrived(_ id: String, startedAt: Date, index: Int, offset: Double, duration: Double) {
        store.update(id, startedAt: startedAt) { r in
            if r.segments[index] == nil {
                r.segments[index] = LocalSegment(index: index, offset: offset, duration: duration)
            }
        }
        changed()
        run()
    }

    // MARK: - From the phone's Live screen

    /// Sections started on the phone, by recording: seconds from the start.
    private(set) var openSections: [String: Double] = [:]
    /// Longest a section runs before it closes itself, as on the watch.
    static let sectionLimit: Double = 10 * 60

    func markNow(_ id: String, startedAt: Date) {
        marked(id, startedAt: startedAt, offset: Date.now.timeIntervalSince(startedAt))
        Inbox.shared.tellWatchMarked(id, section: false)
        changed()
    }

    func toggleSection(_ id: String, startedAt: Date) {
        let now = Date.now.timeIntervalSince(startedAt)
        if let start = openSections.removeValue(forKey: id) {
            markedSection(id, startedAt: startedAt, start: start, end: min(now, start + Self.sectionLimit))
            Inbox.shared.tellWatchMarked(id, section: true)
            changed()
        } else {
            openSections[id] = now
        }
    }

    func finished(_ id: String, startedAt: Date, endedAt: Date, segmentCount: Int) {
        if let start = openSections.removeValue(forKey: id) {
            markedSection(id, startedAt: startedAt, start: start, end: min(endedAt.timeIntervalSince(startedAt), start + Self.sectionLimit))
        }
        store.update(id, startedAt: startedAt) { r in
            r.endedAt = endedAt
            r.segmentCount = segmentCount
        }
        Inbox.shared.syncHistory()
        changed()
        run()
    }

    func marked(_ id: String, startedAt: Date, offset: Double) {
        store.update(id, startedAt: startedAt) { r in
            if !r.marks.contains(offset) { r.marks.append(offset) }
        }
    }

    func markedSection(_ id: String, startedAt: Date, start: Double, end: Double) {
        store.update(id, startedAt: startedAt) { r in
            let section = LocalRecording.MarkedSection(start: start, end: end)
            if !(r.sections ?? []).contains(section) { r.sections = (r.sections ?? []) + [section] }
        }
    }

    /// Everything after the watch, again: language, text, clean-up and
    /// title. For a recording heard in the wrong language.
    /// `language` nil: hear which one again, from Settings' languages.
    func redo(_ id: String, language: String? = nil) {
        guard let r = store.recordings[id], r.imported == nil else { return }
        if let language, language != LocalRecording.mixed, !SpeechModels.shared.isInstalled(language) { prepared = false }
        store.update(id, startedAt: r.startedAt) { r in
            for i in r.segments.keys { r.segments[i]?.phrases = nil; r.segments[i]?.failed = nil }
            r.locale = language
            r.clean = [:]
            r.tidy = nil
            r.tidiedAt = nil
            r.polishedAt = nil
            r.describedAt = nil
            r.notifiedAt = .now
            if !r.titleByUser { r.title = nil; r.summary = nil; r.titleSuggestions = [] }
        }
        describeFailed.remove(id)
        tidyFailed.remove(id)
        changed()
        run()
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
                tidyFailed = []
                transcriberNotReady = false
                await prepareIfNeeded()
                await redoSlowedRecordings()
                refreshLayouts()
                store.purgeAudio(keepingDays: AppConfig.shared.keepAudioDays)
                while let step = nextStep() {
                    await perform(step)
                }
            } while rerun
            running = false
        }
    }

    @ObservationIgnored private var rerun = false

    /// Recordings from the watch build that wrote slowed audio (see
    /// `AudioRepair`) came out with no text. Mend their audio and do them
    /// again. Once per install.
    private func redoSlowedRecordings() async {
        let key = "redidSlowedRecordings"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for r in store.recordings.values where r.imported == nil {
            var redo: [Int] = []
            for s in r.segments.values {
                let url = AudioFiles.url(session: r.id, index: s.index)
                let duration = s.duration
                let fixed = await Task.detached(priority: .utility) { AudioRepair.fix(url, expected: duration) }.value
                if fixed { redo.append(s.index) }
            }
            guard !redo.isEmpty else { continue }
            PhoneLog.shared.note("audio_repaired", "\(r.id) segments=\(redo)")
            store.update(r.id, startedAt: r.startedAt) { r in
                for i in redo { r.segments[i]?.phrases = nil; r.segments[i]?.failed = nil }
                r.clean = [:]
                r.tidy = nil
                r.tidiedAt = nil
                r.polishedAt = nil
                r.describedAt = nil
                r.notifiedAt = nil
                if !r.titleByUser { r.title = nil; r.summary = nil }
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        changed()
    }

    /// Paragraphs are laid out afresh from the sentences each time; when
    /// the rules change (as when paragraphs got shorter), ones without
    /// clean text get it now, and go through the model again.
    private func refreshLayouts() {
        let key = "layoutVersion"
        guard UserDefaults.standard.integer(forKey: key) < Self.layoutVersion else { return }
        for r in store.recordings.values where r.polishedAt != nil && r.imported == nil {
            let blocks = LocalStore.blocks(r).filter { !$0.backchannel }
            guard blocks.contains(where: { r.clean[$0.text] == nil }) else { continue }
            var clean = r.clean
            for b in blocks where clean[b.text] == nil { clean[b.text] = Cleanup.clean(b.text) }
            store.update(r.id, startedAt: r.startedAt) {
                $0.clean = clean
                $0.tidiedAt = nil
            }
        }
        UserDefaults.standard.set(Self.layoutVersion, forKey: key)
        changed()
    }

    /// Bump when `Paragraphs` lays text out differently.
    private static let layoutVersion = 3

    @ObservationIgnored private var prepared = false

    /// The transcription language changed: fetch its model, then retry
    /// anything that was waiting for it.
    func languageChanged() {
        prepared = false
        run()
    }

    /// The language model download needs the app in front; try once per launch.
    private func prepareIfNeeded() async {
        guard !prepared, UIApplication.shared.applicationState == .active else { return }
        prepared = true
        await AppConfig.shared.fillLanguagesIfNeeded()
        let models = SpeechModels.shared
        let wanted = AppConfig.shared.languages
        await models.refresh()
        if wanted.contains(where: { !models.isInstalled($0) }) { waiting = "Downloading the speech model" }
        await models.ensure(wanted)
        waiting = wanted.contains(where: models.failed.contains)
            ? "Couldn't download the speech model. Open Jotto on Wi-Fi to try again" : nil
    }

    private enum Step {
        case transcribe(id: String, index: Int)
        case polish(id: String)
        case describe(id: String)
        case tidy(id: String)
    }

    /// Whether the on-device model will tidy this recording's text.
    private func willTidy(_ r: LocalRecording) -> Bool {
        r.polishedAt != nil && r.tidiedAt == nil && r.imported == nil
            && Editor.isAvailable
    }

    /// Paragraphs tidied so far, for the transcript's status line.
    func tidyProgress(_ r: LocalRecording) -> SessionDetail.Tidying? {
        guard willTidy(r) else { return nil }
        let blocks = LocalStore.blocks(r).filter { !$0.backchannel }
        return .init(done: blocks.filter { r.tidy?[$0.text] != nil }.count, total: blocks.count)
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
        // Titles. The on-device model is rate-limited in the background:
        // one try there (so the notice can carry a title), the rest in front.
        if Describer.isAvailable {
            let inFront = UIApplication.shared.applicationState != .background
            for r in all where r.polishedAt != nil && r.describedAt == nil && !r.titleByUser
                && !describeFailed.contains(r.id) && (inFront || r.notifiedAt == nil) {
                return .describe(id: r.id)
            }
        }
        // Tidying, newest first (the one likely open), only in front.
        if UIApplication.shared.applicationState != .background {
            for r in all.reversed() where willTidy(r) && !tidyFailed.contains(r.id) {
                return .tidy(id: r.id)
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
            let url = AudioFiles.url(session: id, index: index)
            let began = Date.now
            if let expected = r.segments[index]?.duration {
                // From a watch that hasn't updated yet.
                let fixed = await Task.detached(priority: .utility) { AudioRepair.fix(url, expected: expected) }.value
                if fixed { PhoneLog.shared.note("audio_repaired", "\(id) segment \(index)") }
            }
            do {
                // The recording's language, decided once from its first part to arrive.
                let languages = AppConfig.shared.languages
                let language: String
                if let known = r.locale {
                    language = known
                } else if AppConfig.shared.mixesLanguages, languages.count > 1 {
                    language = LocalRecording.mixed
                    store.update(id, startedAt: r.startedAt) { $0.locale = language }
                } else {
                    language = try await OnDeviceTranscriber.shared.detect(url).identifier
                    store.update(id, startedAt: r.startedAt) { $0.locale = language }
                    PhoneLog.shared.note("asr_language", "\(id) \(language)")
                }
                let phrases: [Phrase]
                if language == LocalRecording.mixed {
                    let mixed = try await OnDeviceTranscriber.shared.transcribeMixed(url, languages: languages.map { Locale(identifier: $0) })
                    phrases = mixed.phrases
                    PhoneLog.shared.note("asr_mixed", "segment \(index) \(mixed.note)")
                } else {
                    phrases = try await OnDeviceTranscriber.shared.transcribe(url, locale: Locale(identifier: language))
                }
                store.update(id, startedAt: r.startedAt) { $0.segments[index]?.phrases = phrases }
                waiting = nil
                PhoneLog.shared.note("asr_done", "segment \(index) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s phrases=\(phrases.count)")
            } catch OnDeviceTranscriber.Failure.notReady(let why) {
                transcriberNotReady = true
                if waiting == nil { waiting = why }
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
            // No title coming: the notice goes now.
            if !Describer.isAvailable || r.titleByUser {
                Notifier.shared.ready(id)
            }

        case let .describe(id):
            guard let r = store.recordings[id] else { return }
            let paragraphs = LocalStore.blocks(r).filter { !$0.backchannel }.map { r.tidy?[$0.text] ?? r.clean[$0.text] ?? $0.text }
            guard !paragraphs.joined().isEmpty else {
                store.update(id, startedAt: r.startedAt) { $0.describedAt = .now }
                Notifier.shared.ready(id)
                changed()
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
                Notifier.shared.ready(id)
            } catch {
                // Rate-limited or refused: try again next time we're in front,
                // and send the notice without a title.
                describeFailed.insert(id)
                PhoneLog.shared.note("describe_failed", error.localizedDescription)
                Notifier.shared.ready(id)
                return
            }

        case let .tidy(id):
            await tidy(id)
        }
        changed()
    }

    /// Paragraph by paragraph, saving as it goes so the transcript fills
    /// in. Stops when Jotto leaves the front; carries on next time.
    private func tidy(_ id: String) async {
        guard let r = store.recordings[id] else { return }
        let blocks = LocalStore.blocks(r).filter { !$0.backchannel }
        let began = Date.now
        var kept = 0, rejected = 0
        for b in blocks where store.recordings[id]?.tidy?[b.text] == nil {
            guard UIApplication.shared.applicationState != .background,
                  store.recordings[id]?.tidiedAt == nil, store.recordings[id]?.polishedAt != nil else { return }
            let rough = r.clean[b.text] ?? Cleanup.clean(b.text)
            do {
                let tidied = try await Editor.tidy(rough)
                if tidied == nil { rejected += 1 } else { kept += 1 }
                store.update(id, startedAt: r.startedAt) { $0.tidy = ($0.tidy ?? [:]).merging([b.text: tidied ?? rough]) { $1 } }
                changed()
            } catch {
                tidyFailed.insert(id)
                PhoneLog.shared.note("tidy_failed", "\(id) \(error.localizedDescription)")
                return
            }
        }
        store.update(id, startedAt: r.startedAt) { $0.tidiedAt = .now }
        PhoneLog.shared.note("tidied", "\(id) kept=\(kept) rejected=\(rejected) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s")
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
            let destination = AudioFiles.url(session: id, index: index)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source, to: destination)
            let duration = (try? AVAudioFile(forReading: destination)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 120
            segmentArrived(id, startedAt: startedAt, index: index, offset: offset, duration: duration)
            offset += duration
        }
        // "15,30-45": a moment at 0:15, a section from 0:30 to 0:45.
        for mark in (ProcessInfo.processInfo.environment["JOTTO_SIMULATE_MARKS"] ?? "").split(separator: ",") {
            let ends = mark.split(separator: "-").compactMap { Double($0) }
            if ends.count == 2 { markedSection(id, startedAt: startedAt, start: ends[0], end: ends[1]) }
            else if let at = ends.first { marked(id, startedAt: startedAt, offset: at) }
        }
        finished(id, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(offset), segmentCount: files.count)
    }
}
#endif
