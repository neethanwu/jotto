import AVFoundation

/// Writes incoming PCM buffers to rolling AAC segments on disk.
/// Called from the audio render thread, so state is guarded by a lock.
final class SegmentWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let maxDuration: TimeInterval
    private let onSegmentClosed: @Sendable (URL) -> Void
    private let onError: @Sendable (String) -> Void

    private var file: AVAudioFile?
    private var fileStartedAt = Date.distantPast

    /// 16 kHz mono AAC, ~32 kbps ≈ 14 MB / hour. Plenty for speech.
    nonisolated(unsafe) private static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    init(
        directory: URL,
        maxDuration: TimeInterval,
        onSegmentClosed: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.directory = directory
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
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        closeCurrent()
    }

    private func openNew(format: AVAudioFormat) {
        let start = Date.now
        let url = directory.appending(path: "seg-\(Self.fileStamp(start)).m4a")
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
        let url = file.url
        file.close()
        self.file = nil
        onSegmentClosed(url)
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
