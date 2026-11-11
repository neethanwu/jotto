import AVFoundation

/// A finished segment file, numbered within its recording session.
struct ClosedSegment: Sendable {
    let url: URL
    let index: Int
    let startedAt: Date
    let endedAt: Date
}

/// Writes incoming PCM buffers to rolling AAC segments on disk.
/// Called from the audio render thread, so state is guarded by a lock.
final class SegmentWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let sessionID: UUID
    private let maxDuration: TimeInterval
    private let onSegmentClosed: @Sendable (ClosedSegment) -> Void
    private let onError: @Sendable (String) -> Void

    private var file: AVAudioFile?
    private var fileStartedAt = Date.distantPast
    private var nextIndex = 0
    /// Turns whatever the mic gives (often 48 kHz) into the file's 16 kHz
    /// mono. AVAudioFile doesn't resample: a 48 kHz buffer written to a
    /// 16 kHz file plays three times too slow.
    private var converter: AVAudioConverter?

    /// What the file takes in memory: 16 kHz mono float.
    nonisolated(unsafe) private static let fileFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    /// 16 kHz mono AAC, ~32 kbps ≈ 14 MB / hour. Plenty for speech.
    nonisolated(unsafe) private static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    init(
        directory: URL,
        sessionID: UUID,
        maxDuration: TimeInterval,
        onSegmentClosed: @escaping @Sendable (ClosedSegment) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.directory = directory
        self.sessionID = sessionID
        self.maxDuration = maxDuration
        self.onSegmentClosed = onSegmentClosed
        self.onError = onError
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        if file == nil || Date.now.timeIntervalSince(fileStartedAt) >= maxDuration {
            closeCurrent()
            openNew()
        }
        guard let file, let converted = convert(buffer) else { return }
        do {
            try file.write(from: converted)
        } catch {
            onError("write failed: \(error.localizedDescription)")
        }
    }

    /// The buffer as 16 kHz mono. The converter keeps its state between
    /// buffers, so the resampling is seamless across them.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Self.fileFormat
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            if converter == nil { onError("no converter from \(buffer.format)") }
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            onError("convert failed: \(error?.localizedDescription ?? "?")")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    /// Closes the current segment (if any). Safe to call from any thread.
    /// Returns how many segments this session has produced so far.
    @discardableResult
    func finish() -> Int {
        lock.lock()
        defer { lock.unlock() }
        closeCurrent()
        return nextIndex
    }

    private func openNew() {
        let start = Date.now
        let name = "\(sessionID.uuidString.lowercased())-\(String(format: "%03d", nextIndex)).m4a"
        let url = directory.appending(path: name)
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: Self.fileSettings,
                commonFormat: Self.fileFormat.commonFormat,
                interleaved: Self.fileFormat.isInterleaved
            )
            fileStartedAt = start
        } catch {
            file = nil
            onError("open failed: \(error.localizedDescription)")
        }
    }

    private func closeCurrent() {
        guard let file else { return }
        let segment = ClosedSegment(url: file.url, index: nextIndex, startedAt: fileStartedAt, endedAt: .now)
        file.close()
        self.file = nil
        nextIndex += 1
        onSegmentClosed(segment)
    }
}
