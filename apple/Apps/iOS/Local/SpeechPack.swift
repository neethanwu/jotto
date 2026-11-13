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
/// storefront, mainland China included. Other builds, or if the App
/// Store can't give it, fetch the same files from Hugging Face at fixed
/// revisions. Either way the download carries on when Jotto isn't open,
/// and nothing about your recordings is sent.
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

    private(set) var state: State = .absent
    var isReady: Bool { state == .ready }
    /// Downloading, but nothing has come for a while: the server can't be
    /// reached from here (a network that blocks it, or none at all).
    private(set) var stalled = false
    @ObservationIgnored private var lastProgress = Date.now
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    static let name = "Qwen3-ASR"
    static let sizeLabel = "950 MB"

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
    /// From the app delegate, when iOS wakes Jotto for the download.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    /// Asked for and not yet cancelled; survives Jotto being closed mid-download.
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
        if missing().isEmpty {
            // Closed while it was loading for the first time: once more.
            if wanted { prepare() } else { state = .ready }
        } else if wanted {
            // A download that was going when Jotto last closed: carry on.
            state = .downloading(fraction())
            watchProgress()
            session.getAllTasks { tasks in
                guard tasks.isEmpty else { return }
                Task { @MainActor in self.download() }
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
        state = .downloading(fraction())
        watchProgress()
        fromStore?.cancel()
        fromStore = Task { await downloadFromStore() }
    }

    // MARK: Through the App Store

    /// The asset pack's ID in App Store Connect (letters, digits and
    /// hyphens only) and the folder its files sit in.
    nonisolated static let packID = "qwen3-asr-0-6b"
    nonisolated static let packFolder = "qwen3-asr-0.6b"
    @ObservationIgnored private var fromStore: Task<Void, Never>?

    /// The asset pack, when this build is served one: App Store and
    /// TestFlight builds are, others aren't. Asked with a time limit, as
    /// a build that isn't may not answer at all.
    private static func storePack() async -> AssetPack? {
        await withTaskGroup(of: AssetPack?.self) { group in
            group.addTask {
                if #available(iOS 27, *) {
                    return try? await AssetPackManager.shared.manifest.assetPack(withID: packID)
                }
                return try? await AssetPackManager.shared.assetPack(withID: packID)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func downloadFromStore() async {
        guard let pack = await Self.storePack() else {
            if !Task.isCancelled, wanted { downloadFromWeb(missing()) }
            return
        }
        PhoneLog.shared.note("pack_store", "v\(pack.version) \(pack.downloadSize / 1_000_000) MB")
        let updates = Task { @MainActor [weak self] in
            for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: Self.packID) {
                guard let self else { return }
                if case let .downloading(_, progress) = update, self.downloading {
                    self.lastProgress = .now
                    if self.stalled { self.stalled = false }
                    self.state = .downloading(progress.fractionCompleted)
                }
            }
        }
        defer { updates.cancel() }
        do {
            try await AssetPackManager.shared.ensureLocalAvailability(of: pack)
            guard wanted else { return }
            // Into Jotto's own folder, where the model loads from; on the
            // same disk a copy is a clone, so it takes no more room. Then
            // the pack itself can go.
            try await Task.detached { try Self.copyFromStore() }.value
            try? await AssetPackManager.shared.remove(assetPackWithID: Self.packID)
            PhoneLog.shared.note("pack_store_done")
            if missing().isEmpty { prepare() } else { downloadFromWeb(missing()) }
        } catch {
            guard !Task.isCancelled, wanted else { return }
            PhoneLog.shared.note("pack_store_failed", error.localizedDescription)
            downloadFromWeb(missing())
        }
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
        written = [:]
        state = .downloading(fraction())
        watchProgress()
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

    func cancel() {
        wanted = false
        fromStore?.cancel()
        Task { try? await AssetPackManager.shared.remove(assetPackWithID: Self.packID) }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        written = [:]
        if state != .ready { state = .absent }
    }

    /// Deletes the files. Recordings go back to Apple's model.
    func remove() {
        wanted = false
        fromStore?.cancel()
        Task { try? await AssetPackManager.shared.remove(assetPackWithID: Self.packID) }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        QwenEngine.shared.unload()
        try? FileManager.default.removeItem(at: Self.directory)
        state = .absent
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
                    if quiet { PhoneLog.shared.note("pack_stalled") }
                }
            }
        }
    }

    fileprivate func progressed(_ path: String, _ bytes: Int64) {
        guard downloading else { return }
        lastProgress = .now
        if stalled { stalled = false }
        written[path] = bytes
        state = .downloading(fraction())
    }

    fileprivate func finished(_ path: String) {
        written[path] = nil
        guard downloading else { return }
        if missing().isEmpty { prepare() } else { state = .downloading(fraction()) }
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

    private let queue = DispatchQueue(label: "com.neethanwu.jotto.qwen", qos: .utility)
    private var model: QwenASR?
    private var uses = 0

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

    private func run<T: Sendable>(_ work: @escaping @Sendable (QwenASR) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.model == nil { self.model = try QwenASR(directory: SpeechPack.directory) }
                    let result = try work(self.model!)
                    self.uses += 1
                    let use = self.uses
                    self.queue.asyncAfter(deadline: .now() + 180) {
                        if self.uses == use { self.model = nil }
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
