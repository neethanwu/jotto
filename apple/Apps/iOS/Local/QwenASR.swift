import Accelerate
import CoreML
import Foundation

// Qwen3-ASR 0.6B, run on the Neural Engine with Core ML: no GPU, so it
// keeps working with the screen locked. The models are the Core ML export
// at huggingface.co/aufklarer/Qwen3-ASR-CoreML (Apache 2.0, from
// Qwen/Qwen3-ASR-0.6B, Apache 2.0); this file is adapted from the MLX-free
// path of soniqo/speech-swift (Apache 2.0): the mel features, the
// fixed-size decoder calls and the token ids are theirs.
//
// The encoder takes at most 30 seconds, so a part is cut into windows at
// quiet moments first (`windows`). The model gives text only, no times;
// `QwenTranscriber` spreads each window's text over its speech.

/// One loaded model. Not thread-safe: one transcription at a time.
final class QwenASR {
    struct Heard {
        let text: String
        /// The language the model heard, as a code ("zh", "en"), if it said.
        let language: String?
    }

    static let sampleRate = 16_000
    /// The encoder's fixed input: 3000 mel frames, 30 seconds.
    static let maxSamples = 30 * sampleRate

    private let encoder: MLModel
    private let embedding: MLModel
    private let part1: MLModel
    private let part2: MLModel
    private let vocab: QwenVocab
    private let features = QwenFeatures()

    private let maxSeq: Int
    private let hidden: Int
    /// Both decoder parts take exactly this many tokens a call.
    private let batch: Int

    /// How long each model took to load, for the test log ("encoder 2.1s, …").
    let loadTimes: String

    init(directory: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        var times: [String] = []
        func load(_ name: String) throws -> MLModel {
            let began = Date.now
            defer { times.append("\(name) \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s") }
            return try MLModel(contentsOf: directory.appending(path: "\(name).mlmodelc", directoryHint: .isDirectory), configuration: config)
        }
        encoder = try load("encoder")
        embedding = try load("embedding")
        part1 = try load("decoder_part1")
        part2 = try load("decoder_part2")
        vocab = try QwenVocab(directory: directory)
        loadTimes = times.joined(separator: ", ")

        let json = (try? Data(contentsOf: directory.appending(path: "config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        maxSeq = json["max_seq_length"] as? Int ?? 1024
        hidden = json["hidden_size"] as? Int ?? 1024
        batch = (json["enumerated_t"] as? [Int])?.first ?? 128
    }

    // MARK: Transcribe

    private enum Token {
        static let imStart: Int32 = 151_644
        static let imEnd: Int32 = 151_645
        static let audioStart: Int32 = 151_669
        static let audioEnd: Int32 = 151_670
        static let asrText: Int32 = 151_704
        static let newline: Int32 = 198
        static let system: Int32 = 8948
        static let user: Int32 = 872
        static let assistant: Int32 = 77091
    }

    /// Up to 30 seconds of 16 kHz mono audio, as text.
    func transcribe(_ samples: [Float]) throws -> Heard {
        precondition(samples.count <= Self.maxSamples)
        let mel = features.mel(samples)
        let (audio, audioTokens) = try encode(mel)

        var decoder = try Decoder(self)
        // <|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>
        try decoder.prefill(tokens: [Token.imStart, Token.system, Token.newline, Token.imEnd, Token.newline,
                                     Token.imStart, Token.user, Token.newline, Token.audioStart])
        var consumed = 0
        while consumed < audioTokens {
            let n = min(batch, audioTokens - consumed)
            try decoder.prefill(rows: n) { slot, dst in
                Self.copyRows(from: audio, first: consumed, count: n, hidden: self.hidden, to: dst + slot * self.hidden)
            }
            consumed += n
        }
        // <|audio_end|><|im_end|>\n<|im_start|>assistant\n — the model then
        // says "language X<asr_text>" and the text.
        var logits = try decoder.prefill(tokens: [Token.audioEnd, Token.imEnd, Token.newline,
                                                  Token.imStart, Token.assistant, Token.newline])

        var out: [Int32] = []
        let room = decoder.room
        while out.count < min(448, room) {
            try Task.checkCancellation()
            let next = Self.argmax(logits)
            if next == Token.imEnd { break }
            out.append(next)
            if Self.isLooping(out) { break }
            logits = try decoder.step(try embed(next))
        }
        return Self.parse(vocab.decode(out))
    }

    /// "language Chinese<asr_text>你好" → ("你好", "zh").
    static func parse(_ raw: String) -> Heard {
        guard let mark = raw.range(of: "<asr_text>") else {
            return Heard(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), language: nil)
        }
        let said = raw[..<mark.lowerBound].replacingOccurrences(of: "language", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = String(raw[mark.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Heard(text: text, language: languageCodes[said])
    }

    private static let languageCodes: [String: String] = [
        "chinese": "zh", "english": "en", "cantonese": "yue", "japanese": "ja", "korean": "ko",
        "french": "fr", "german": "de", "spanish": "es", "italian": "it", "portuguese": "pt",
        "russian": "ru", "arabic": "ar", "dutch": "nl", "thai": "th", "vietnamese": "vi",
        "indonesian": "id", "malay": "ms", "turkish": "tr", "hindi": "hi", "polish": "pl",
        "swedish": "sv", "danish": "da", "finnish": "fi", "czech": "cs", "greek": "el",
        "hungarian": "hu", "romanian": "ro", "filipino": "fil", "persian": "fa", "macedonian": "mk",
    ]

    /// The same few tokens over and over (noise can set it off): stop.
    static func isLooping(_ tokens: [Int32]) -> Bool {
        for period in 1...8 {
            let span = max(24, period * 4)
            guard tokens.count >= span else { return false }
            let tail = tokens.suffix(span)
            let pattern = Array(tail.prefix(period))
            if tail.enumerated().allSatisfy({ $0.element == pattern[$0.offset % period] }) { return true }
        }
        return false
    }

    // MARK: Models

    private func encode(_ mel: QwenFeatures.Mel) throws -> (MLMultiArray, Int) {
        let padded = 3000
        let input = try MLMultiArray(shape: [1, mel.bins as NSNumber, padded as NSNumber], dataType: .float32)
        let p = input.dataPointer.assumingMemoryBound(to: Float.self)
        p.initialize(repeating: 0, count: mel.bins * padded)
        mel.data.withUnsafeBufferPointer { src in
            for bin in 0..<mel.bins {
                (p + bin * padded).update(from: src.baseAddress! + bin * mel.frames, count: mel.frames)
            }
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: Int32(mel.frames))
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: input),
            "mel_length": MLFeatureValue(multiArray: length),
        ]))
        guard let embeddings = output.featureValue(for: "audio_embeddings")?.multiArrayValue,
              let count = output.featureValue(for: "output_length")?.multiArrayValue else { throw QwenError.badOutput("encoder") }
        let rows = embeddings.shape.count >= 2 ? embeddings.shape[embeddings.shape.count - 2].intValue : 0
        guard embeddings.shape.last?.intValue == hidden else { throw QwenError.badOutput("encoder width") }
        return (embeddings, min(max(0, count[0].intValue), rows))
    }

    private func embed(_ token: Int32) throws -> MLMultiArray {
        let id = try MLMultiArray(shape: [1, 1], dataType: .int32)
        id[0] = NSNumber(value: token)
        let output = try embedding.prediction(from: MLDictionaryFeatureProvider(dictionary: ["token_id": MLFeatureValue(multiArray: id)]))
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue else { throw QwenError.badOutput("embedding") }
        return vector
    }

    /// The KV caches of one transcription, and where the next token goes.
    private struct Decoder {
        let model: QwenASR
        var state1: MLState
        var state2: MLState
        var position = 0
        /// Cache slots past this take the padding of short calls.
        var scratch: Int { model.maxSeq - (model.batch - 1) }
        var room: Int { scratch - position }

        init(_ model: QwenASR) throws {
            self.model = model
            state1 = model.part1.makeState()
            state2 = model.part2.makeState()
        }

        @discardableResult
        mutating func prefill(tokens: [Int32]) throws -> MLMultiArray {
            var logits: MLMultiArray?
            var done = 0
            let hidden = model.hidden
            while done < tokens.count {
                let n = min(model.batch, tokens.count - done)
                let vectors = try tokens[done..<done + n].map(model.embed)
                logits = try prefill(rows: n) { slot, dst in
                    for (k, v) in vectors.enumerated() {
                        QwenASR.copyRows(from: v, first: 0, count: 1, hidden: hidden, to: dst + (slot + k) * hidden)
                    }
                }
                done += n
            }
            return logits!
        }

        mutating func step(_ vector: MLMultiArray) throws -> MLMultiArray {
            let hidden = model.hidden
            return try prefill(rows: 1) { slot, dst in
                QwenASR.copyRows(from: vector, first: 0, count: 1, hidden: hidden, to: dst + slot * hidden)
            }
        }

        /// `n` real tokens in the last `n` of the call's slots; the rest
        /// write to scratch slots that every real token's mask hides.
        /// Fresh buffers each call: Core ML can hold on to inputs.
        @discardableResult
        mutating func prefill(rows n: Int, fill: (Int, UnsafeMutablePointer<Float>) -> Void) throws -> MLMultiArray {
            let t = model.batch, seq = model.maxSeq, hidden = model.hidden
            guard position + n <= scratch else { throw QwenError.tooLong }
            let first = t - n
            let embeds = try MLMultiArray(shape: [1, t as NSNumber, hidden as NSNumber], dataType: .float32)
            let positions = try MLMultiArray(shape: [t as NSNumber], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, 1, t as NSNumber, seq as NSNumber], dataType: .float32)

            let pos = positions.dataPointer.assumingMemoryBound(to: Int32.self)
            for i in 0..<first { pos[i] = Int32(scratch + i) }
            for i in 0..<n { pos[first + i] = Int32(position + i) }

            let m = mask.dataPointer.assumingMemoryBound(to: Float.self)
            var blocked: Float = -1e4
            vDSP_vfill(&blocked, m, 1, vDSP_Length(t * seq))
            for i in 0..<n {
                // Sees every real position up to its own.
                var open: Float = 0
                vDSP_vfill(&open, m + (first + i) * seq, 1, vDSP_Length(position + i + 1))
            }

            let e = embeds.dataPointer.assumingMemoryBound(to: Float.self)
            e.initialize(repeating: 0, count: t * hidden)
            fill(first, e)
            position += n

            let out1 = try model.part1.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "input_embeds": MLFeatureValue(multiArray: embeds),
                "positions": MLFeatureValue(multiArray: positions),
                "attention_mask": MLFeatureValue(multiArray: mask),
            ]), using: state1)
            guard let middle = out1.featureValue(for: "hidden_state")?.multiArrayValue else { throw QwenError.badOutput("decoder part 1") }
            let out2 = try model.part2.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "input_embeds": MLFeatureValue(multiArray: middle),
                "positions": MLFeatureValue(multiArray: positions),
                "attention_mask": MLFeatureValue(multiArray: mask),
            ]), using: state2)
            guard let logits = out2.featureValue(for: "logits")?.multiArrayValue else { throw QwenError.badOutput("decoder part 2") }
            return logits
        }
    }

    // MARK: Arrays

    /// Rows of a `[…, rows, hidden]` array (Float16 or Float32, any
    /// strides) into contiguous Float32.
    static func copyRows(from src: MLMultiArray, first: Int, count: Int, hidden: Int, to dst: UnsafeMutablePointer<Float>) {
        let strides = src.strides.map(\.intValue)
        let rowStride = strides.count >= 2 ? strides[strides.count - 2] : hidden
        let step = strides.last ?? 1
        for r in 0..<count {
            let base = (first + r) * rowStride
            let out = dst + r * hidden
            switch src.dataType {
            case .float16:
                let p = src.dataPointer.assumingMemoryBound(to: Float16.self)
                for j in 0..<hidden { out[j] = Float(p[base + j * step]) }
            case .float32:
                let p = src.dataPointer.assumingMemoryBound(to: Float.self)
                for j in 0..<hidden { out[j] = p[base + j * step] }
            default:
                out.initialize(repeating: 0, count: hidden)
            }
        }
    }

    /// The likeliest next token. NaNs are skipped.
    static func argmax(_ logits: MLMultiArray) -> Int32 {
        let count = logits.shape.last?.intValue ?? logits.count
        let step = logits.strides.last?.intValue ?? 1
        var best = -Float.infinity, index = 0
        switch logits.dataType {
        case .float16:
            let p = logits.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<count {
                let v = Float(p[i * step])
                if v > best { best = v; index = i }
            }
        case .float32:
            let p = logits.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                let v = p[i * step]
                if v > best { best = v; index = i }
            }
        default:
            break
        }
        return Int32(index)
    }

    // MARK: Windows

    /// Cuts audio into pieces of at most 30 seconds, each at the longest
    /// pause between 15 and 29 seconds in: the model ends every piece as a
    /// finished sentence, so the cut should fall where one likely ended.
    static func windows(_ samples: [Float]) -> [Range<Int>] {
        let hop = sampleRate / 100
        let energy = frameEnergy(samples, hop: hop)
        let smooth = movingAverage(energy, width: 30)
        var out: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            if samples.count - start <= maxSamples {
                out.append(start..<samples.count)
                break
            }
            let lo = (start + 15 * sampleRate) / hop, hi = min((start + 29 * sampleRate) / hop, energy.count)
            let region = Array(energy[lo..<hi])
            let level = region.sorted()[Int(Double(region.count - 1) * 0.9)]
            let quiet = max(0.002, level * 0.1)
            // The longest run of quiet frames; the later one on a tie.
            var best: (start: Int, length: Int)?
            var run = 0
            for f in lo..<hi {
                run = energy[f] < quiet ? run + 1 : 0
                if run > 0, run >= (best?.length ?? 1) { best = (f - run + 1, run) }
            }
            let cut = best.map { $0.start + $0.length / 2 }
                ?? (lo..<hi).min { smooth[$0] < smooth[$1] } ?? hi
            let end = cut * hop
            out.append(start..<end)
            start = end
        }
        return out
    }

    /// Root-mean-square level of each 10 ms frame.
    static func frameEnergy(_ samples: [Float], hop: Int) -> [Float] {
        let frames = samples.count / hop
        var out = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { s in
            for f in 0..<frames {
                var rms: Float = 0
                vDSP_rmsqv(s.baseAddress! + f * hop, 1, &rms, vDSP_Length(hop))
                out[f] = rms
            }
        }
        return out
    }

    static func movingAverage(_ x: [Float], width: Int) -> [Float] {
        guard !x.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: x.count)
        var sum: Float = 0
        for i in 0..<x.count {
            sum += x[i]
            if i >= width { sum -= x[i - width] }
            out[i] = sum / Float(min(i + 1, width))
        }
        // Centre it.
        let shift = width / 2
        return Array(out.dropFirst(shift)) + Array(repeating: out.last!, count: min(shift, out.count))
    }
}

enum QwenError: LocalizedError {
    case badOutput(String), tooLong, badVocab
    var errorDescription: String? {
        switch self {
        case let .badOutput(what): "The speech model gave something unexpected (\(what))."
        case .tooLong: "Too much speech for the model in one go."
        case .badVocab: "The speech model's word list is damaged."
        }
    }
}

// MARK: - Mel features

/// Whisper's log-mel features (128 bins, 25 ms windows every 10 ms), as
/// Hugging Face's WhisperFeatureExtractor computes them.
final class QwenFeatures {
    struct Mel {
        /// `[bins, frames]`, row-major.
        let data: [Float]
        let bins: Int
        let frames: Int
    }

    private let nFFT = 400
    private let hop = 160
    private let bins = 128
    /// `[nFFT, nFFT/2+1]`: a 400-point DFT with the Hann window folded in.
    private let dftCos: [Float]
    private let dftSin: [Float]
    /// `[nFFT/2+1, bins]`, Slaney-normalised.
    private let filters: [Float]

    init() {
        let nBins = nFFT / 2 + 1
        var cosTable = [Float](repeating: 0, count: nFFT * nBins)
        var sinTable = [Float](repeating: 0, count: nFFT * nBins)
        for n in 0..<nFFT {
            let window = 0.5 * (1 - cos(2 * Double.pi * Double(n) / Double(nFFT)))
            for k in 0..<nBins {
                let angle = 2 * Double.pi * Double(k * n % nFFT) / Double(nFFT)
                cosTable[n * nBins + k] = Float(window * cos(angle))
                sinTable[n * nBins + k] = Float(window * sin(angle))
            }
        }
        dftCos = cosTable
        dftSin = sinTable

        // Slaney mel scale: linear below 1 kHz, logarithmic above.
        func hzToMel(_ hz: Double) -> Double { hz < 1000 ? 3 * hz / 200 : 15 + log(hz / 1000) * 27 / log(6.4) }
        func melToHz(_ mel: Double) -> Double { mel < 15 ? 200 * mel / 3 : 1000 * exp((mel - 15) * log(6.4) / 27) }
        let points = bins + 2
        let lo = hzToMel(0), hi = hzToMel(8000)
        let edges = (0..<points).map { melToHz(lo + Double($0) * (hi - lo) / Double(points - 1)) }
        var bank = [Float](repeating: 0, count: nBins * bins)
        for b in 0..<nBins {
            let f = Double(b) * 16000 / Double(nFFT)
            for m in 0..<bins {
                let down = (f - edges[m]) / (edges[m + 1] - edges[m])
                let up = (edges[m + 2] - f) / (edges[m + 2] - edges[m + 1])
                bank[b * bins + m] = Float(max(0, min(down, up)) * 2 / (edges[m + 2] - edges[m]))
            }
        }
        filters = bank
    }

    func mel(_ audio: [Float]) -> Mel {
        let nBins = nFFT / 2 + 1
        let pad = nFFT / 2
        // Reflect-padded on both ends.
        var padded = [Float](repeating: 0, count: audio.count + 2 * pad)
        for i in 0..<pad { padded[i] = audio[max(0, min(pad - i, audio.count - 1))] }
        padded.replaceSubrange(pad..<pad + audio.count, with: audio)
        for i in 0..<pad { padded[pad + audio.count + i] = audio[max(0, audio.count - 2 - i)] }

        let frames = (padded.count - nFFT) / hop + 1
        var power = [Float](repeating: 0, count: frames * nBins)
        let chunk = min(frames, 256)
        var rows = [Float](repeating: 0, count: chunk * nFFT)
        var re = [Float](repeating: 0, count: chunk * nBins)
        var im = [Float](repeating: 0, count: chunk * nBins)
        for first in stride(from: 0, to: frames, by: chunk) {
            let n = min(chunk, frames - first)
            padded.withUnsafeBufferPointer { src in
                rows.withUnsafeMutableBufferPointer { dst in
                    for f in 0..<n {
                        (dst.baseAddress! + f * nFFT).update(from: src.baseAddress! + (first + f) * hop, count: nFFT)
                    }
                }
            }
            vDSP_mmul(rows, 1, dftCos, 1, &re, 1, vDSP_Length(n), vDSP_Length(nBins), vDSP_Length(nFFT))
            vDSP_mmul(rows, 1, dftSin, 1, &im, 1, vDSP_Length(n), vDSP_Length(nBins), vDSP_Length(nFFT))
            power.withUnsafeMutableBufferPointer { out in
                vDSP_vmma(re, 1, re, 1, im, 1, im, 1, out.baseAddress! + first * nBins, 1, vDSP_Length(n * nBins))
            }
        }

        var mel = [Float](repeating: 0, count: frames * bins)
        vDSP_mmul(power, 1, filters, 1, &mel, 1, vDSP_Length(frames), vDSP_Length(bins), vDSP_Length(nBins))
        let count = mel.count
        var floor: Float = 1e-10, ceiling = Float.greatestFiniteMagnitude
        vDSP_vclip(mel, 1, &floor, &ceiling, &mel, 1, vDSP_Length(count))
        var n32 = Int32(count)
        vvlog10f(&mel, mel, &n32)
        var top: Float = 0
        vDSP_maxv(mel, 1, &top, vDSP_Length(count))
        var bottom = top - 8
        vDSP_vclip(mel, 1, &bottom, &ceiling, &mel, 1, vDSP_Length(count))
        var scale: Float = 0.25, offset: Float = 1
        vDSP_vsmsa(mel, 1, &scale, &offset, &mel, 1, vDSP_Length(count))

        // Hugging Face drops the last frame.
        let kept = frames - 1
        var out = [Float](repeating: 0, count: kept * bins)
        mel.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                vDSP_mtrans(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(bins), vDSP_Length(kept))
            }
        }
        return Mel(data: out, bins: bins, frames: kept)
    }
}

// MARK: - Tokens to text

/// Qwen's byte-level BPE vocabulary, for turning token ids back into text.
struct QwenVocab {
    private var tokens: [Int: String] = [:]

    init(directory: URL) throws {
        guard let vocab = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "vocab.json"))) as? [String: Int]
        else { throw QwenError.badVocab }
        for (token, id) in vocab { tokens[id] = token }
        if let config = try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "tokenizer_config.json"))) as? [String: Any],
           let added = config["added_tokens_decoder"] as? [String: [String: Any]] {
            for (id, info) in added {
                if let id = Int(id), let content = info["content"] as? String { tokens[id] = content }
            }
        }
    }

    /// GPT-2's map from the printable stand-ins back to bytes.
    private static let bytes: [Character: UInt8] = {
        var map: [UInt8: Character] = [:]
        for b in UInt8(ascii: "!")...UInt8(ascii: "~") { map[b] = Character(UnicodeScalar(b)) }
        for b in UInt8(0xA1)...0xAC { map[b] = Character(UnicodeScalar(b)) }
        for b in UInt8(0xAE)...0xFF { map[b] = Character(UnicodeScalar(b)) }
        var n = 0
        for b in UInt8(0)...255 where map[b] == nil {
            map[b] = Character(UnicodeScalar(0x100 + n)!)
            n += 1
        }
        return Dictionary(uniqueKeysWithValues: map.map { ($1, $0) })
    }()

    /// Bytes are gathered first, so a character split across tokens
    /// (most Chinese ones) comes out whole. `<|…|>` tokens are dropped;
    /// `<asr_text>` is kept, to find where the text starts.
    func decode(_ ids: [Int32]) -> String {
        var buffer: [UInt8] = []
        for id in ids {
            guard let token = tokens[Int(id)] else { continue }
            if token.hasPrefix("<|"), token.hasSuffix("|>") { continue }
            if token.hasPrefix("<"), token.hasSuffix(">") {
                buffer += Array(token.utf8)
                continue
            }
            for ch in token {
                if let b = Self.bytes[ch] { buffer.append(b) } else { buffer += Array(String(ch).utf8) }
            }
        }
        return String(decoding: buffer, as: UTF8.self)
    }
}
