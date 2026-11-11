import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech-to-text (SpeechAnalyzer). Free, private, and
/// fast: about 2.6 s for a 2-minute segment on an M-series Mac. One
/// language at a time; no speaker labels.
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

    /// The language to listen for: the user's choice, else the first
    /// preferred language the system supports, else English.
    static func preferredLocale() async -> Locale {
        if let saved = UserDefaults.standard.string(forKey: "transcriptionLocale") {
            return Locale(identifier: saved)
        }
        return await automaticLocale()
    }

    /// What Automatic picks: the first of the iPhone's languages that
    /// on-device transcription supports. One language for every recording;
    /// it doesn't listen and choose.
    static func automaticLocale() async -> Locale {
        for id in Locale.preferredLanguages {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) {
                return match
            }
        }
        return Locale(identifier: "en_US")
    }

    /// Downloads the language model if needed. Call while in the foreground.
    func prepare(status: @MainActor @escaping (String?) -> Void = { _ in }) async {
        let locale = await Self.preferredLocale()
        let supported = await SpeechTranscriber.supportedLocales
        await PhoneLog.shared.noteAsync("asr_prepare", "locale=\(locale.identifier) supported=\(supported.count) available=\(SpeechTranscriber.isAvailable)")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                await PhoneLog.shared.noteAsync("asr_download", locale.identifier)
                await status("Downloading the speech model")
                try await request.downloadAndInstall()
                await PhoneLog.shared.noteAsync("asr_downloaded", locale.identifier)
            }
            await status(nil)
        } catch {
            await PhoneLog.shared.noteAsync("asr_download_failed", error.localizedDescription)
            await status("Couldn't download the speech model. Open Jotto on Wi-Fi to try again")
        }
    }

    func transcribe(_ url: URL) async throws -> [Phrase] {
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
        let locale = await Self.preferredLocale()
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw Failure.notReady("On-device transcription isn't available for \(locale.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw Failure.notReady("The \(locale.identifier) speech model isn't downloaded yet")
        }
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
