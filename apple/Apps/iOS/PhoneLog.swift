import UIKit

/// Test-build log of when the phone wakes and what it does while locked:
/// launches, scene changes, files and messages from the watch, uploads.
/// Lives with the watch's files, so it shows under "Files from the watch".
final class PhoneLog: @unchecked Sendable {
    static let shared = PhoneLog()

    private let url = Inbox.directory.appending(path: "phone-log.csv")
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    private init() {}

    /// Made again if it was deleted from the list while jotto ran. Looked
    /// for by its plain path: the folder's name has a space, and the
    /// percent-encoded one never matched, so each launch began it afresh
    /// and lost everything before.
    private func createIfNeeded() {
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? FileManager.default.createDirectory(at: Inbox.directory, withIntermediateDirectories: true)
        try? Data("time,event,app,protected,detail\n".utf8).write(to: url)
    }

    /// Records the event with the app's state (0 active, 1 inactive, 2 background)
    /// and whether protected files can be read (false while locked).
    @MainActor
    func note(_ event: String, _ detail: String = "") {
        let app = UIApplication.shared.applicationState.rawValue
        let protected = UIApplication.shared.isProtectedDataAvailable
        write("\(formatter.string(from: .now)),\(event),\(app),\(protected),\(detail.replacingOccurrences(of: ",", with: ";"))\n")
    }

    func noteAsync(_ event: String, _ detail: String = "") async {
        await MainActor.run { self.note(event, detail) }
    }

    /// From any thread; the event is noted on the main actor right after.
    nonisolated func later(_ event: String, _ detail: String = "") {
        let at = formatter.string(from: .now)
        Task { @MainActor in self.note(event, "\(detail) at=\(at)") }
    }

    private func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        createIfNeeded()
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
