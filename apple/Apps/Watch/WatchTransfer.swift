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

    func send(_ url: URL, kind: String) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            SpikeLog.shared.log("transfer_skipped", "\(kind) session not active")
            return
        }
        session.transferFile(url, metadata: ["kind": kind, "name": url.lastPathComponent])
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
