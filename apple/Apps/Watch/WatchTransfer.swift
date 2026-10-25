import Foundation
import Observation
import WatchConnectivity

/// Queues finished segments for transfer to the phone. WatchConnectivity
/// persists the queue across launches and delivers when the phone is reachable.
@MainActor @Observable
final class WatchTransfer: NSObject {
    static let shared = WatchTransfer()

    private(set) var pendingCount = 0

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Audio segment plus what the phone needs to upload it on its own.
    func sendSegment(_ segment: ClosedSegment, session: UUID, sessionStartedAt: Date) {
        send(segment.url, kind: "audio", extra: [
            "session": session.uuidString.lowercased(),
            "sessionStartedAt": sessionStartedAt.timeIntervalSince1970,
            "index": segment.index,
            "offset": segment.startedAt.timeIntervalSince(sessionStartedAt),
            "duration": segment.endedAt.timeIntervalSince(segment.startedAt),
        ])
    }

    /// Tells the phone the recording ended. `transferUserInfo` is queued and
    /// guaranteed like file transfers, and may arrive before the last segment.
    func sendFinish(session: UUID, startedAt: Date, endedAt: Date, segmentCount: Int) {
        WCSession.default.transferUserInfo([
            "kind": "finish",
            "session": session.uuidString.lowercased(),
            "sessionStartedAt": startedAt.timeIntervalSince1970,
            "endedAt": endedAt.timeIntervalSince1970,
            "segmentCount": segmentCount,
        ])
        SpikeLog.shared.log("finish_sent", "\(session.uuidString) segments=\(segmentCount)")
    }

    func send(_ url: URL, kind: String, extra: [String: Any] = [:]) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            SpikeLog.shared.log("transfer_skipped", "\(kind) session not active")
            return
        }
        var metadata: [String: Any] = ["kind": kind, "name": url.lastPathComponent]
        metadata.merge(extra) { _, new in new }
        session.transferFile(url, metadata: metadata)
        refreshPending()
    }

    private func refreshPending() {
        pendingCount = WCSession.default.outstandingFileTransfers.count
    }
}

extension WatchTransfer: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        SpikeLog.shared.log("wc_activated", "state=\(activationState.rawValue) \(error?.localizedDescription ?? "")")
        Task { @MainActor in self.refreshPending() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        if let error {
            SpikeLog.shared.log("transfer_failed", "\(url.lastPathComponent) \(error.localizedDescription)")
        } else {
            // The phone owns the audio now; free watch storage.
            try? FileManager.default.removeItem(at: url)
        }
        Task { @MainActor in self.refreshPending() }
    }
}
