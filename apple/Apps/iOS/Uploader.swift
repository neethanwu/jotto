import Foundation
import Observation

/// Pushes watch segments and "recording finished" notices to the backend.
///
/// Jobs are persisted to disk and sent with a background URLSession, so an
/// upload keeps going while the app is suspended and the queue survives a
/// relaunch. Every call is idempotent on the server, and each one carries the
/// session's start time, so jobs can complete in any order.
@MainActor @Observable
final class Uploader: NSObject {
    static let shared = Uploader()

    struct Job: Codable, Identifiable {
        enum Kind: Codable {
            case segment(index: Int, offset: Double, duration: Double)
            case finish(segmentCount: Int, endedAt: Date)
        }

        var id = UUID()
        let session: String
        let sessionStartedAt: Date
        let kind: Kind
        var attempts = 0
        var notBefore = Date.distantPast
        var lastError: String?
    }

    private(set) var jobs: [Job] = []
    private(set) var lastError: String?

    /// Set by the app delegate when iOS relaunches us for background events.
    var backgroundCompletion: (() -> Void)?

    nonisolated static let sessionsDirectory = URL.documentsDirectory.appending(path: "Sessions")
    private static let queueFile = URL.documentsDirectory.appending(path: "upload-queue.json")
    private static let bodiesDirectory = URL.documentsDirectory.appending(path: "UploadBodies")

    /// Full ISO 8601 with time zone, e.g. 2026-10-25T09:04:00.656Z.
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private var inFlight: Set<UUID> = []
    private var retryTask: Task<Void, Never>?

    @ObservationIgnored
    private lazy var urlSession: URLSession = {
        #if targetEnvironment(simulator)
        // The simulator's background transfer daemon fails every task with
        // NSURLErrorUnknown; a foreground session exercises the same code.
        let config = URLSessionConfiguration.default
        #else
        let config = URLSessionConfiguration.background(withIdentifier: "com.neethanwu.jotto.upload")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        #endif
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        for dir in [Self.sessionsDirectory, Self.bodiesDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: Self.queueFile) {
            jobs = (try? JSONDecoder().decode([Job].self, from: data)) ?? []
        }
        // Tasks from a previous launch may still be running in the background.
        urlSession.getAllTasks { tasks in
            let ids = Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
            Task { @MainActor in
                self.inFlight = ids
                self.pump()
            }
        }
    }

    nonisolated static func audioURL(session: String, index: Int) -> URL {
        sessionsDirectory.appending(path: session).appending(path: String(format: "%03d.m4a", index))
    }

    // MARK: - Enqueue

    func enqueue(_ job: Job) {
        jobs.append(job)
        save()
        pump()
    }

    /// Retry everything now (e.g. after fixing settings).
    func retryAll() {
        for i in jobs.indices { jobs[i].notBefore = .distantPast }
        save()
        pump()
    }

    // MARK: - Sending

    func pump() {
        guard AppConfig.shared.isReady else {
            lastError = jobs.isEmpty ? nil : "No server yet, so recordings wait on this iPhone"
            return
        }
        let now = Date.now
        for job in jobs where !inFlight.contains(job.id) && job.notBefore <= now {
            do {
                let (request, body) = try makeRequest(job)
                let task = urlSession.uploadTask(with: request, fromFile: body)
                task.taskDescription = job.id.uuidString
                inFlight.insert(job.id)
                task.resume()
            } catch {
                fail(job.id, message: error.localizedDescription, permanent: true)
            }
        }
        scheduleRetry()
    }

    private func makeRequest(_ job: Job) throws -> (URLRequest, URL) {
        let started = job.sessionStartedAt.ISO8601Format(Self.timestamp)
        switch job.kind {
        case let .segment(index, offset, duration):
            var request = try API.request("\(job.session)/segments/\(index)", method: "PUT")
            request.url = request.url?.appending(queryItems: [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "duration", value: String(duration)),
                URLQueryItem(name: "startedAt", value: started),
            ])
            request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
            let file = Self.audioURL(session: job.session, index: index)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return (request, file)

        case let .finish(segmentCount, endedAt):
            var request = try API.request("\(job.session)/finish", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Background sessions can only upload from a file.
            let body = Self.bodiesDirectory.appending(path: "\(job.id.uuidString).json")
            let json: [String: Any] = [
                "segmentCount": segmentCount,
                "endedAt": endedAt.ISO8601Format(Self.timestamp),
                "startedAt": started,
            ]
            try JSONSerialization.data(withJSONObject: json).write(to: body)
            return (request, body)
        }
    }

    private func complete(_ id: UUID, status: Int, error: Error?) {
        inFlight.remove(id)
        try? FileManager.default.removeItem(at: Self.bodiesDirectory.appending(path: "\(id.uuidString).json"))

        if error == nil, (200..<300).contains(status) {
            jobs.removeAll { $0.id == id }
            if jobs.allSatisfy({ $0.lastError == nil }) { lastError = nil }
            save()
            return
        }
        let message = error.map { e in
            let ns = e as NSError
            return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        } ?? "HTTP \(status)"
        // 400 means the request itself is wrong; retrying won't help.
        fail(id, message: message, permanent: status == 400)
    }

    private func fail(_ id: UUID, message: String, permanent: Bool) {
        inFlight.remove(id)
        lastError = message
        if permanent {
            jobs.removeAll { $0.id == id }
        } else if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].attempts += 1
            jobs[i].lastError = message
            // 10 s, 20 s, 40 s … capped at 10 minutes.
            let delay = min(600, 10 * pow(2, Double(jobs[i].attempts - 1)))
            jobs[i].notBefore = .now.addingTimeInterval(delay)
        }
        save()
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let waiting = jobs.filter { !inFlight.contains($0.id) && $0.notBefore > .now }
        guard let next = waiting.map(\.notBefore).min() else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: Self.queueFile, options: .atomic)
    }
}

extension Uploader: URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        Task { @MainActor in self.complete(id, status: status, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

#if DEBUG
extension Uploader {
    /// Simulator stand-in for the watch: queue a folder of m4a clips as one
    /// recording (`JOTTO_DEMO_AUDIO_DIR`, first `JOTTO_DEMO_LIMIT` clips, 2 min each).
    func enqueueDemoRecordingIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["JOTTO_DEMO_AUDIO_DIR"] else { return }
        let limit = Int(env["JOTTO_DEMO_LIMIT"] ?? "") ?? 3
        let clips = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".m4a") }
            .sorted()
            .prefix(limit)
        let session = UUID().uuidString.lowercased()
        let started = Date.now.addingTimeInterval(-Double(clips.count) * 120)
        for (index, clip) in clips.enumerated() {
            let destination = Self.audioURL(session: session, index: index)
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(atPath: "\(dir)/\(clip)", toPath: destination.path)
            enqueue(.init(
                session: session, sessionStartedAt: started,
                kind: .segment(index: index, offset: Double(index) * 120, duration: 120)
            ))
        }
        enqueue(.init(
            session: session, sessionStartedAt: started,
            kind: .finish(segmentCount: clips.count, endedAt: .now)
        ))
    }
}
#endif
