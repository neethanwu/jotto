import Foundation
import Observation
import WatchConnectivity

/// Receives everything the watch sends. Recording segments go to
/// Documents/Sessions and into the upload queue; anything else (spike logs,
/// segments from older builds without session info) lands in Documents/Inbox.
@MainActor @Observable
final class Inbox: NSObject {
    static let shared = Inbox()

    struct Item: Identifiable, Hashable {
        let url: URL
        let size: Int
        let date: Date
        var id: URL { url }
        var isAudio: Bool { url.pathExtension == "m4a" }
    }

    private(set) var items: [Item] = []
    private(set) var watchStatus = "connecting…"

    nonisolated static let directory = URL.documentsDirectory.appending(path: "Inbox")

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        reload()
        guard WCSession.isSupported() else {
            watchStatus = "WatchConnectivity unsupported"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func reload() {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: keys
        )) ?? []
        items = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Item(url: url, size: values?.fileSize ?? 0, date: values?.creationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }
}

extension Inbox: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let status = error?.localizedDescription
            ?? (session.isPaired ? (session.isWatchAppInstalled ? "watch app installed" : "watch app not installed") : "no paired watch")
        Task { @MainActor in self.watchStatus = status }
    }

    /// The file is deleted when this returns, so move it synchronously.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let meta = file.metadata ?? [:]
        if let segment = SegmentInfo(meta) {
            let destination = Uploader.audioURL(session: segment.session, index: segment.index)
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: file.fileURL, to: destination)
            } catch {
                return
            }
            Task { @MainActor in
                Library.shared.watchSent(segment.session, startedAt: segment.sessionStartedAt, index: segment.index)
                Uploader.shared.enqueue(.init(
                    session: segment.session,
                    sessionStartedAt: segment.sessionStartedAt,
                    kind: .segment(index: segment.index, offset: segment.offset, duration: segment.duration)
                ))
            }
            return
        }

        let name = (meta["name"] as? String) ?? file.fileURL.lastPathComponent
        let destination = Self.directory.appending(path: name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: file.fileURL, to: destination)
        Task { @MainActor in self.reload() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let id = userInfo["session"] as? String,
              let started = (userInfo["sessionStartedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        else { return }
        switch userInfo["kind"] as? String {
        case "start":
            Task { @MainActor in Library.shared.watchStarted(id, at: started) }
        case "finish":
            guard let ended = userInfo["endedAt"] as? Double,
                  let count = userInfo["segmentCount"] as? Int else { return }
            let endedAt = Date(timeIntervalSince1970: ended)
            Task { @MainActor in
                Library.shared.watchFinished(id, startedAt: started, endedAt: endedAt, segmentCount: count)
                Uploader.shared.enqueue(.init(
                    session: id,
                    sessionStartedAt: started,
                    kind: .finish(segmentCount: count, endedAt: endedAt)
                ))
            }
        default:
            break
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

/// Metadata the watch attaches to each recording segment (`WatchTransfer.sendSegment`).
private struct SegmentInfo {
    let session: String
    let sessionStartedAt: Date
    let index: Int
    let offset: Double
    let duration: Double

    init?(_ meta: [String: Any]) {
        guard meta["kind"] as? String == "audio",
              let session = meta["session"] as? String,
              let started = meta["sessionStartedAt"] as? Double,
              let index = meta["index"] as? Int,
              let offset = meta["offset"] as? Double,
              let duration = meta["duration"] as? Double else { return nil }
        self.session = session
        self.sessionStartedAt = Date(timeIntervalSince1970: started)
        self.index = index
        self.offset = offset
        self.duration = duration
    }
}
