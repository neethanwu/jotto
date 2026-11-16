import BackgroundTasks
import Foundation
import UIKit

/// Does on the phone what the server used to: each segment from the watch
/// is transcribed as it arrives; when the recording ends and every part is
/// in, the text is cleaned up and given a title.
///
/// Runs whenever there is work: on arrival (the watch nudges jotto awake
/// after each part it sends, see `Inbox`), on launch and on coming to the
/// foreground. Each step asks for background time, so a locked phone keeps
/// going for a while.
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
    /// What the model is working on right now, for the timeline: a title
    /// being written, or paragraphs being formatted.
    @ObservationIgnored private(set) var describingNow: String?
    @ObservationIgnored private var tidyingNow: String?
    /// Transcription can't run yet (model not downloaded); retried next run.
    @ObservationIgnored private var transcriberNotReady = false
    /// Parts that failed out of sight this run ("id#index"); tried again
    /// next run, and given up only if they fail in front.
    @ObservationIgnored private var deferred: Set<String> = []

    /// Give up on segments that haven't arrived this long after the end.
    private static let missingTimeout: TimeInterval = 30 * 60

    // MARK: - From the watch

    func started(_ id: String, at startedAt: Date) {
        store.update(id, startedAt: startedAt) { $0.heardAt = .now }
        LiveActivities.shared.sync()
        changed()
        warmUp()
        PlaceTracker.shared.update("start")
    }

    /// A recording has started: load Qwen3-ASR now, in the few seconds the
    /// watch's nudge gives, so the first part isn't held up by it, and keep
    /// it loaded while parts are still to come (`QwenEngine.hold`).
    private func warmUp() {
        guard AppConfig.shared.usesQwen, !Cloud.isOn, SpeechPack.shared.state == .ready else { return }
        QwenEngine.shared.hold(true)
        let time = BackgroundTime(step: "warm up")
        Task {
            try? await QwenEngine.shared.prepare()
            time.end()
        }
    }

    /// The audio is already at `AudioFiles.url(session:index:)`.
    func segmentArrived(_ id: String, startedAt: Date, index: Int, offset: Double, duration: Double) {
        guard !store.isDeleted(id) else {
            try? FileManager.default.removeItem(at: AudioFiles.url(session: id, index: index))
            return
        }
        store.update(id, startedAt: startedAt) { r in
            r.heardAt = .now
            if r.segments[index] == nil {
                r.segments[index] = LocalSegment(index: index, offset: offset, duration: duration)
                // A part that arrives after the rest was cleaned up (the
                // watch was out of reach): clean up again with it.
                if r.polishedAt != nil {
                    r.polishedAt = nil
                    r.tidiedAt = nil
                }
            }
        }
        if finishing != nil { finishTotal += 1 }
        PlaceTracker.shared.partArrived(index)
        PlaceTracker.shared.update("part \(index)")
        changed()
        run()
        finishInBackgroundIfNeeded()
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
            LiveActivities.shared.update(id)
        }
    }

    /// Shorter than this is taken for a tap by mistake, on the watch or
    /// here, and dropped (as on the watch, `Recorder.shortest`).
    static let shortest: TimeInterval = 3

    func finished(_ id: String, startedAt: Date, endedAt: Date, segmentCount: Int) {
        if endedAt.timeIntervalSince(startedAt) < Self.shortest {
            openSections[id] = nil
            store.delete(id)
            Library.shared.remove(id)
            try? FileManager.default.removeItem(at: AudioFiles.directory.appending(path: id))
            PhoneLog.shared.note("dropped_short", "\(id) \(String(format: "%.1f", endedAt.timeIntervalSince(startedAt)))s")
            changed()
            return
        }
        if let start = openSections.removeValue(forKey: id) {
            markedSection(id, startedAt: startedAt, start: start, end: min(endedAt.timeIntervalSince(startedAt), start + Self.sectionLimit))
        }
        store.update(id, startedAt: startedAt) { r in
            r.endedAt = endedAt
            r.segmentCount = segmentCount
        }
        LiveActivities.shared.end(id)
        Inbox.shared.syncHistory()
        changed()
        askToOpenIfTooMuch(id)
        run()
    }

    /// The watch has stopped and jotto is out of sight. When the work
    /// plainly won't fit in the half minute a nudge gives (the model still
    /// to load, which takes about a minute out of sight, or several parts
    /// to hear), the notice asking to open jotto goes now, at the stop,
    /// rather than once that time has run out. A recording that will fit
    /// gets just its "ready" notice.
    private func askToOpenIfTooMuch(_ id: String) {
        guard UIApplication.shared.applicationState == .background, !keptRunning,
              let r = store.recordings[id], let count = r.segmentCount else { return }
        let toHear = count - r.segments.values.filter { $0.phrases != nil || $0.failed != nil }.count
        let coldModel = AppConfig.shared.usesQwen && !Cloud.isOn && !QwenEngine.shared.isLoaded
        guard toHear >= 3 || (coldModel && toHear > 0) else { return }
        PhoneLog.shared.note("too_much", "\(id) parts=\(toHear) cold=\(coldModel)")
        Notifier.shared.askToOpen(id)
    }

    func marked(_ id: String, startedAt: Date, offset: Double) {
        store.update(id, startedAt: startedAt) { r in
            r.heardAt = .now
            if !r.marks.contains(offset) { r.marks.append(offset) }
        }
        LiveActivities.shared.update(id)
    }

    func markedSection(_ id: String, startedAt: Date, start: Double, end: Double) {
        store.update(id, startedAt: startedAt) { r in
            let section = LocalRecording.MarkedSection(start: start, end: end)
            if !(r.sections ?? []).contains(section) { r.sections = (r.sections ?? []) + [section] }
        }
        LiveActivities.shared.update(id)
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
        current = Task {
            repeat {
                rerun = false
                describeFailed = []
                tidyFailed = []
                transcriberNotReady = false
                deferred = []
                await prepareIfNeeded()
                retryFailedOnce()
                await redoSlowedRecordings()
                refreshLayouts()
                closeAbandoned()
                store.purgeAudio(keepingDays: AppConfig.shared.keepAudioDays)
                while let step = nextStep() {
                    await perform(step)
                    // After every step: a part heard returns before
                    // `changed()`, so iOS's progress stayed at 0 of n, and
                    // with no progress iOS gave up on the task and said it
                    // failed while the parts were being heard.
                    reportFinishing()
                }
            } while rerun
            running = false
            // Out of sight and out of steps, with parts of a finished
            // recording still unheard (the model not ready, a part that
            // failed here): say so rather than wait in silence.
            if UIApplication.shared.applicationState == .background, !keptRunning { askToOpenIfStuck(onlyUnheard: true) }
            awake?.end()
            awake = nil
            PlaceTracker.shared.update("idle")
            QwenEngine.shared.hold(store.recordings.values.contains { $0.endedAt == nil && $0.imported == nil } || partsToHear > 0)
            // Woken by the watch and out of steps that can run unseen, or
            // left with parts still to hear: ask iOS for a later turn.
            if UIApplication.shared.applicationState == .background { scheduleCatchUp() }
        }
    }

    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var current: Task<Void, Never>?

    /// The watch has nudged jotto awake. Each nudge brings fresh background
    /// time, but only to whoever asks for it: a step already under way
    /// (the model still loading, a part half heard) had used up its own,
    /// went on in the nudge's few seconds and stopped mid-part, where it
    /// waited until jotto was next opened. So take new time here, for the
    /// run as a whole, until it's idle.
    func woken(_ reason: String) {
        let previous = awake
        awake = BackgroundTime(step: "wake: \(reason)")
        previous?.end()
        PlaceTracker.shared.update("wake: \(reason)")
        run()
    }

    @ObservationIgnored private var awake: BackgroundTime?

    /// Time out of sight is about to run out. A recording that's done gets
    /// its notice now, without waiting for its title; one that has ended
    /// with parts still to hear gets a notice asking to open jotto, rather
    /// than nothing until it's next opened.
    func outOfTime() {
        for r in store.recordings.values where r.isEnded && r.polishedAt != nil && r.notifiedAt == nil && r.imported == nil {
            Notifier.shared.ready(r.id)
        }
        askToOpenIfStuck(onlyUnheard: false)
    }

    /// A step's background time ran out. Not the end while iOS keeps jotto
    /// running for the work anyway (a continued task after jotto was
    /// opened, or a catch-up turn), which ends in its own time.
    func stepOutOfTime() {
        guard !keptRunning else { return }
        outOfTime()
    }

    /// iOS keeps jotto running for the work anyway: a continued task after
    /// jotto was opened, a catch-up turn, or following places while a
    /// recording goes on. Then running out of a step's time isn't the end,
    /// and there's no need to ask for jotto to be opened.
    private var keptRunning: Bool {
        finishing != nil || catchingUp || PlaceTracker.shared.isFollowing
    }

    /// Not for one only waiting on parts still on the watch: opening jotto
    /// wouldn't bring them.
    private func askToOpenIfStuck(onlyUnheard: Bool) {
        for r in store.recordings.values where r.isEnded && r.polishedAt == nil && r.notifiedAt == nil && r.imported == nil {
            let unheard = r.segments.values.contains { $0.phrases == nil && $0.failed == nil }
            if unheard || (!onlyUnheard && r.allTranscribed) { Notifier.shared.askToOpen(r.id) }
        }
    }

    /// Runs, and returns once there's nothing left to do for now.
    func runUntilIdle() async {
        run()
        await current?.value
    }

    // MARK: - In the background

    /// The catch-up turn iOS gives jotto in the background, for what a wake
    /// from the watch didn't have time to finish (a long part through
    /// Qwen3-ASR on a locked phone). When it comes is up to iOS: usually
    /// soon while the phone sits locked, later when it's busy.
    static let catchUpID = "com.neethanwu.jotto.pipeline"

    /// Parts still to hear, or recordings still to put together: the work
    /// that runs with jotto out of sight.
    var hasBackgroundWork: Bool {
        store.recordings.values.contains { r in
            r.segments.values.contains { $0.phrases == nil && $0.failed == nil }
                || (r.isEnded && r.polishedAt == nil)
        }
    }

    func scheduleCatchUp() {
        guard hasBackgroundWork else { return }
        let request = BGProcessingTaskRequest(identifier: Self.catchUpID)
        request.requiresNetworkConnectivity = Cloud.isOn
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            PhoneLog.shared.note("bg_scheduled")
        } catch {
            PhoneLog.shared.note("bg_schedule_failed", error.localizedDescription)
        }
    }

    /// iOS's turn: work until done or until it wants the time back; a
    /// step cut off carries on the next time jotto runs.
    func catchUp(_ task: BGProcessingTask) {
        PhoneLog.shared.note("bg_processing")
        let turn = CatchUpTurn(task)
        catchingUp = true
        task.expirationHandler = {
            Task { @MainActor in
                PhoneLog.shared.note("bg_processing_expired")
                Pipeline.shared.catchingUp = false
                Pipeline.shared.outOfTime()
                Pipeline.shared.scheduleCatchUp()
                turn.complete(success: false)
            }
        }
        Task {
            await runUntilIdle()
            catchingUp = false
            turn.complete(success: !hasBackgroundWork)
            scheduleCatchUp()
        }
    }

    @ObservationIgnored private var catchingUp = false

    /// Parts given up on get one more go, at the first run after a launch:
    /// a service that turned one down, or the model failing on it, may
    /// manage it now. After that they wait for "Try again".
    @ObservationIgnored private var retriedThisLaunch = false

    private func retryFailedOnce() {
        guard !retriedThisLaunch else { return }
        retriedThisLaunch = true
        for r in store.recordings.values where r.imported == nil {
            let again = r.segments.values.filter { $0.failed != nil && $0.retried != true }.map(\.index)
            guard !again.isEmpty else { continue }
            store.update(r.id, startedAt: r.startedAt) { rec in
                for i in again {
                    rec.segments[i]?.failed = nil
                    rec.segments[i]?.retried = true
                }
                rec.polishedAt = nil
                rec.tidiedAt = nil
            }
            PhoneLog.shared.note("retry_failed", "\(r.id) parts=\(again.sorted())")
        }
    }

    /// "Try again" under a transcript with parts that couldn't be heard.
    func retryFailed(_ id: String) {
        guard let r = store.recordings[id] else { return }
        let again = r.segments.values.filter { $0.failed != nil }.map(\.index)
        guard !again.isEmpty else { return }
        store.update(id, startedAt: r.startedAt) { rec in
            for i in again { rec.segments[i]?.failed = nil }
            rec.polishedAt = nil
            rec.tidiedAt = nil
        }
        PhoneLog.shared.note("retry_asked", "\(id) parts=\(again.sorted())")
        changed()
        run()
    }

    // MARK: - Finishing with jotto put away

    /// While jotto is in front with parts still to hear, it asks iOS to let
    /// the work go on if jotto is put away (a continued processing task,
    /// iOS 26): iOS shows how far it has got and keeps it running until
    /// it's done. Without it, leaving jotto stopped the work within seconds,
    /// and a long recording only got done in front.
    static let finishPrefix = "com.neethanwu.jotto.finish"
    @ObservationIgnored private var finishing: BGContinuedProcessingTask?
    @ObservationIgnored private var finishAsked = false
    /// Parts to hear when the task began, plus any that came in since.
    @ObservationIgnored private var finishTotal = 0

    /// A recording still going on, from the watch or this iPhone.
    var hasLiveRecording: Bool {
        store.recordings.values.contains { $0.endedAt == nil && $0.imported == nil }
    }

    /// What following places keeps jotto running for (`PlaceTracker`): a
    /// recording going on, or parts still to hear.
    var hasLiveWork: Bool { hasLiveRecording || partsToHear > 0 }

    /// Parts that have come in and are still to be heard.
    var partsToHear: Int {
        store.recordings.values.reduce(0) { n, r in
            n + r.segments.values.filter { $0.phrases == nil && $0.failed == nil }.count
        }
    }

    func finishInBackgroundIfNeeded() {
        // Not `== .active`: as jotto comes to the front, its scene is active
        // a moment before the app is, and that's when this is asked.
        guard UIApplication.shared.applicationState != .background, finishing == nil, !finishAsked,
              partsToHear > 0 else { return }
        // A part or two with the model loaded takes seconds, which leaving
        // jotto gives anyway; asking would leave iOS's progress and tick
        // showing for nothing.
        let coldModel = AppConfig.shared.usesQwen && !Cloud.isOn && !QwenEngine.shared.isLoaded
        guard partsToHear >= 3 || coldModel else { return }
        finishAsked = true
        let id = "\(Self.finishPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            MainActor.assumeIsolated { Pipeline.shared.finish(task) }
        }
        guard registered else {
            finishAsked = false
            PhoneLog.shared.note("finish_not_registered")
            return
        }
        let (title, subtitle) = finishingText(done: 0, total: partsToHear)
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            PhoneLog.shared.note("finish_asked", "\(partsToHear) parts")
        } catch {
            finishAsked = false
            PhoneLog.shared.note("finish_refused", error.localizedDescription)
        }
    }

    private func finish(_ task: BGContinuedProcessingTask) {
        finishing = task
        finishTotal = partsToHear
        task.progress.totalUnitCount = Int64(max(1, finishTotal))
        task.progress.completedUnitCount = 0
        PhoneLog.shared.note("finish_started", "\(finishTotal) parts")
        task.expirationHandler = {
            Task { @MainActor in Pipeline.shared.endFinishing(success: false, why: "expired") }
        }
        Task {
            await runUntilIdle()
            endFinishing(success: partsToHear == 0, why: partsToHear == 0 ? "done" : "stuck")
        }
    }

    /// After each step: how far the task has got, for iOS to show.
    private func reportFinishing() {
        guard let task = finishing else { return }
        let total = max(finishTotal, 1)
        let done = min(total, max(0, finishTotal - partsToHear))
        task.progress.totalUnitCount = Int64(total)
        task.progress.completedUnitCount = Int64(done)
        let (title, subtitle) = finishingText(done: done, total: total)
        task.updateTitle(title, subtitle: subtitle)
    }

    private func endFinishing(success: Bool, why: String) {
        guard let task = finishing else { return }
        finishing = nil
        finishAsked = false
        task.setTaskCompleted(success: success)
        PhoneLog.shared.note("finish_ended", "\(why) \(partsToHear) left")
        if UIApplication.shared.applicationState == .background {
            if !success { outOfTime() }
            scheduleCatchUp()
        }
    }

    /// "Night recording" / "Transcribing · 2 of 6 parts", or for several
    /// recordings at once, how many.
    private func finishingText(done: Int, total: Int) -> (String, String) {
        let waiting = store.recordings.values.filter { r in r.segments.values.contains { $0.phrases == nil && $0.failed == nil } }
        let title = waiting.count == 1
            ? (waiting[0].title ?? Format.provisionalTitle(waiting[0].startedAt))
            : "\(waiting.count) recordings"
        return (title, "Transcribing · \(done) of \(Format.plural(total, "part"))")
    }

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

    /// A recording the watch went quiet on without saying it finished (its
    /// app was killed, the battery ran out, or the finish got lost) would
    /// look live for ever. After half an hour with nothing new, it ends
    /// where its last part did; a part or finish arriving later still counts.
    private func closeAbandoned() {
        for r in store.recordings.values where r.endedAt == nil && r.imported == nil {
            let heard = r.heardAt ?? r.startedAt
            guard Date.now.timeIntervalSince(heard) > Self.abandonedAfter else { continue }
            let lastPart = r.segments.values.map { $0.offset + $0.duration }.max() ?? 0
            store.update(r.id, startedAt: r.startedAt) {
                $0.endedAt = r.startedAt.addingTimeInterval(lastPart)
                $0.segmentCount = r.segments.count
            }
            Library.shared.watchFinished(r.id, startedAt: r.startedAt, endedAt: r.startedAt.addingTimeInterval(lastPart),
                                         segmentCount: r.segments.count)
            LiveActivities.shared.end(r.id)
            PhoneLog.shared.note("closed_abandoned", "\(r.id) parts=\(r.segments.count)")
        }
    }

    static let abandonedAfter: TimeInterval = 30 * 60

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
        // Qwen3-ASR (or your own key's service) hears the language itself.
        if AppConfig.shared.usesQwen || Cloud.isOn {
            waiting = nil
            return
        }
        let models = SpeechModels.shared
        let wanted = AppConfig.shared.languages
        await models.refresh()
        if wanted.contains(where: { !models.isInstalled($0) }) { waiting = "Downloading the speech model" }
        await models.ensure(wanted)
        waiting = wanted.contains(where: models.failed.contains)
            ? "Couldn't download the speech model. Open jotto on Wi-Fi to try again" : nil
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
            && (Editor.isAvailable || Cloud.isOn)
    }

    /// Paragraphs tidied so far, for the transcript's status line.
    func tidyProgress(_ r: LocalRecording) -> SessionDetail.Tidying? {
        // Not while it's stuck (the model refused or is busy): say nothing.
        // One picked up again where it left off shows only once the model
        // is on it, so a launch where it can't carry on doesn't flash it.
        guard willTidy(r), !tidyFailed.contains(r.id), tidyingNow == r.id || r.tidy == nil else { return nil }
        let blocks = LocalStore.blocks(r).filter { !$0.backchannel }
        return .init(done: blocks.filter { r.tidy?[$0.text] != nil }.count, total: blocks.count)
    }

    private func nextStep() -> Step? {
        let all = store.recordings.values.sorted { $0.startedAt < $1.startedAt }
        // Oldest untranscribed segment first.
        for r in all where !transcriberNotReady {
            if let s = r.segments.values.filter({ $0.phrases == nil && $0.failed == nil && !deferred.contains("\(r.id)#\($0.index)") })
                .min(by: { $0.index < $1.index }) {
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
        if Describer.isAvailable || Cloud.isOn {
            // The on-device model is rate-limited in the background; a service isn't.
            let inFront = UIApplication.shared.applicationState != .background || Cloud.isOn
            for r in all where r.polishedAt != nil && r.describedAt == nil && !r.titleByUser
                && !describeFailed.contains(r.id) && (inFront || r.notifiedAt == nil) {
                return .describe(id: r.id)
            }
        }
        // Tidying, newest first (the one likely open); on this iPhone only in front.
        if UIApplication.shared.applicationState != .background || Cloud.isOn {
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
        let time = BackgroundTime(step: "\(step)")
        defer { time.end() }

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
            if Cloud.isOn {
                do {
                    let heard = try await Cloud.transcribe(url, duration: r.segments[index]?.duration ?? 120)
                    store.update(id, startedAt: r.startedAt) { rec in
                        rec.segments[index]?.phrases = heard.phrases
                        if rec.locale == nil, let language = heard.language, language.count <= 3 { rec.locale = language }
                    }
                    waiting = nil
                    PhoneLog.shared.note("cloud_asr_done", "segment \(index) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s phrases=\(heard.phrases.count)")
                } catch let failure as Cloud.Failure where failure.isPassing {
                    // Offline, busy or a key problem: wait, and say why.
                    transcriberNotReady = true
                    waiting = failure.localizedDescription
                    PhoneLog.shared.note("cloud_asr_waiting", failure.localizedDescription)
                } catch {
                    store.update(id, startedAt: r.startedAt) { $0.segments[index]?.failed = error.localizedDescription }
                    PhoneLog.shared.note("cloud_asr_failed", "segment \(index) \(error.localizedDescription)")
                }
                return
            }
            if AppConfig.shared.usesQwen {
                do {
                    let heard = try await QwenEngine.shared.transcribe(url)
                    store.update(id, startedAt: r.startedAt) { rec in
                        rec.segments[index]?.phrases = heard.phrases
                        if rec.locale == nil, let language = heard.language { rec.locale = language }
                    }
                    waiting = nil
                    PhoneLog.shared.note("qwen_asr_done", "segment \(index) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s phrases=\(heard.phrases.count)")
                } catch {
                    if deferInBackground("qwen", id: id, index: index, error) { return }
                    store.update(id, startedAt: r.startedAt) { $0.segments[index]?.failed = error.localizedDescription }
                    PhoneLog.shared.note("qwen_asr_failed", "segment \(index) \(error.localizedDescription)")
                }
                return
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
                if deferInBackground("asr", id: id, index: index, error) { return }
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
            // No title coming, or no time for one out of sight (the title
            // can follow in jotto; the notice can't wait): the notice goes now.
            let short = UIApplication.shared.applicationState == .background && !keptRunning
                && UIApplication.shared.backgroundTimeRemaining < 20
            if !(Describer.isAvailable || Cloud.isOn) || r.titleByUser || short {
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
            // A few words: they are the title. The model has nothing to
            // go on, and for a test like this it would rather refuse.
            let said = paragraphs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if Sentences.units(said) <= 10 {
                let title = said.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                store.update(id, startedAt: r.startedAt) {
                    if !$0.titleByUser, !title.isEmpty { $0.title = title }
                    $0.describedAt = .now
                }
                Notifier.shared.ready(id)
                changed()
                return
            }
            describingNow = id
            changed()
            defer { describingNow = nil }
            do {
                let d = Cloud.isOn ? try await Cloud.describe(paragraphs) : try await Describer.describe(paragraphs).plain
                store.update(id, startedAt: r.startedAt) {
                    if !$0.titleByUser { $0.title = d.title }
                    $0.titleSuggestions = d.suggestions
                    $0.summary = d.summary
                    $0.describedAt = .now
                }
                Notifier.shared.ready(id)
            } catch {
                // Busy or offline: try again next time we're in front. A
                // failure that would only come round again (the model won't
                // write about this text, or a service keeps turning it
                // down): after a few, stop asking, so it doesn't flash
                // "writing the title" at every launch, and it keeps its
                // time-of-day name, which can be renamed. Either way the
                // notice goes now, without a title.
                let verdict = Cloud.isOn ? ((error as? Cloud.Failure)?.isPassing == true ? true : nil) : Describer.isPassing(error)
                let passing = verdict == true
                let tries = (r.describeTries ?? 0) + (passing ? 0 : 1)
                let giveUp = verdict == false || (!passing && tries >= 3)
                store.update(id, startedAt: r.startedAt) {
                    $0.describeTries = tries
                    if giveUp { $0.describedAt = .now }
                }
                if !giveUp { describeFailed.insert(id) }
                PhoneLog.shared.note(giveUp ? "describe_gave_up" : "describe_failed", "\(id) \(error.localizedDescription)")
                Notifier.shared.ready(id)
                return
            }

        case let .tidy(id):
            await tidy(id)
        }
        changed()
    }

    /// A part that fails to transcribe out of sight may have failed for
    /// the phone's sake (locked, short of memory, the model not loading):
    /// it waits to be tried again rather than being given up without text.
    /// In front, a failure is the part's own and it's given up.
    private func deferInBackground(_ engine: String, id: String, index: Int, _ error: Error) -> Bool {
        guard UIApplication.shared.applicationState == .background else { return false }
        deferred.insert("\(id)#\(index)")
        PhoneLog.shared.note("\(engine)_asr_deferred", "segment \(index) \(error.localizedDescription)")
        return true
    }

    /// Paragraph by paragraph, saving as it goes so the transcript fills
    /// in. Stops when jotto leaves the front; carries on next time.
    private func tidy(_ id: String) async {
        guard let r = store.recordings[id] else { return }
        let blocks = LocalStore.blocks(r).filter { !$0.backchannel }
        let began = Date.now
        var kept = 0, rejected = 0, refused = 0
        tidyingNow = id
        defer { tidyingNow = nil }
        for b in blocks where store.recordings[id]?.tidy?[b.text] == nil {
            guard UIApplication.shared.applicationState != .background || Cloud.isOn,
                  store.recordings[id]?.tidiedAt == nil, store.recordings[id]?.polishedAt != nil else { return }
            let rough = r.clean[b.text] ?? Cleanup.clean(b.text)
            do {
                let tidied = try await Editor.tidy(rough)
                if tidied == nil { rejected += 1 } else { kept += 1 }
                store.update(id, startedAt: r.startedAt) { $0.tidy = ($0.tidy ?? [:]).merging([b.text: tidied ?? rough]) { $1 } }
                changed()
            } catch where Editor.isAboutThisText(error) || (error as? Cloud.Failure).map({ !$0.isPassing }) == true {
                // The model won't do this one paragraph (its guardrails,
                // or too long): it keeps the rule-based text, and the rest
                // carry on. Stopping here left the recording half done,
                // tried again and failing at every launch.
                refused += 1
                store.update(id, startedAt: r.startedAt) { $0.tidy = ($0.tidy ?? [:]).merging([b.text: rough]) { $1 } }
                changed()
            } catch {
                // Busy or rate-limited: try again next time.
                tidyFailed.insert(id)
                PhoneLog.shared.note("tidy_failed", "\(id) \(error.localizedDescription)")
                return
            }
        }
        store.update(id, startedAt: r.startedAt) { $0.tidiedAt = .now }
        PhoneLog.shared.note("tidied", "\(id) kept=\(kept) rejected=\(rejected) refused=\(refused) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s")
    }

    private func changed() {
        reportFinishing()
        Task { await Library.shared.refresh() }
        // Marks, sections and new lines show on the lock screen too.
        for r in store.recordings.values where r.endedAt == nil { LiveActivities.shared.update(r.id) }
    }
}

#if DEBUG
import AVFoundation

extension Pipeline {
    /// Simulator: feeds a folder of .m4a files through as if the watch sent
    /// them. `SIMCTL_CHILD_JOTTO_SIMULATE_RECORDING=/path/to/dir xcrun simctl launch …`
    func simulateRecordingIfRequested() {
        // A recording that has started on the watch and is still going.
        if ProcessInfo.processInfo.environment["JOTTO_SIMULATE_LIVE"] != nil {
            let id = UUID().uuidString.lowercased()
            let startedAt = Date.now.addingTimeInterval(-312)
            Library.shared.watchStarted(id, at: startedAt)
            started(id, at: startedAt)
            marked(id, startedAt: startedAt, offset: 120)
        }
        guard let dir = ProcessInfo.processInfo.environment["JOTTO_SIMULATE_RECORDING"] else { return }
        // "5": the parts come five seconds after launch, so jotto can be
        // put away first and they're worked on out of sight.
        if let after = ProcessInfo.processInfo.environment["JOTTO_SIMULATE_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(after))
                simulateRecording(from: dir)
            }
            return
        }
        simulateRecording(from: dir)
    }

    private func simulateRecording(from dir: String) {
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


/// Background time for one step. When it runs out partway (a long part
/// transcribed on a locked phone), the task is ended so iOS suspends
/// jotto instead of quitting it, and the step carries on the next time
/// jotto runs; the log says so.
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(step: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: "jotto.pipeline") { [weak self] in
            MainActor.assumeIsolated {
                PhoneLog.shared.note("bg_expired", "\(step) \(Int(UIApplication.shared.backgroundTimeRemaining))s")
                Pipeline.shared.stepOutOfTime()
                Pipeline.shared.scheduleCatchUp()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// One catch-up turn, finished once: by the work running out or by iOS
/// taking the time back, whichever comes first.
@MainActor
private final class CatchUpTurn: @unchecked Sendable {
    private let task: BGProcessingTask
    private var done = false

    init(_ task: BGProcessingTask) { self.task = task }

    func complete(success: Bool) {
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: success)
        PhoneLog.shared.note("bg_processing_done", success ? "all done" : "more to do")
    }
}

