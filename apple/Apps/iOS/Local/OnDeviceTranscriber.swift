import AVFoundation
import Foundation
import Speech
import UIKit

/// Apple's on-device speech-to-text (SpeechAnalyzer). Free, private, and
/// fast: about 2.6 s for a 2-minute segment on an M-series Mac. One
/// language per recording; no speaker labels.
///
/// The language is the user's pick, or with Automatic, whichever of the
/// iPhone's languages and keyboards the start of each recording sounds
/// most like (`detect`).
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

    /// The language picked in Settings, if not Automatic.
    static var chosenLocale: Locale? {
        UserDefaults.standard.string(forKey: "transcriptionLocale").map { Locale(identifier: $0) }
    }

    /// What Automatic chooses between: the iPhone's languages, then its
    /// keyboards, that on-device transcription supports. One per language
    /// (English (US) and English (UK) count once), at most three.
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

    /// The languages whose models should be on the phone.
    static func wantedLocales() async -> [Locale] {
        if let chosen = chosenLocale { return [chosen] }
        return await candidates()
    }

    /// Downloads the language models if needed. Call while in the foreground.
    func prepare(status: @MainActor @escaping (String?) -> Void = { _ in }) async {
        let locales = await Self.wantedLocales()
        await PhoneLog.shared.noteAsync("asr_prepare", "locales=\(locales.map(\.identifier)) available=\(SpeechTranscriber.isAvailable)")
        let transcribers = locales.map { SpeechTranscriber(locale: $0, preset: .transcription) }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: transcribers) {
                await PhoneLog.shared.noteAsync("asr_download", locales.map(\.identifier).joined(separator: ","))
                await status("Downloading the speech model")
                try await request.downloadAndInstall()
                await PhoneLog.shared.noteAsync("asr_downloaded")
            }
            await status(nil)
        } catch {
            await PhoneLog.shared.noteAsync("asr_download_failed", error.localizedDescription)
            await status("Couldn't download the speech model. Open Jotto on Wi-Fi to try again")
        }
    }

    private func requireInstalled(_ locale: Locale) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw Failure.notReady("On-device transcription isn't available for \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw Failure.notReady("Waiting for the \(Self.name(locale)) speech model. Open Jotto to download it")
        }
        return transcriber
    }

    private static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: - Which language

    /// The language a recording is in, from its first segment. With one
    /// candidate there is nothing to decide. Otherwise the first 30 s go
    /// through each language's model and the most confident one wins.
    func detect(_ url: URL) async throws -> Locale {
        if let chosen = Self.chosenLocale { return chosen }
        let candidates = await Self.candidates()
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
        let transcriber = try await requireInstalled(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        async let collected: [Phrase] = transcriber.results.reduce(into: []) { phrases, result in
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            phrases.append(Phrase(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }
}
