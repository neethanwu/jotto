import UIKit

/// Test-build log of when the phone wakes and what it does while locked:
/// launches, scene changes, files and messages from the watch, uploads.
/// Lives in the Inbox folder, so it shows under "Files from the watch".
final class PhoneLog: @unchecked Sendable {
    static let shared = PhoneLog()

    private let url = Inbox.directory.appending(path: "phone-log.csv")
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    private init() {
        try? FileManager.default.createDirectory(at: Inbox.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path()) {
            try? Data("time,event,app,protected,detail\n".utf8).write(to: url)
        }
    }

    /// Records the event with the app's state (0 active, 1 inactive, 2 background)
    /// and whether protected files can be read (false while locked).
    @MainActor
    func note(_ event: String, _ detail: String = "") {
        let app = UIApplication.shared.applicationState.rawValue
        let protected = UIApplication.shared.isProtectedDataAvailable
        write("\(formatter.string(from: .now)),\(event),\(app),\(protected),\(detail.replacingOccurrences(of: ",", with: ";"))\n")
    }

    /// From any thread; the event is noted on the main actor right after.
    nonisolated func later(_ event: String, _ detail: String = "") {
        let at = formatter.string(from: .now)
        Task { @MainActor in self.note(event, "\(detail) at=\(at)") }
    }

    private func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
