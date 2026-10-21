import AVFoundation
import Observation
import WatchKit

/// Spike 0 recorder: background audio capture into rolling segments,
/// with logging for battery drain, interruptions and recovery.
@MainActor @Observable
final class Recorder {
    enum State: String {
        case idle, recording, interrupted
    }

    private(set) var state: State = .idle
    private(set) var startedAt: Date?
    private(set) var segmentsWritten = 0
    private(set) var lastEvent = "—"

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
        writer = SegmentWriter(
            directory: directory,
            maxDuration: segmentDuration,
            onSegmentClosed: { [weak self] url in
                Task { @MainActor in self?.segmentClosed(url) }
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
        startedAt = .now
        note("start")
        startBatteryLogging()
    }

    func stop() {
        guard state != .idle else { return }
        stopEngine()
        writer?.finish()
        writer = nil
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

    // MARK: - Engine

    @discardableResult
    private func startEngine() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let writer else {
            note("engine_error", "no input format")
            return false
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.append(buffer)
        }
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

    private func segmentClosed(_ url: URL) {
        segmentsWritten += 1
        WatchTransfer.shared.send(url, kind: "audio")
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
