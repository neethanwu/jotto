import Foundation
import Observation
import WatchConnectivity

/// Queues finished segments for transfer to the phone. WatchConnectivity
/// persists the queue across launches and delivers when the phone is reachable.
@MainActor @Observable
final class WatchTransfer: NSObject {
    static let shared = WatchTransfer()

    private(set) var pendingCount = 0
    /// Parts not yet on the phone, grouped by recording, oldest first.
    private(set) var pending: [PendingRecording] = []
    private(set) var isPhoneReachable = false

    struct PendingRecording: Identifiable {
        let id: String
        let startedAt: Date
        let parts: Int
        let length: TimeInterval
    }

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

    /// Tells the phone a recording started, so it can show it live.
    func sendStart(session: UUID, startedAt: Date) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "kind": "start",
            "session": session.uuidString.lowercased(),
            "sessionStartedAt": startedAt.timeIntervalSince1970,
        ])
    }

    /// A highlight, as seconds from the start of the recording.
    func sendMark(session: UUID, startedAt: Date, offset: TimeInterval) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "kind": "mark",
            "session": session.uuidString.lowercased(),
            "sessionStartedAt": startedAt.timeIntervalSince1970,
            "offset": offset,
        ])
    }

    /// A marked stretch, as seconds from the start of the recording.
    func sendSection(session: UUID, startedAt: Date, start: TimeInterval, end: TimeInterval) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo([
            "kind": "section",
            "session": session.uuidString.lowercased(),
            "sessionStartedAt": startedAt.timeIntervalSince1970,
            "offset": start,
            "end": end,
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

    func refreshPending() {
        let transfers = WCSession.default.outstandingFileTransfers
        pendingCount = transfers.count
        isPhoneReachable = WCSession.default.isReachable
        var groups: [String: (start: Date, parts: Int, length: TimeInterval)] = [:]
        for t in transfers {
            let meta = t.file.metadata ?? [:]
            guard meta["kind"] as? String == "audio",
                  let id = meta["session"] as? String,
                  let started = meta["sessionStartedAt"] as? Double else { continue }
            let g = groups[id] ?? (Date(timeIntervalSince1970: started), 0, 0)
            groups[id] = (g.start, g.parts + 1, g.length + ((meta["duration"] as? Double) ?? 0))
        }
        pending = groups.map { PendingRecording(id: $0.key, startedAt: $0.value.start, parts: $0.value.parts, length: $0.value.length) }
            .sorted { $0.startedAt < $1.startedAt }
    }
}

/// WatchConnectivity's reply handler, carried to the main actor.
private struct Reply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

extension WatchTransfer: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        SpikeLog.shared.log("wc_activated", "state=\(activationState.rawValue) \(error?.localizedDescription ?? "")")
        let sent = History.parse(session.receivedApplicationContext)
        Task { @MainActor in
            self.refreshPending()
            History.shared.phoneSent(sent)
        }
    }

    /// The phone asks: "stop" from its Live screen, or says it marked a
    /// moment or a section there. Live message when the watch app is
    /// reachable (with or without a reply wanted), else queued user info.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // The phone's record button: start here, and say which recording.
        if message["kind"] as? String == "start" {
            let reply = Reply(send: replyHandler)
            Task { @MainActor in
                Recorder.shared.start()
                reply.send(Recorder.shared.sessionInfo)
            }
            return
        }
        let command = (message["kind"] as? String, message["session"] as? String)
        Task { @MainActor in Self.handle(command) }
        replyHandler(["ok": true])
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let command = (message["kind"] as? String, message["session"] as? String)
        Task { @MainActor in Self.handle(command) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let command = (userInfo["kind"] as? String, userInfo["session"] as? String)
        Task { @MainActor in Self.handle(command) }
    }

    private static func handle(_ command: (kind: String?, session: String?)) {
        guard let session = command.session else { return }
        switch command.kind {
        case "stop": Recorder.shared.stopFromPhone(session: session)
        case "mark": Recorder.shared.markedOnPhone(session: session, section: false)
        case "section": Recorder.shared.markedOnPhone(session: session, section: true)
        case "levels": Recorder.shared.phoneWantsLevels(session: session)
        default: break
        }
    }

    /// Levels for the phone's Live screen: live only, nothing queued, since
    /// they're stale a moment later. Outside the main actor, so no handler
    /// inherits its isolation on WatchConnectivity's queue.
    nonisolated static func sendLevels(_ levels: [Float], session id: String) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["kind": "levels", "session": id, "levels": levels.map(Double.init)],
                            replyHandler: nil, errorHandler: nil)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let sent = History.parse(context)
        Task { @MainActor in History.shared.phoneSent(sent) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
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
