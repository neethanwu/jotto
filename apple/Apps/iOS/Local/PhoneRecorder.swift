import AVFoundation
import Observation
import UIKit
import WatchConnectivity

/// Recording on the iPhone itself, for when the watch isn't on the wrist
/// or its app isn't running. The same two-minute parts as the watch, fed
/// into the same pipeline, so the timeline, Live, the lock screen and the
/// transcript don't know the difference.
///
/// A call takes the microphone: the recording pauses (the part so far is
/// closed) and picks up again when the call ends, as one recording with a
/// gap where the call was.
@MainActor @Observable
final class PhoneRecorder {
    static let shared = PhoneRecorder()

    private(set) var sessionID: String?
    private(set) var startedAt: Date?
    /// A call or another app has the microphone.
    private(set) var interrupted = false
    var isRecording: Bool { sessionID != nil }

    static let segmentDuration: TimeInterval = 120

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var writer: SegmentWriter?
    @ObservationIgnored private let meter = LevelMeter()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated { PhoneRecorder.shared.interruption(type) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneRecorder.shared.restart(reason: "config_change") }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneRecorder.shared.restartIfInterrupted() }
        })
    }

    enum StartError: LocalizedError {
        case noMicrophone, couldNotStart(String)
        var errorDescription: String? {
            switch self {
            case .noMicrophone: "Jotto needs the microphone to record. Turn it on in Settings → Jotto."
            case let .couldNotStart(reason): "Couldn't start recording. \(reason)"
            }
        }
    }

    /// Starts a recording on this iPhone and returns its id.
    func start() async throws -> String {
        if let sessionID { return sessionID }
        guard await AVAudioApplication.requestRecordPermission() else { throw StartError.noMicrophone }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            throw StartError.couldNotStart(error.localizedDescription)
        }

        let uuid = UUID()
        let id = uuid.uuidString.lowercased()
        let startedAt = Date.now
        writer = SegmentWriter(
            directory: URL.temporaryDirectory.appending(path: "PhoneSegments"),
            sessionID: uuid,
            maxDuration: Self.segmentDuration,
            onSegmentClosed: Self.closed(id: id, startedAt: startedAt),
            onError: { PhoneLog.shared.later("phone_writer_error", $0) }
        )
        guard startEngine() else {
            writer = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            throw StartError.couldNotStart("The microphone didn't start.")
        }
        self.sessionID = id
        self.startedAt = startedAt
        interrupted = false
        Library.shared.watchStarted(id, at: startedAt)
        Pipeline.shared.started(id, at: startedAt)
        PhoneLog.shared.note("phone_start", id)
        return id
    }

    func stop() {
        guard let id = sessionID, let startedAt else { return }
        stopEngine()
        let count = writer?.finish() ?? 0
        writer = nil
        sessionID = nil
        self.startedAt = nil
        interrupted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let endedAt = Date.now
        // The last part is moved in on the main actor just after this; the
        // pipeline waits for every part the count says there is.
        Task { @MainActor in
            Library.shared.watchFinished(id, startedAt: startedAt, endedAt: endedAt, segmentCount: count)
            Pipeline.shared.finished(id, startedAt: startedAt, endedAt: endedAt, segmentCount: count)
        }
        PhoneLog.shared.note("phone_stop", "\(id) parts=\(count)")
    }

    /// A part is done: into the recording's folder, as if the watch sent it.
    /// Built outside the main actor: the writer calls it on the audio thread.
    nonisolated private static func closed(id: String, startedAt: Date) -> @Sendable (ClosedSegment) -> Void {
        { segment in
            let destination = AudioFiles.url(session: id, index: segment.index)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: segment.url, to: destination)
            } catch {
                PhoneLog.shared.later("phone_segment_move_failed", error.localizedDescription)
                return
            }
            let offset = segment.startedAt.timeIntervalSince(startedAt)
            let duration = segment.endedAt.timeIntervalSince(segment.startedAt)
            Task { @MainActor in
                Library.shared.watchSent(id, startedAt: startedAt, index: segment.index)
                Pipeline.shared.segmentArrived(id, startedAt: startedAt, index: segment.index, offset: offset, duration: duration)
            }
        }
    }

    // MARK: - Engine

    private func startEngine() -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let writer else { return false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(writer, meter: meter))
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            input.removeTap(onBus: 0)
            PhoneLog.shared.note("phone_engine_error", error.localizedDescription)
            return false
        }
    }

    nonisolated private static func tap(_ writer: SegmentWriter, meter: LevelMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            writer.append(buffer)
            meter.add(buffer)
        }
    }

    /// The loudest the microphone has been since the last call, 0…1, for
    /// the Live screen's level strip.
    func takeLevel() -> Float { meter.take() }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Calls and other interruptions

    private func interruption(_ type: AVAudioSession.InterruptionType?) {
        guard isRecording, let type else { return }
        switch type {
        case .began:
            interrupted = true
            stopEngine()
            // Close the part, so the gap never hides inside one file.
            writer?.finish()
            PhoneLog.shared.note("phone_interrupted")
        case .ended:
            restart(reason: "interruption_ended")
        @unknown default:
            break
        }
    }

    private func restart(reason: String) {
        guard isRecording else { return }
        stopEngine()
        writer?.finish()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            interrupted = true
            PhoneLog.shared.note("phone_resume_failed", "\(reason) \(error.localizedDescription)")
            return
        }
        interrupted = !startEngine()
        PhoneLog.shared.note(interrupted ? "phone_resume_failed" : "phone_resumed", reason)
    }

    private func restartIfInterrupted() {
        if interrupted { restart(reason: "foreground") }
    }
}

/// The record button: the watch records if its app is open and in reach
/// (it has the better microphone, on the wrist); otherwise this iPhone does.
enum RecordStarter {
    enum Where { case watch, phone }

    static func start() async throws -> (id: String, on: Where) {
        if let id = await Inbox.shared.askWatchToStart() {
            return (id, .watch)
        }
        return (try await PhoneRecorder.shared.start(), .phone)
    }
}
