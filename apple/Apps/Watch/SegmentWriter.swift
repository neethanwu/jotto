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
            openNew(format: buffer.format)
        }
        do {
            try file?.write(from: buffer)
        } catch {
            onError("write failed: \(error.localizedDescription)")
        }
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

    private func openNew(format: AVAudioFormat) {
        let start = Date.now
        let name = "\(sessionID.uuidString.lowercased())-\(String(format: "%03d", nextIndex)).m4a"
        let url = directory.appending(path: name)
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: Self.fileSettings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
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
