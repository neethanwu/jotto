import AVFoundation
import Foundation
import Speech
import UIKit

/// Apple's on-device speech-to-text (SpeechAnalyzer). Free, private, and
/// fast: about 2.6 s for a 2-minute segment on an M-series Mac. One
/// language per recording; no speaker labels.
///
/// The languages are the ones picked in Settings → Languages; with more
/// than one, each recording gets whichever the start of it sounds most
/// like (`detect`).
actor OnDeviceTranscriber {
    static let shared = OnDeviceTranscriber()

    enum Failure: LocalizedError {
        /// Not a problem with the audio: the language or its model isn't
        /// available yet. Leave the segment for later.
        case notReady(String)
        var errorDescription: String? {
            switch self {
            case let .notReady(why): why
            }
        }
    }

    /// The languages picked in Settings, or the iPhone's if none yet.
    static func languages() async -> [Locale] {
        let picked = await MainActor.run { AppConfig.shared.languages }
        if !picked.isEmpty { return picked.map { Locale(identifier: $0) } }
        return await candidates()
    }

    /// A first guess at the languages: the iPhone's, then its keyboards',
    /// that on-device transcription supports. One per language (English
    /// (US) and English (UK) count once), at most three.
    static func candidates() async -> [Locale] {
        let keyboards = await MainActor.run { UITextInputMode.activeInputModes.compactMap(\.primaryLanguage) }
        var out: [Locale] = []
        for id in Locale.preferredLanguages + keyboards {
            guard out.count < 3,
                  let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)),
                  !out.contains(where: { Self.sameLanguage($0, match) }) else { continue }
            out.append(match)
        }
        return out.isEmpty ? [Locale(identifier: "en_US")] : out
    }

    /// Chinese is one language in Locale's eyes but Mandarin and Cantonese
    /// are different models, so compare the script/region as well for it.
    private static func sameLanguage(_ a: Locale, _ b: Locale) -> Bool {
        guard a.language.languageCode == b.language.languageCode else { return false }
        if a.language.languageCode == .chinese { return a.identifier == b.identifier }
        return true
    }

    private func requireInstalled(_ locale: Locale) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw Failure.notReady("On-device transcription isn't available for \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw Failure.notReady("Waiting for the \(Self.name(locale)) speech model. Open jotto to download it")
        }
        return transcriber
    }

    private static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: - Which language

    /// The language a recording is in, from its first segment. With one
    /// language there is nothing to decide. Otherwise the first 30 s go
    /// through each language's model and the most confident one wins.
    func detect(_ url: URL) async throws -> Locale {
        let candidates = await Self.languages()
        guard candidates.count > 1 else { return candidates[0] }
        #if DEBUG
        if ProcessInfo.processInfo.environment["JOTTO_FAKE_ASR"] != nil { return candidates[0] }
        #endif
        for locale in candidates { _ = try await requireInstalled(locale) }

        let sample = try Self.sample(url, seconds: 30)
        defer { try? FileManager.default.removeItem(at: sample) }
        var best: (locale: Locale, score: Double)?
        var scores: [String] = []
        for locale in candidates {
            let score = try await confidence(sample, locale: locale)
            scores.append("\(locale.identifier)=\(String(format: "%.2f", score))")
            if score > (best?.score ?? -1) { best = (locale, score) }
        }
        await PhoneLog.shared.noteAsync("asr_detect", scores.joined(separator: " "))
        return best?.locale ?? candidates[0]
    }

    /// Mean word confidence, weighted by how long each stretch is.
    private func confidence(_ url: URL, locale: Locale) async throws -> Double {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        async let total: (weighted: Double, length: Double) = transcriber.results.reduce(into: (0, 0)) { sum, result in
            for run in result.text.runs {
                guard let c = run.transcriptionConfidence else { continue }
                let text = result.text[run.range].characters
                let weight = Double(max(1, text.count))
                sum.weighted += c * weight
                sum.length += weight
            }
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let t = try await total
        return t.length > 0 ? t.weighted / t.length : 0
    }

    /// The first `seconds` of a file, as a temporary uncompressed copy.
    private static func sample(_ url: URL, seconds: Double) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), seconds * format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw CocoaError(.fileReadUnknown) }
        try file.read(into: buffer, frameCount: frames)
        let out = URL.temporaryDirectory.appending(path: "detect-\(UUID().uuidString).caf")
        let writer = try AVAudioFile(forWriting: out, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try writer.write(from: buffer)
        return out
    }

    // MARK: - Transcribing

    func transcribe(_ url: URL, locale: Locale) async throws -> [Phrase] {
        #if DEBUG
        // The simulator has no on-device speech model. Stand-in transcripts,
        // one `<segment index>.json` of [Phrase] per segment.
        if let dir = ProcessInfo.processInfo.environment["JOTTO_FAKE_ASR"],
           let index = Int(url.deletingPathExtension().lastPathComponent) {
            if let delay = ProcessInfo.processInfo.environment["JOTTO_FAKE_ASR_DELAY"].flatMap(Double.init) {
                try await Task.sleep(for: .seconds(delay))
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appending(path: "\(index).json"))
            return try JSONDecoder().decode([Phrase].self, from: data)
        }
        #endif
        // Word times, then sentences: a result alone can run a minute.
        return Sentences.phrases(try await tokens(url, locale: locale))
    }

    // MARK: - Mixed languages (experiment)

    /// Every language's model over the whole segment, word by word with
    /// times and confidence; `Mixer` then keeps the surer language for
    /// each stretch between pauses and sentence ends.
    func transcribeMixed(_ url: URL, languages: [Locale]) async throws -> (phrases: [Phrase], note: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["JOTTO_FAKE_ASR"] != nil {
            return (try await transcribe(url, locale: languages[0]), "fake")
        }
        #endif
        var heard: [String: [Mixer.Token]] = [:]
        for locale in languages {
            heard[locale.identifier] = try await tokens(url, locale: locale)
        }
        let pieces = Mixer.merge(heard)
        let counts = Dictionary(grouping: pieces, by: \.language).mapValues(\.count)
        let note = counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            + " words=" + heard.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
        return (pieces.flatMap { Sentences.phrases($0.tokens) }, note)
    }

    /// What one language's model heard, a word (or character) at a time.
    private func tokens(_ url: URL, locale: Locale) async throws -> [Mixer.Token] {
        _ = try await requireInstalled(locale)
        let preset = SpeechTranscriber.Preset.transcription
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions.union([.audioTimeRange, .transcriptionConfidence])
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        async let collected: [Mixer.Token] = transcriber.results.reduce(into: []) { out, result in
            var at = result.range.start.seconds
            for run in result.text.runs {
                let text = String(result.text[run.range].characters)
                // Punctuation and spaces come without times: they sit where
                // the last word ended.
                let start = run.audioTimeRange?.start.seconds ?? at
                let end = run.audioTimeRange?.end.seconds ?? at
                at = max(at, end)
                out.append(.init(text: text, start: start, end: end,
                                 confidence: run.transcriptionConfidence ?? 0.5))
            }
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }
}
