import Foundation

/// Append-only CSV log for Spike 0 measurements (battery, interruptions, lifecycle).
/// Transferred to the phone whenever a recording stops.
final class SpikeLog: @unchecked Sendable {
    static let shared = SpikeLog()

    private static let header = "time,event,battery,detail\n"
    /// Past this the older half goes: the log is written, and sent to the
    /// phone after each recording, in App Store builds too.
    private static let limit = 256 * 1024

    let url: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    private init() {
        let docs = URL.documentsDirectory
        url = docs.appending(path: "spike-log.csv")
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try? Data(Self.header.utf8).write(to: url)
        }
    }

    func log(_ event: String, battery: Float? = nil, _ detail: String = "") {
        let batteryText = battery.map { String(format: "%.2f", $0) } ?? ""
        let safeDetail = detail.replacingOccurrences(of: ",", with: ";")
        let line = "\(formatter.string(from: .now)),\(event),\(batteryText),\(safeDetail)\n"

        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        let size = (try? handle.offset()) ?? 0
        try? handle.close()
        if size > Self.limit { trim() }
    }

    /// Keeps the newer half, from a line's start, under the header.
    private func trim() {
        guard let data = try? Data(contentsOf: url) else { return }
        let newer = data.suffix(Self.limit / 2)
        let start = newer.firstIndex(of: UInt8(ascii: "\n")).map { newer.index(after: $0) } ?? newer.startIndex
        try? (Data(Self.header.utf8) + newer[start...]).write(to: url, options: .atomic)
    }

    /// Copies the log to a temp file so it can be transferred while we keep appending.
    func snapshot() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let copy = URL.temporaryDirectory.appending(path: "spike-log-\(Int(Date.now.timeIntervalSince1970)).csv")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }
}
