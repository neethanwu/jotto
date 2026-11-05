import AVFoundation
import Observation
import WatchKit

/// Background audio capture into rolling segments, with logging for
/// battery drain, interruptions and recovery (the Spike 0 log).
@MainActor @Observable
final class Recorder {
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

    init() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        observeSession()
    }

    // MARK: - Control

    func toggle() {
        state == .idle ? start() : stop()
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
        justSaved = nil
        WatchTransfer.shared.sendStart(session: sessionID, startedAt: startedAt)
        WKInterfaceDevice.current().play(.start)
        note("start", sessionID.uuidString)
        startBatteryLogging()
        startMetering()
    }

    func stop() {
        guard state != .idle else { return }
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
        note("stop")

        if let snapshot = log.snapshot() {
            WatchTransfer.shared.send(snapshot, kind: "log")
        }
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
    private func recover(reason: String) {
        guard state != .idle else { return }
        stopEngine()
        writer?.finish()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            state = .interrupted
            note("recover_failed", "\(reason): \(error.localizedDescription)")
            return
        }
        if startEngine() {
            state = .recording
            note("recovered", reason)
        } else {
            state = .interrupted
        }
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
            MainActor.assumeIsolated { self?.handleInterruption(rawType: rawType, rawReason: rawReason) }
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

    private func handleInterruption(rawType: UInt?, rawReason: UInt?) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            guard state != .idle else { return }
            state = .interrupted
            writer?.finish()
            note("interrupt_began", "reason=\(rawReason ?? 0)")
        case .ended:
            note("interrupt_ended")
            // Always try to resume: an always-on recorder should not wait for permission.
            recover(reason: "interruption_ended")
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

/// Recordings made on this watch, for the "4 today · 3 h 18" line.
@MainActor
final class History {
    static let shared = History()
    private let key = "history"

    struct Item: Codable {
        let startedAt: Date
        let length: TimeInterval
    }

    private(set) var items: [Item]

    private init() {
        items = (UserDefaults.standard.data(forKey: key))
            .flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    func add(startedAt: Date, length: TimeInterval) {
        let weekAgo = Date.now.addingTimeInterval(-7 * 86400)
        items = items.filter { $0.startedAt > weekAgo } + [Item(startedAt: startedAt, length: length)]
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }

    var today: [Item] { items.filter { Calendar.current.isDateInToday($0.startedAt) } }
}
