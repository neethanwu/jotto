import Foundation
import Observation
import UIKit
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

    /// Not Documents/Inbox: that one belongs to the system (files handed
    /// to the app, WatchConnectivity's own store), and an app can't write
    /// there on a device, so the log and the watch's files never landed.
    nonisolated static let directory = URL.documentsDirectory.appending(path: "From watch")

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
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
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

    /// Asks the watch to stop this recording: right away if its app is
    /// reachable, else queued for when it next runs. False if there's no
    /// watch to ask.
    @discardableResult
    func askWatchToStop(_ session: String) -> Bool {
        tellWatch(["kind": "stop", "session": session])
    }

    /// Asks the watch to start recording, if its app is open and in reach
    /// right now; waits a few seconds for it to say it has. The id of the
    /// recording it started, or nil (record on the phone instead).
    func askWatchToStart() async -> String? {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              WCSession.default.isReachable else { return nil }
        PhoneLog.shared.note("ask_watch_start")
        guard let reply = await Self.request(["kind": "start"], timeout: 4),
              let id = reply["session"] as? String,
              let started = (reply["sessionStartedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) else {
            PhoneLog.shared.note("ask_watch_start_failed")
            return nil
        }
        Library.shared.watchStarted(id, at: started)
        Pipeline.shared.started(id, at: started)
        return id
    }

    /// A live message with its reply, or nil on error or after `timeout`.
    nonisolated private static func request(_ message: [String: Any], timeout: TimeInterval) async -> [String: Any]? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        struct Reply: @unchecked Sendable { let value: [String: Any]? }
        let once = Once()
        let reply: Reply = await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(message, replyHandler: { @Sendable value in
                if once.claim() { continuation.resume(returning: Reply(value: value)) }
            }, errorHandler: { @Sendable _ in
                if once.claim() { continuation.resume(returning: Reply(value: nil)) }
            })
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: Reply(value: nil)) }
            }
        }
        return reply.value
    }

    /// The Live screen is open on a recording the watch is making: ask it
    /// to send its levels for a while (asked again every few seconds while
    /// the screen stays open). Only when it's in reach right now; nothing
    /// is queued.
    func askWatchForLevels(_ session: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        Self.sendNow(["kind": "levels", "session": session])
    }

    nonisolated private static func sendNow(_ message: [String: Any]) {
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    /// A mark or section made on the phone's Live screen, so the watch's
    /// count includes it.
    func tellWatchMarked(_ session: String, section: Bool) {
        tellWatch(["kind": section ? "section" : "mark", "session": session])
    }

    /// A live message when the watch app is reachable (with a reply, so a
    /// failure is known), else queued user info. The watch handles both.
    @discardableResult
    private func tellWatch(_ message: [String: Any]) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return false }
        let kind = message["kind"] as? String ?? "?"
        PhoneLog.shared.note("tell_watch", "\(kind) reachable=\(WCSession.default.isReachable)")
        Self.send(message, kind: kind)
        return true
    }

    /// Built outside the main actor: WatchConnectivity calls the reply and
    /// error handlers on its own queue, and a closure written in a
    /// main-actor method inherits that isolation, which Swift 6 traps on
    /// (the crash on Mark, Section and stop in build 202611120345).
    nonisolated private static func send(_ message: [String: Any], kind: String) {
        let session = WCSession.default
        guard session.isReachable else {
            session.transferUserInfo(message)
            return
        }
        session.sendMessage(message, replyHandler: { @Sendable _ in
            PhoneLog.shared.later("tell_watch_ok", kind)
        }, errorHandler: { @Sendable error in
            PhoneLog.shared.later("tell_watch_failed", "\(kind) \(error.localizedDescription)")
            WCSession.default.transferUserInfo(message)
        })
    }

    /// Tells the watch which recordings the phone has from the last week,
    /// so its "2 today · 4 min" line drops ones deleted here. The latest
    /// context replaces any earlier one still on its way.
    func syncHistory() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
        let items: [[String: Double]] = LocalStore.shared.recordings.values.compactMap { r in
            guard r.startedAt > weekAgo, let ended = r.endedAt else { return nil }
            return ["startedAt": r.startedAt.timeIntervalSince1970, "length": ended.timeIntervalSince(r.startedAt)]
        }
        do {
            try WCSession.default.updateApplicationContext(["history": items, "at": Date.now.timeIntervalSince1970])
        } catch {
            PhoneLog.shared.note("history_sync_failed", error.localizedDescription)
        }
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
        Task { @MainActor in
            self.watchStatus = status
            self.syncHistory()
        }
    }

    /// The file is deleted when this returns, so move it synchronously.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let meta = file.metadata ?? [:]
        PhoneLog.shared.later("wc_file", "kind=\(meta["kind"] as? String ?? "?") index=\(meta["index"] as? Int ?? -1)")
        if let segment = SegmentInfo(meta) {
            let destination = AudioFiles.url(session: segment.session, index: segment.index)
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: file.fileURL, to: destination)
            } catch {
                PhoneLog.shared.later("wc_file_move_failed", error.localizedDescription)
                return
            }
            Task { @MainActor in
                Library.shared.watchSent(segment.session, startedAt: segment.sessionStartedAt, index: segment.index)
                Pipeline.shared.segmentArrived(
                    segment.session, startedAt: segment.sessionStartedAt,
                    index: segment.index, offset: segment.offset, duration: segment.duration
                )
            }
            return
        }

        // The watch's log comes whole after every recording: keep the
        // latest only, where every copy used to pile up.
        let isLog = meta["kind"] as? String == "log"
        let name = isLog ? "watch-log.csv" : (meta["name"] as? String) ?? file.fileURL.lastPathComponent
        let destination = Self.directory.appending(path: name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: file.fileURL, to: destination)
        if isLog { Self.removeOldWatchLogs() }
        Task { @MainActor in self.reload() }
    }

    /// Copies kept from before, named spike-log-<time>.csv; each was the
    /// whole log at the time, so the latest has everything they had.
    nonisolated private static func removeOldWatchLogs() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix("spike-log-") && name.hasSuffix(".csv") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let offset = (userInfo["offset"] as? Double).map { " offset=\(Int($0))s" } ?? ""
        PhoneLog.shared.later("wc_info", "kind=\(userInfo["kind"] as? String ?? "?")\(offset)")
        guard let id = userInfo["session"] as? String,
              let started = (userInfo["sessionStartedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        else { return }
        switch userInfo["kind"] as? String {
        case "start":
            Task { @MainActor in
                Library.shared.watchStarted(id, at: started)
                Pipeline.shared.started(id, at: started)
            }
        case "mark":
            guard let offset = userInfo["offset"] as? Double else { return }
            Task { @MainActor in
                Pipeline.shared.marked(id, startedAt: started, offset: offset)
            }
        case "section":
            guard let start = userInfo["offset"] as? Double, let end = userInfo["end"] as? Double else { return }
            Task { @MainActor in
                Pipeline.shared.markedSection(id, startedAt: started, start: start, end: end)
            }
        case "finish":
            guard let ended = userInfo["endedAt"] as? Double,
                  let count = userInfo["segmentCount"] as? Int else { return }
            let endedAt = Date(timeIntervalSince1970: ended)
            Task { @MainActor in
                Library.shared.watchFinished(id, startedAt: started, endedAt: endedAt, segmentCount: count)
                Pipeline.shared.finished(id, startedAt: started, endedAt: endedAt, segmentCount: count)
            }
        default:
            break
        }
    }

    /// The watch's nudge after each part it sends. Its parts and messages
    /// come by background transfer, which iOS holds until jotto next runs;
    /// a live message is what wakes jotto, and the parts waiting arrive
    /// with it. Then the pipeline works through them.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(["ok": true])
        guard message["kind"] as? String == "wake" else { return }
        let reason = message["reason"] as? String ?? "?"
        // The start's own nudge carries the start, ahead of the queued copy.
        let start = (message["session"] as? String).flatMap { id in
            (message["sessionStartedAt"] as? Double).map { (id, Date(timeIntervalSince1970: $0)) }
        }
        Task { @MainActor in
            let left = UIApplication.shared.backgroundTimeRemaining
            PhoneLog.shared.note("wc_wake", "\(reason) left=\(left > 999 ? "-" : "\(Int(left))s")")
            if let (id, started) = start {
                Library.shared.watchStarted(id, at: started)
                Pipeline.shared.started(id, at: started)
            }
            Pipeline.shared.woken(reason)
        }
    }

    /// Live from the watch: its levels, for the Live screen's strip.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["kind"] as? String == "levels", let id = message["session"] as? String,
              let values = message["levels"] as? [Double] else { return }
        let levels = values.map(Float.init)
        Task { @MainActor in LiveLevels.shared.received(id, levels) }
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
