import AVFoundation
import Accelerate
import Foundation

/// A part's audio through Qwen3-ASR: cut into windows of at most 30
/// seconds at pauses, each heard on its own, the text spread over the
/// window's speech to give sentences their times.
enum QwenTranscriber {
    struct Result {
        let phrases: [Phrase]
        /// The language most of it was in, as a code ("zh").
        let language: String?
    }

    static func transcribe(_ url: URL, with model: QwenASR) throws -> Result {
        let samples = try load(url)
        let hop = QwenASR.sampleRate / 100
        let energy = QwenASR.frameEnergy(samples, hop: hop)
        var phrases: [Phrase] = []
        var languages: [String: Int] = [:]
        let windows = QwenASR.windows(samples)
        for (k, window) in windows.enumerated() {
            try Task.checkCancellation()
            let frames = (window.lowerBound / hop)..<min(energy.count, window.upperBound / hop)
            // Too quiet to hold speech: skip rather than have the model guess.
            guard let loudest = energy[frames].max(), loudest > 0.002 else { continue }
            let heard = try model.transcribe(Array(samples[window]))
            var text = heard.text
            guard !text.isEmpty else { continue }
            // Each window comes back as whole sentences, so the cut gets a
            // full stop even mid-sentence. Unless there was a real pause,
            // a comma reads better either way.
            if k < windows.count - 1, let last = text.last, "。.".contains(last),
               quiet(around: frames.upperBound, energy: energy, threshold: threshold(Array(energy[frames]))) < 1.0 {
                text.removeLast()
                text.append(last == "。" ? "，" : ",")
            }
            if let language = heard.language { languages[language, default: 0] += text.count }
            phrases += timed(text, energy: Array(energy[frames]), offset: Double(frames.lowerBound) / 100)
        }
        return Result(phrases: phrases, language: languages.max { $0.value < $1.value }?.key)
    }

    /// 16 kHz mono floats, whatever the file.
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(QwenASR.sampleRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw QwenError.badOutput("audio format") }
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * ratio) + 1024)
        let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384)!
        let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(16384) * ratio) + 1024)!
        var ended = false
        while true {
            var status: AVAudioConverterOutputStatus = .haveData
            var failure: NSError?
            outBuffer.frameLength = 0
            status = converter.convert(to: outBuffer, error: &failure) { _, inputStatus in
                if ended {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer)
                } catch {
                    ended = true
                }
                if inBuffer.frameLength == 0 {
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let failure { throw failure }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry, ended { break }
        }
        return out
    }

    /// Spreads a window's text over its speech: each character (or Latin
    /// word) gets a share of the voiced frames by how much there is to
    /// read, so a pause in the audio falls between the words around it.
    static func timed(_ text: String, energy: [Float], offset: Double) -> [Phrase] {
        let pieces = split(text)
        let total = pieces.reduce(0) { $0 + Sentences.units($1) }
        guard total > 0, !energy.isEmpty else { return [] }

        let threshold = Self.threshold(energy)
        let voiced = energy.indices.filter { energy[$0] >= threshold }
        guard !voiced.isEmpty else { return [] }
        func time(_ fraction: Double) -> Double {
            let i = min(voiced.count - 1, max(0, Int(fraction * Double(voiced.count))))
            return offset + Double(voiced[i]) / 100
        }

        var tokens: [Mixer.Token] = []
        var done = 0.0
        for piece in pieces {
            let units = Sentences.units(piece)
            let start = time(done / total)
            done += units
            let end = units > 0 ? time(done / total - 0.0001) + 0.01 : start
            tokens.append(Mixer.Token(text: piece, start: start, end: max(start, end), confidence: 1))
        }
        return Sentences.phrases(tokens)
    }

    /// Voiced: louder than a tenth of the window's speaking level.
    static func threshold(_ energy: [Float]) -> Float {
        guard !energy.isEmpty else { return 0.002 }
        let level = energy.sorted()[Int(Double(energy.count - 1) * 0.9)]
        return max(0.002, level * 0.1)
    }

    /// Seconds of quiet either side of a frame.
    static func quiet(around frame: Int, energy: [Float], threshold: Float) -> Double {
        var before = frame - 1, after = frame
        while before >= 0, energy[before] < threshold { before -= 1 }
        while after < energy.count, energy[after] < threshold { after += 1 }
        return Double(after - before - 1) / 100
    }

    /// Characters, with Latin words kept whole, spaces leading the word
    /// after them and punctuation trailing the one before.
    static func split(_ text: String) -> [String] {
        enum Kind { case none, cjk, word }
        var out: [String] = []
        var current = ""
        var kind = Kind.none
        var space = false
        func flush() {
            if !current.isEmpty { out.append(current) }
            current = ""
            kind = .none
        }
        for c in text {
            if c.isWhitespace {
                flush()
                space = !out.isEmpty
                continue
            }
            if Sentences.isCJK(c) {
                flush()
                current = (space ? " " : "") + String(c)
                kind = .cjk
            } else if c.isLetter || c.isNumber {
                if kind != .word {
                    flush()
                    current = space ? " " : ""
                    kind = .word
                }
                current.append(c)
            } else if kind == .word, "'’-".contains(c) {
                // Inside a word: don't, GPT-4.
                current.append(c)
            } else {
                // Punctuation goes with what came before.
                if current.isEmpty, let last = out.popLast() { current = last }
                current.append(c)
                kind = .none
            }
            space = false
        }
        flush()
        return out
    }
}
