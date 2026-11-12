import AVFoundation
import Observation
import UserNotifications
import WatchKit
import WidgetKit

/// Background audio capture into rolling segments, with logging for
/// battery drain, interruptions and recovery (the Spike 0 log).
@MainActor @Observable
final class Recorder {
    /// One recorder per app, so App Intents (controls, Action Button) can reach it.
    static let shared = Recorder()

    enum State: String {
        case idle, recording, interrupted
    }

    private(set) var state: State = .idle
    private(set) var startedAt: Date?
    private var sessionID: UUID?
    private(set) var segmentsWritten = 0
    private(set) var lastEvent = "—"
    /// Recent input levels, 0…1, newest last, for the level bars.
    private(set) var levels: [Float] = Array(repeating: 0, count: Recorder.levelCount)
    /// The recording that just ended, shown on the Saved screen.
    private(set) var justSaved: (length: TimeInterval, sentNow: Bool)?
    /// Highlights in this recording, moments and sections, made here or
    /// on the phone; and when the last moment was, for feedback.
    private(set) var marks = 0
    private(set) var lastMarkAt: Date?
    /// When the section being marked began, while one is open.
    private(set) var sectionStartedAt: Date?
    private var sectionLimitTask: Task<Void, Never>?
    /// A forgotten section ends by itself.
    static let sectionLimit: TimeInterval = 600

    static let levelCount = 30
    private let meter = LevelMeter()
    private var meterTask: Task<Void, Never>?

    /// Short segments keep transfers small and give Spike 1 plenty of clips.
    let segmentDuration: TimeInterval = 120

    private let engine = AVAudioEngine()
    private var writer: SegmentWriter?
    private var observers: [NSObjectProtocol] = []
    private var batteryTask: Task<Void, Never>?
    private let log = SpikeLog.shared

    private var battery: Float { WKInterfaceDevice.current().batteryLevel }

    private init() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        observeSession()
        updateFace()
    }

    // MARK: - Control

    /// Which recording is going, for the phone that asked to start one.
    var sessionInfo: [String: Any] {
        guard state != .idle, let sessionID, let startedAt else { return ["ok": false] }
        return ["ok": true, "session": sessionID.uuidString.lowercased(), "sessionStartedAt": startedAt.timeIntervalSince1970]
    }

    func toggle() {
        state == .idle ? start() : stop()
    }

    /// What the Action Button and the control do: start when idle, mark when recording.
    func primaryAction(source: String) {
        note("primary_action", "source=\(source) state=\(state.rawValue) app=\(WKApplication.shared().applicationState.rawValue)")
        if state == .idle { start() } else { mark(source: source) }
    }

    /// Marks this moment as a highlight without pausing the recording.
    func mark(source: String = "screen") {
        guard state != .idle, let sessionID, let startedAt else { return }
        let offset = Date.now.timeIntervalSince(startedAt)
        marks += 1
        lastMarkAt = .now
        WKInterfaceDevice.current().play(.click)
        WatchTransfer.shared.sendMark(session: sessionID, startedAt: startedAt, offset: offset)
        note("mark", "offset=\(Int(offset))s source=\(source)")
    }

    /// The [ ] button: the first press opens a section, the second ends it.
    func toggleSection() {
        if sectionStartedAt == nil { beginSection() } else { endSection(reason: "button") }
    }

    private func beginSection() {
        guard state != .idle, sessionID != nil else { return }
        sectionStartedAt = .now
        WKInterfaceDevice.current().play(.directionUp)
        note("section_begin")
        sectionLimitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.sectionLimit))
            guard !Task.isCancelled else { return }
            self?.endSection(reason: "limit")
        }
    }

    private func endSection(reason: String) {
        sectionLimitTask?.cancel()
        sectionLimitTask = nil
        guard let begin = sectionStartedAt, let sessionID, let startedAt else { return }
        sectionStartedAt = nil
        // Stopping has its own haptic.
        if reason != "stop" { WKInterfaceDevice.current().play(.directionDown) }
        let start = begin.timeIntervalSince(startedAt)
        let end = Date.now.timeIntervalSince(startedAt)
        marks += 1
        WatchTransfer.shared.sendSection(session: sessionID, startedAt: startedAt, start: start, end: end)
        note("section_end", "start=\(Int(start))s end=\(Int(end))s reason=\(reason)")
    }

    func start() {
        guard state == .idle else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            note("session_error", error.localizedDescription)
            return
        }

        let directory = URL.documentsDirectory.appending(path: "Segments")
        let sessionID = UUID()
        let startedAt = Date.now
        writer = SegmentWriter(
            directory: directory,
            sessionID: sessionID,
            maxDuration: segmentDuration,
            onSegmentClosed: { [weak self] segment in
                // Captures the session values: the recorder may already have
                // stopped by the time the last segment closes.
                Task { @MainActor in
                    self?.segmentsWritten += 1
                    WatchTransfer.shared.sendSegment(segment, session: sessionID, sessionStartedAt: startedAt)
                }
            },
            onError: { message in
                SpikeLog.shared.log("writer_error", message)
            }
        )

        guard startEngine() else {
            writer = nil
            return
        }
        state = .recording
        self.startedAt = startedAt
        self.sessionID = sessionID
        segmentsWritten = 0
        marks = 0
        lastMarkAt = nil
        sectionStartedAt = nil
        justSaved = nil
        // Needed for the "tap to keep recording" notice after a call.
        // (Skipped for simulator screenshots, where the prompt would cover the screen.)
        if ProcessInfo.processInfo.environment["JOTTO_AUTOSTART"] == nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        WatchTransfer.shared.sendStart(session: sessionID, startedAt: startedAt)
        updateFace()
        WKInterfaceDevice.current().play(.start)
        note("start", sessionID.uuidString)
        startBatteryLogging()
        startMetering()
    }

    func stop() {
        guard state != .idle else { return }
        endSection(reason: "stop")
        stopEngine()
        let segmentCount = writer?.finish() ?? 0
        writer = nil
        if let sessionID, let startedAt {
            let endedAt = Date.now
            WatchTransfer.shared.sendFinish(
                session: sessionID, startedAt: startedAt, endedAt: endedAt, segmentCount: segmentCount
            )
            History.shared.add(startedAt: startedAt, length: endedAt.timeIntervalSince(startedAt))
            justSaved = (endedAt.timeIntervalSince(startedAt), WatchTransfer.shared.isPhoneReachable)
        }
        WKInterfaceDevice.current().play(.stop)
        meterTask?.cancel()
        levels = Array(repeating: 0, count: Self.levelCount)
        sessionID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        batteryTask?.cancel()
        batteryTask = nil
        state = .idle
        startedAt = nil
        updateFace()
        note("stop")

        if let snapshot = log.snapshot() {
            WatchTransfer.shared.send(snapshot, kind: "log")
        }
    }

    /// Held the dot on the phone's Live screen. Only for the recording
    /// still going, so a late message can't stop a new one.
    func stopFromPhone(session: String) {
        guard state != .idle, sessionID?.uuidString.lowercased() == session.lowercased() else {
            note("phone_stop_ignored", session)
            return
        }
        note("phone_stop")
        stop()
    }

    /// Marked on the phone's Live screen: counts here too, and a moment
    /// flashes the star as if pressed.
    func markedOnPhone(session: String, section: Bool) {
        guard state != .idle, sessionID?.uuidString.lowercased() == session.lowercased() else { return }
        marks += 1
        if !section {
            lastMarkAt = .now
            WKInterfaceDevice.current().play(.click)
        }
        note("phone_mark", section ? "section" : "moment")
    }

    /// The watch-face complication: recording or not, and today's line.
    func updateFace() {
        let today = History.shared.today
        WatchFace.save(.init(recordingSince: state == .idle ? nil : startedAt,
                             todayCount: today.count, todaySeconds: today.map(\.length).reduce(0, +)))
        WidgetCenter.shared.reloadTimelines(ofKind: WatchFace.kind)
    }

    func dismissSaved() {
        justSaved = nil
    }

    // MARK: - Engine

    /// Samples the meter ten times a second while recording.
    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.levels.removeFirst()
                self.levels.append(self.meter.take())
            }
        }
    }

    @discardableResult
    private func startEngine() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let writer else {
            note("engine_error", "no input format")
            return false
        }

        note("engine_format", "\(Int(format.sampleRate)) Hz \(format.channelCount) ch")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(writer: writer, meter: meter))
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            input.removeTap(onBus: 0)
            note("engine_error", error.localizedDescription)
            return false
        }
    }

    /// Runs on the audio render thread. Built outside the main actor: a
    /// closure written inside a main-actor method inherits that isolation,
    /// and Swift 6 traps when the audio thread calls it.
    nonisolated private static func tap(writer: SegmentWriter, meter: LevelMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            writer.append(buffer)
            meter.add(buffer)
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Restart after an interruption or route/config change. Closes the
    /// current segment so a gap in the audio never hides inside one file.
    @discardableResult
    private func recover(reason: String) -> Bool {
        guard state != .idle else { return false }
        stopEngine()
        writer?.finish()
        let app = WKApplication.shared().applicationState.rawValue
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            state = .interrupted
            note("recover_failed", "\(reason) app=\(app): \(error.localizedDescription)")
            return false
        }
        if startEngine() {
            state = .recording
            note("recovered", "\(reason) app=\(app)")
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.pausedNotice])
            return true
        } else {
            state = .interrupted
            return false
        }
    }

    /// After a call: try a few times (activation can fail for a moment
    /// while the call's audio winds down), then ask for one tap.
    private func resumeAfterInterruption() {
        Task { [weak self] in
            for (attempt, delay) in [0, 1, 3].enumerated() {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, self.state == .interrupted else { return }
                if self.recover(reason: "interruption_ended#\(attempt + 1)") { return }
            }
            self?.notifyPaused()
        }
    }

    /// Coming to the foreground counts as the user's go-ahead to resume.
    func resumeIfInterrupted() {
        guard state == .interrupted else { return }
        recover(reason: "foreground")
    }

    private static let pausedNotice = "paused"

    private func notifyPaused() {
        let content = UNMutableNotificationContent()
        content.title = "Recording paused"
        content.body = "Tap to keep recording."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: Self.pausedNotice, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        note("paused_notice")
    }

    // MARK: - Observation

    private func observeSession() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo ?? [:]
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawReason = info[AVAudioSessionInterruptionReasonKey] as? UInt
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(rawType: rawType, rawReason: rawReason, rawOptions: rawOptions)
            }
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover(reason: "config_change") }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover(reason: "media_services_reset") }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.note("route_change", "reason=\(reason ?? 0)") }
        })
    }

    private func handleInterruption(rawType: UInt?, rawReason: UInt?, rawOptions: UInt?) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            guard state != .idle else { return }
            state = .interrupted
            writer?.finish()
            note("interrupt_began", "reason=\(rawReason ?? 0) app=\(WKApplication.shared().applicationState.rawValue)")
        case .ended:
            note("interrupt_ended", "options=\(rawOptions ?? 0) app=\(WKApplication.shared().applicationState.rawValue)")
            // Always try to resume: an always-on recorder should not wait for permission.
            resumeAfterInterruption()
        @unknown default:
            break
        }
    }

    private func startBatteryLogging() {
        batteryTask?.cancel()
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                let elapsed = Int(Date.now.timeIntervalSince(self.startedAt ?? .now))
                let appState = WKApplication.shared().applicationState.rawValue
                self.log.log("tick", battery: self.battery, "elapsed=\(elapsed)s segments=\(self.segmentsWritten) state=\(self.state.rawValue) app=\(appState)")
            }
        }
    }

    func lifecycle(_ phase: String) {
        log.log("lifecycle", battery: battery, phase)
    }

    private func note(_ event: String, _ detail: String = "") {
        lastEvent = event
        log.log(event, battery: battery, detail)
    }
}

/// Peak level of the audio since it was last read. Written on the audio
/// thread, read on the main actor.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in stride(from: 0, to: n, by: 2) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(max(1, n / 2)))
        lock.lock()
        peak = max(peak, rms)
        lock.unlock()
    }

    /// 0…1 on a rough speech scale (−50 dB … −10 dB).
    func take() -> Float {
        lock.lock()
        let value = peak
        peak = 0
        lock.unlock()
        let db = 20 * log10(max(value, 1e-6))
        return min(1, max(0, (db + 50) / 40))
    }
}

/// Recordings for the "4 today · 3 h 18" line: the phone's list (so ones
/// deleted there go), plus ones made here that the phone may not have yet.
@MainActor @Observable
final class History {
    static let shared = History()
    private let key = "history"
    private let phoneKey = "historyFromPhone"

    struct Item: Codable {
        let startedAt: Date
        let length: TimeInterval
    }

    private struct FromPhone: Codable {
        var items: [Item]
        var at: Date
    }

    /// Made on this watch, the last week.
    private var items: [Item]
    private var phone: FromPhone?

    private init() {
        let defaults = UserDefaults.standard
        items = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
        phone = defaults.data(forKey: phoneKey).flatMap { try? JSONDecoder().decode(FromPhone.self, from: $0) }
    }

    func add(startedAt: Date, length: TimeInterval) {
        let weekAgo = Date.now.addingTimeInterval(-7 * 86400)
        items = items.filter { $0.startedAt > weekAgo } + [Item(startedAt: startedAt, length: length)]
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }

    /// The phone's list, read from its application context.
    nonisolated static func parse(_ context: [String: Any]) -> (items: [Item], at: Date)? {
        guard let raw = context["history"] as? [[String: Double]], let at = context["at"] as? Double else { return nil }
        let list = raw.compactMap { d -> Item? in
            guard let s = d["startedAt"], let l = d["length"] else { return nil }
            return Item(startedAt: Date(timeIntervalSince1970: s), length: l)
        }
        return (list, Date(timeIntervalSince1970: at))
    }

    func phoneSent(_ sent: (items: [Item], at: Date)?) {
        guard let sent else { return }
        phone = FromPhone(items: sent.items, at: sent.at)
        UserDefaults.standard.set(try? JSONEncoder().encode(phone), forKey: phoneKey)
        Recorder.shared.updateFace()
    }

    var today: [Item] {
        var all = items
        if let phone {
            // Ours that ended before the phone's list and aren't on it were deleted there.
            let known = phone.items.map(\.startedAt.timeIntervalSince1970)
            let ours = items.filter { item in
                !known.contains { abs($0 - item.startedAt.timeIntervalSince1970) < 2 }
                    && item.startedAt.addingTimeInterval(item.length) > phone.at.addingTimeInterval(-60)
            }
            all = phone.items + ours
        }
        return all.filter { Calendar.current.isDateInToday($0.startedAt) }
    }
}
