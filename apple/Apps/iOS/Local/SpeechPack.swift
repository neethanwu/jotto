import BackgroundAssets
import Foundation
import Observation
import System
import UIKit

/// The speech model you can download: Qwen3-ASR 0.6B, about 950 MB, for
/// recordings with Chinese and English mixed together. Never downloaded
/// unless asked for (Settings → Processing). In App Store and TestFlight
/// builds the files come through the App Store, as an asset pack App
/// Store Connect hosts (AssetPacks/qwen3-asr), which reaches every
/// storefront, mainland China included. Builds from source fetch the
/// same files from Hugging Face at fixed revisions, and so does a store
/// build the pack isn't served to. Nothing about your recordings is sent.
///
/// iOS loses an App Store download that was moved to the background
/// partway (it fails at the end and starts again from nothing), so while
/// one runs the screen stays on and the page asks for jotto to stay open;
/// if it was closed anyway, the download starts over once jotto is back.
@MainActor @Observable
final class SpeechPack: NSObject {
    static let shared = SpeechPack()

    enum State: Equatable {
        case absent
        /// 0…1.
        case downloading(Double)
        /// Downloaded; loading it once so the first recording doesn't wait.
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .absent {
        didSet { keepAwake() }
    }
    var isReady: Bool { state == .ready }
    /// Downloading, but nothing has come for a while: the server can't be
    /// reached from here (a network that blocks it, or none at all).
    private(set) var stalled = false
    /// Coming through the App Store, which needs jotto kept open, rather
    /// than from Hugging Face, which carries on with jotto closed.
    private(set) var fromApple = false {
        didSet { keepAwake() }
    }
    /// Started again from nothing, after jotto was closed partway.
    private(set) var startedOver = false
    /// Seconds to go at the speed of the last half minute, once known.
    private(set) var secondsLeft: Double?
    @ObservationIgnored private var lastProgress = Date.now
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var samples: [(date: Date, fraction: Double)] = []

    static let name = "Qwen3-ASR"
    static let sizeLabel = "950 MB"
    static let megabytes = 950

    private struct File: Sendable {
        let path: String
        let size: Int64
        let base: String
    }

    nonisolated private static let models = "https://huggingface.co/aufklarer/Qwen3-ASR-CoreML/resolve/8c6bc87b87856930b435550e94ce47de710ce4ed/"
    nonisolated private static let tokenizer = "https://huggingface.co/Qwen/Qwen3-ASR-0.6B/resolve/5eb144179a02acc5e5ba31e748d22b0cf3e303b0/"

    nonisolated private static let files: [File] = [
        ("config.json", 656),
        ("decoder_part1.mlmodelc/analytics/coremldata.bin", 243),
        ("decoder_part1.mlmodelc/coremldata.bin", 1263),
        ("decoder_part1.mlmodelc/metadata.json", 10422),
        ("decoder_part1.mlmodelc/model.mil", 391_638),
        ("decoder_part1.mlmodelc/weights/weight.bin", 220_344_512),
        ("decoder_part2.mlmodelc/analytics/coremldata.bin", 243),
        ("decoder_part2.mlmodelc/coremldata.bin", 1257),
        ("decoder_part2.mlmodelc/metadata.json", 10416),
        ("decoder_part2.mlmodelc/model.mil", 394_840),
        ("decoder_part2.mlmodelc/weights/weight.bin", 376_233_664),
        ("embedding.mlmodelc/analytics/coremldata.bin", 243),
        ("embedding.mlmodelc/coremldata.bin", 317),
        ("embedding.mlmodelc/metadata.json", 1589),
        ("embedding.mlmodelc/model.mil", 1161),
        ("embedding.mlmodelc/weights/weight.bin", 155_583_168),
        ("encoder.mlmodelc/analytics/coremldata.bin", 243),
        ("encoder.mlmodelc/coremldata.bin", 376),
        ("encoder.mlmodelc/metadata.json", 2736),
        ("encoder.mlmodelc/model.mil", 1_298_756),
        ("encoder.mlmodelc/weights/weight.bin", 186_844_416),
    ].map { File(path: $0.0, size: $0.1, base: models) } + [
        ("tokenizer_config.json", 12487),
        ("vocab.json", 2_776_833),
    ].map { File(path: $0.0, size: $0.1, base: tokenizer) }

    nonisolated private static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Kept out of backups: it can always be downloaded again.
    nonisolated static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Models/qwen3-asr-0.6b", directoryHint: .isDirectory)
    }

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var written: [String: Int64] = [:]
    /// From the app delegate, when iOS wakes jotto for the download.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    /// Asked for and not yet cancelled; survives jotto being closed mid-download.
    private var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: "speechPackWanted") }
        set { UserDefaults.standard.set(newValue, forKey: "speechPackWanted") }
    }

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.neethanwu.jotto.speechpack")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: PackDelegate(), delegateQueue: nil)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
        if missing().isEmpty {
            // Closed while it was loading for the first time: once more.
            if wanted { prepare() } else { state = .ready }
        } else if wanted {
            // A download that was going when jotto last closed: carry on.
            // Files still coming from Hugging Face keep coming; otherwise
            // ask again, which picks up whatever the system still has.
            begin(fraction())
            session.getAllTasks { tasks in
                Task { @MainActor in
                    if !tasks.isEmpty {
                        self.fromApple = false
                    } else if Self.isStoreBuild {
                        self.startFromStore()
                    } else {
                        self.downloadFromWeb(self.missing())
                    }
                }
            }
        }
    }

    private func missing() -> [File] {
        Self.files.filter { file in
            let url = Self.directory.appending(path: file.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            return size != file.size
        }
    }

    private func fraction() -> Double {
        let gone = Set(missing().map(\.path))
        let have = Self.files.filter { !gone.contains($0.path) }.reduce(0) { $0 + $1.size }
        let going = written.values.reduce(0, +)
        return min(1, Double(have + going) / Double(Self.totalBytes))
    }

    func download() {
        guard state != .ready, state != .preparing else { return }
        let needed = missing()
        wanted = true
        guard !needed.isEmpty else { prepare(); return }
        written = [:]
        restarts = 0
        startedOver = false
        begin(fraction())
        if Self.isStoreBuild { startFromStore() } else { downloadFromWeb(needed) }
    }

    /// Downloading from `fraction`, with the speed and the watchdog fresh.
    private func begin(_ fraction: Double) {
        state = .downloading(fraction)
        samples = []
        secondsLeft = nil
        watchProgress()
    }

    // MARK: Through the App Store

    /// The asset pack's ID in App Store Connect (letters, digits and
    /// hyphens only) and the folder its files sit in.
    nonisolated static let packID = "qwen3-asr-0-6b"
    nonisolated static let packFolder = "qwen3-asr-0.6b"
    @ObservationIgnored private var fromStore: Task<Void, Never>?
    @ObservationIgnored private var updates: Task<Void, Never>?
    /// The system's own progress for the pack: cancelling it stops the download.
    @ObservationIgnored private var storeProgress: Progress?
    /// Sent to the background while the App Store download ran.
    @ObservationIgnored private var leftPartway = false
    @ObservationIgnored private var restartWhenBack = false
    @ObservationIgnored private var restarts = 0

    /// App Store and TestFlight builds, which Apple re-signs without a
    /// provisioning profile inside; only they are served the asset pack.
    nonisolated static var isStoreBuild: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") == nil
        #endif
    }

    private func startFromStore() {
        fromApple = true
        fromStore?.cancel()
        fromStore = Task { await downloadFromStore() }
    }

    /// The asset pack, asked for with a time limit: with no network the
    /// question can go unanswered for a long time.
    private static func storePack() async throws -> AssetPack {
        try await withThrowingTaskGroup(of: AssetPack.self) { group in
            group.addTask {
                if #available(iOS 27, *) {
                    guard let pack = try await AssetPackManager.shared.manifest.assetPack(withID: packID) else {
                        throw ManagedBackgroundAssetsError.assetPackNotFound(withID: packID)
                    }
                    return pack
                }
                return try await AssetPackManager.shared.assetPack(withID: packID)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    /// The App Store has no such pack for this build (not yet approved,
    /// say), as opposed to not answering.
    private static func notServed(_ error: Error) -> Bool {
        if let managed = error as? ManagedBackgroundAssetsError, case .assetPackNotFound = managed { return true }
        let ns = error as NSError
        return ns.domain.contains("BAManagedError") && ns.code == 0
    }

    private func downloadFromStore() async {
        let pack: AssetPack
        do {
            pack = try await Self.storePack()
        } catch {
            guard !Task.isCancelled, wanted else { return }
            if Self.notServed(error) {
                PhoneLog.shared.note("pack_store_missing", error.localizedDescription)
                downloadFromWeb(missing())
            } else {
                storeFailed(error, reached: false)
            }
            return
        }
        PhoneLog.shared.note("pack_store", "v\(pack.version) \(pack.downloadSize / 1_000_000) MB")
        listen()
        do {
            try await AssetPackManager.shared.ensureLocalAvailability(of: pack)
            updates?.cancel()
            storeProgress = nil
            guard wanted else { return }
            // Into jotto's own folder, where the model loads from; on the
            // same disk a copy is a clone, so it takes no more room. Then
            // the pack itself can go.
            try await Task.detached { try Self.copyFromStore() }.value
            try? await AssetPackManager.shared.remove(assetPackWithID: Self.packID)
            PhoneLog.shared.note("pack_store_done")
            leftPartway = false
            if missing().isEmpty { prepare() } else { storeFailed(CocoaError(.fileReadCorruptFile)) }
        } catch {
            updates?.cancel()
            storeProgress = nil
            guard !Task.isCancelled, wanted else { return }
            storeFailed(error)
        }
    }

    /// Progress from the system, for the bar and the time left.
    private func listen() {
        updates?.cancel()
        updates = Task { [weak self] in
            for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: Self.packID) {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case let .downloading(_, progress):
                    self.storeProgress = progress
                    if self.downloading { self.advance(progress.fractionCompleted) }
                case .paused:
                    PhoneLog.shared.note("pack_store_paused")
                case let .failed(_, error):
                    PhoneLog.shared.note("pack_store_update_failed", error.localizedDescription)
                default:
                    break
                }
            }
        }
    }

    /// A download moved to the background is lost, so one that failed
    /// after jotto was closed starts over, as soon as jotto is in front
    /// (iOS won't start one for an app that isn't). Any other failure
    /// waits for Try again.
    private func storeFailed(_ error: Error, reached: Bool = true) {
        let left = leftPartway
        leftPartway = false
        PhoneLog.shared.note("pack_store_failed", "\(left ? "left partway; " : "")\(error.localizedDescription)")
        guard left, restarts < 3 else {
            state = .failed(reached
                ? "The download stopped before it finished. Keep jotto open while it downloads."
                : "Couldn't reach the App Store. Check the connection, then try again.")
            return
        }
        restarts += 1
        startedOver = true
        begin(0)
        if UIApplication.shared.applicationState == .active {
            startFromStore()
        } else {
            restartWhenBack = true
        }
    }

    private func wentAway() {
        guard fromApple, downloading else { return }
        leftPartway = true
        PhoneLog.shared.note("pack_store_left")
    }

    private func cameBack() {
        if restartWhenBack {
            restartWhenBack = false
            if downloading { startFromStore() }
        } else if fromApple, downloading, storeProgress != nil {
            // The updates may have stopped while jotto was away.
            listen()
        }
        keepAwake()
    }

    /// An App Store download only finishes with jotto in front, so the
    /// screen doesn't lock partway.
    private func keepAwake() {
        var on = false
        if fromApple, case .downloading = state { on = true }
        if UIApplication.shared.isIdleTimerDisabled != on { UIApplication.shared.isIdleTimerDisabled = on }
    }

    nonisolated private static func copyFromStore() throws {
        let manager = FileManager.default
        for file in files {
            let source = try AssetPackManager.shared.url(for: FilePath("\(packFolder)/\(file.path)"))
            let destination = directory.appending(path: file.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: source, to: destination)
        }
    }

    // MARK: From Hugging Face

    private func downloadFromWeb(_ needed: [File]) {
        guard !needed.isEmpty else { prepare(); return }
        fromApple = false
        written = [:]
        begin(fraction())
        PhoneLog.shared.note("pack_download", "\(needed.count) files")
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            Task { @MainActor in
                for file in needed {
                    let task = self.session.downloadTask(with: URL(string: file.base + file.path)!)
                    task.taskDescription = file.path
                    task.countOfBytesClientExpectsToReceive = file.size
                    task.resume()
                }
            }
        }
    }

    /// Stops whatever is going, from either source.
    private func stopAll() {
        wanted = false
        storeProgress?.cancel()
        storeProgress = nil
        fromStore?.cancel()
        updates?.cancel()
        leftPartway = false
        restartWhenBack = false
        startedOver = false
        if Self.isStoreBuild {
            Task { try? await AssetPackManager.shared.remove(assetPackWithID: Self.packID) }
        }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        written = [:]
    }

    func cancel() {
        stopAll()
        if state != .ready { state = .absent }
        fromApple = false
    }

    /// Deletes the files. Recordings go back to Apple's model.
    func remove() {
        stopAll()
        QwenEngine.shared.unload()
        try? FileManager.default.removeItem(at: Self.directory)
        state = .absent
        fromApple = false
        if AppConfig.shared.speechModel == .qwen {
            AppConfig.shared.speechModel = .apple
            Pipeline.shared.languageChanged()
        }
        PhoneLog.shared.note("pack_removed")
    }

    // MARK: From the download

    private var downloading: Bool {
        guard wanted else { return false }
        switch state {
        case .absent, .downloading: return true
        default: return false
        }
    }

    /// Notices when the download has gone quiet for 20 s.
    private func watchProgress() {
        lastProgress = .now
        stalled = false
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, case .downloading = self.state else { return }
                let quiet = Date.now.timeIntervalSince(self.lastProgress) > 20
                if quiet != self.stalled {
                    self.stalled = quiet
                    if quiet { PhoneLog.shared.note("pack_stalled", self.fromApple ? "store" : "web") }
                }
            }
        }
    }

    /// New progress, from either source: the bar, and the time left at
    /// the speed of the last half minute.
    private func advance(_ fraction: Double) {
        lastProgress = .now
        if stalled { stalled = false }
        state = .downloading(fraction)
        let now = Date.now
        samples.append((now, fraction))
        if samples.count > 2 { samples.removeAll { now.timeIntervalSince($0.date) > 30 } }
        if let first = samples.first, fraction > first.fraction {
            let seconds = now.timeIntervalSince(first.date)
            if seconds >= 5 { secondsLeft = (1 - fraction) * seconds / (fraction - first.fraction) }
        }
    }

    fileprivate func progressed(_ path: String, _ bytes: Int64) {
        guard downloading else { return }
        written[path] = bytes
        advance(fraction())
    }

    fileprivate func finished(_ path: String) {
        written[path] = nil
        guard downloading else { return }
        if missing().isEmpty { prepare() } else { advance(fraction()) }
    }

    fileprivate func failed(_ path: String, _ error: Error) {
        written[path] = nil
        guard downloading, (error as? URLError)?.code != .cancelled else { return }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        state = .failed("The download stopped. \(error.localizedDescription)")
        PhoneLog.shared.note("pack_failed", "\(path) \(error.localizedDescription)")
    }

    fileprivate func doneInBackground() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    /// Loads the model once (the Neural Engine compiles it the first
    /// time), then uses it.
    private func prepare() {
        state = .preparing
        fromApple = false
        var url = Self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        Task {
            do {
                try await QwenEngine.shared.prepare()
                wanted = false
                state = .ready
                AppConfig.shared.speechModel = .qwen
                Pipeline.shared.languageChanged()
                PhoneLog.shared.note("pack_ready")
            } catch {
                state = .failed("Downloaded, but it didn't load. \(error.localizedDescription)")
                PhoneLog.shared.note("pack_load_failed", error.localizedDescription)
            }
        }
    }
}

/// Runs on the session's queue: files must be moved before this returns.
private final class PackDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let path = downloadTask.taskDescription else { return }
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            let error = URLError(.badServerResponse)
            Task { @MainActor in SpeechPack.shared.failed(path, error) }
            return
        }
        let destination = SpeechPack.directory.appending(path: path)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in SpeechPack.shared.finished(path) }
        } catch {
            Task { @MainActor in SpeechPack.shared.failed(path, error) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let path = downloadTask.taskDescription else { return }
        Task { @MainActor in SpeechPack.shared.progressed(path, totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let path = task.taskDescription else { return }
        Task { @MainActor in SpeechPack.shared.failed(path, error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in SpeechPack.shared.doneInBackground() }
    }
}

/// The loaded model, used one part at a time on its own queue. Let go
/// after a few idle minutes, or when memory runs short.
final class QwenEngine: @unchecked Sendable {
    static let shared = QwenEngine()

    /// Asked for by the person, even out of sight: at utility, loading the
    /// model in the time a wake from the watch gives took over a minute of
    /// it, where in front it takes seconds.
    private let queue = DispatchQueue(label: "com.neethanwu.jotto.qwen", qos: .userInitiated)
    private var model: QwenASR?
    private var uses = 0
    /// Kept loaded while a recording is going or parts are still to come,
    /// so each wake from the watch doesn't start by loading it again.
    private var held = false

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            QwenEngine.shared.unload()
        }
    }

    func prepare() async throws {
        try await run { _ in }
    }

    func transcribe(_ url: URL) async throws -> QwenTranscriber.Result {
        try await run { try QwenTranscriber.transcribe(url, with: $0) }
    }

    func unload() {
        queue.async { self.model = nil }
    }

    func hold(_ on: Bool) {
        queue.async {
            guard self.held != on else { return }
            self.held = on
            // Let go: unloaded as after any use, if nothing comes meanwhile.
            guard !on else { return }
            let use = self.uses
            self.queue.asyncAfter(deadline: .now() + 180) {
                if self.uses == use, !self.held { self.model = nil }
            }
        }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable (QwenASR) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.model == nil {
                        let began = Date.now
                        let model = try QwenASR(directory: SpeechPack.directory)
                        self.model = model
                        PhoneLog.shared.later("qwen_loaded", String(format: "%.1fs", Date.now.timeIntervalSince(began)) + " (\(model.loadTimes))")
                    }
                    let result = try work(self.model!)
                    self.uses += 1
                    let use = self.uses
                    self.queue.asyncAfter(deadline: .now() + 180) {
                        if self.uses == use, !self.held { self.model = nil }
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
