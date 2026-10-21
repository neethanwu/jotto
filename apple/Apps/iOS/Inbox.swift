import Foundation
import Observation
import WatchConnectivity

/// Receives audio segments and spike logs from the watch and keeps them in
/// Documents/Inbox. Spike-only: the real app will ingest into a proper store.
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
        let name = (file.metadata?["name"] as? String) ?? file.fileURL.lastPathComponent
        let destination = Self.directory.appending(path: name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: file.fileURL, to: destination)
        Task { @MainActor in self.reload() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
