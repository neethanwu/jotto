import AVFoundation
import Foundation

/// Watch builds before 2026-11-11 wrote the mic's 48 kHz samples into a
/// 16 kHz file without resampling, so the audio plays three times too
/// slow and the speech model hears nothing it knows. The watch now
/// resamples; this mends files it sent before, in place.
enum AudioRepair {
    /// Mic rates a file may have been mislabeled from.
    private static let micRates: [Double] = [48_000, 44_100, 32_000, 24_000]

    /// The rate the samples were really taken at, if the file runs too long
    /// for the time the watch says the segment took.
    static func stretchedRate(_ url: URL, expected: Double) -> Double? {
        guard expected > 5, let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let ratio = Double(file.length) / rate / expected
        return micRates.first { abs(ratio - $0 / rate) < 0.1 * ($0 / rate) }
    }

    /// Rewrites the file at its real speed. True if it did.
    @discardableResult
    static func fix(_ url: URL, expected: Double) -> Bool {
        guard let trueRate = stretchedRate(url, expected: expected),
              let file = try? AVAudioFile(forReading: url),
              let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: read)) != nil,
              let truth = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: trueRate,
                                        channels: file.processingFormat.channelCount, interleaved: false),
              let relabeled = AVAudioPCMBuffer(pcmFormat: truth, frameCapacity: read.frameLength),
              let source = read.floatChannelData, let target = relabeled.floatChannelData
        else { return false }
        // Same samples, honest rate.
        relabeled.frameLength = read.frameLength
        for channel in 0..<Int(truth.channelCount) {
            target[channel].update(from: source[channel], count: Int(read.frameLength))
        }

        let out = file.fileFormat
        guard let mono16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: out.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: truth, to: mono16k),
              let converted = AVAudioPCMBuffer(
                pcmFormat: mono16k,
                frameCapacity: AVAudioFrameCount(Double(read.frameLength) * out.sampleRate / trueRate) + 1024)
        else { return false }
        var given = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .endOfStream
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return relabeled
        }
        guard status != .error else { return false }

        let temp = url.deletingLastPathComponent().appending(path: "repair-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: temp)
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: out.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            // Scoped so the file is closed before it replaces the original.
            do {
                let writer = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try writer.write(from: converted)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }
}
