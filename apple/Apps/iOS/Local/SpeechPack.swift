import Foundation
import Observation
import UIKit

/// The speech model you can download: Qwen3-ASR 0.6B, about 950 MB, for
/// recordings with Chinese and English mixed together. Never downloaded
/// unless asked for (Settings → Processing). The files come from Hugging
/// Face at fixed revisions, in a background download that carries on
/// when Jotto isn't open; nothing about your recordings is sent.
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

    static let name = "Qwen3-ASR"
    static let sizeLabel = "950 MB"

    private struct File {
        let path: String
        let size: Int64
        let base: String
    }

    private static let models = "https://huggingface.co/aufklarer/Qwen3-ASR-CoreML/resolve/8c6bc87b87856930b435550e94ce47de710ce4ed/"
    private static let tokenizer = "https://huggingface.co/Qwen/Qwen3-ASR-0.6B/resolve/5eb144179a02acc5e5ba31e748d22b0cf3e303b0/"

    private static let files: [File] = [
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

    private static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

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
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        written = [:]
        if state != .ready { state = .absent }
    }

    /// Deletes the files. Recordings go back to Apple's model.
    func remove() {
        wanted = false
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

    fileprivate func progressed(_ path: String, _ bytes: Int64) {
        guard downloading else { return }
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
