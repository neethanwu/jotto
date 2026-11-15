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
///
/// A part ends at the first pause after `cutAfter` seconds, so a word
/// isn't cut in two, and at `cutBy` whatever is being said. Parts of
/// about a minute: each is transcribed on its own, in the short time iOS
/// gives jotto when the watch wakes it, and the last one is what's left
/// to do after a stop. Much shorter, and the cuts and lost context start
/// to cost more than they save.
final class SegmentWriter: @unchecked Sendable {
    static let cutAfter: TimeInterval = 45
    static let cutBy: TimeInterval = 75
    /// How long the level has to stay down to count as a pause.
    private static let pause: TimeInterval = 0.25

    private let lock = NSLock()
    private let directory: URL
    private let sessionID: UUID
    private let cutAfter: TimeInterval
    private let cutBy: TimeInterval
    private let onSegmentClosed: @Sendable (ClosedSegment) -> Void
    private let onError: @Sendable (String) -> Void

    /// Levels of the last minute or so of buffers, for the room's floor.
    private var levels: [Float] = []
    private var floor: Float = 0
    private var quietFor: TimeInterval = 0
    private var heard = 0
    /// Audio in the part being written, by its samples (not the clock,
    /// which also runs through a call that paused the recording).
    private var length: TimeInterval = 0

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
        cutAfter: TimeInterval = SegmentWriter.cutAfter,
        cutBy: TimeInterval = SegmentWriter.cutBy,
        onSegmentClosed: @escaping @Sendable (ClosedSegment) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.directory = directory
        self.sessionID = sessionID
        self.cutAfter = cutAfter
        self.cutBy = cutBy
        self.onSegmentClosed = onSegmentClosed
        self.onError = onError
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        let converted = convert(buffer)
        if let converted { listen(converted) }
        if file == nil || timeToCut {
            closeCurrent()
            openNew()
        }
        guard let file, let converted else { return }
        do {
            try file.write(from: converted)
            length += Double(converted.frameLength) / converted.format.sampleRate
        } catch {
            onError("write failed: \(error.localizedDescription)")
        }
    }

    private var timeToCut: Bool {
        length >= cutBy || (length >= cutAfter && quietFor >= Self.pause)
    }

    /// Keeps track of how long it has been quiet. Quiet is measured against
    /// the room: within 6 dB of its floor (the level 15% of the last
    /// minute's buffers were under), so a pause still counts in a noisy
    /// café, and talk over a hum doesn't.
    private func listen(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let level = sqrt(sum / Float(n))
        levels.append(level)
        if levels.count > 600 { levels.removeFirst(levels.count - 600) }
        heard += 1
        if heard < 10 || heard % 10 == 0 {
            let sorted = levels.sorted()
            floor = sorted[sorted.count * 15 / 100]
        }
        let duration = Double(n) / buffer.format.sampleRate
        quietFor = level <= max(floor * 2, 0.0005) ? quietFor + duration : 0
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
            length = 0
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

/// Peak level of the audio since it was last read, for the level bars on
/// the watch and the phone's Live screen. Written on the audio thread,
/// read on the main actor.
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
