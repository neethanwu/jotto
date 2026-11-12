import Foundation
import Observation

/// The app's settings, kept in UserDefaults.
@MainActor @Observable
final class AppConfig {
    static let shared = AppConfig()

    /// The languages people speak in the recordings (locale identifiers),
    /// one to three. With more than one, each recording is matched to one
    /// (`OnDeviceTranscriber.detect`). Empty only until the first launch
    /// fills it from the iPhone's languages and keyboards.
    var languages: [String] {
        didSet { UserDefaults.standard.set(languages, forKey: "transcriptionLocales") }
    }
    static let maxLanguages = 3

    /// Experiment: with two or more languages, transcribe every recording
    /// in all of them and keep the surest, stretch by stretch.
    var mixesLanguages: Bool {
        didSet { UserDefaults.standard.set(mixesLanguages, forKey: "mixesLanguages") }
    }

    /// First launch: the iPhone's languages and keyboards, as a start.
    func fillLanguagesIfNeeded() async {
        guard languages.isEmpty else { return }
        languages = await OnDeviceTranscriber.candidates().map(\.identifier)
    }
    /// Days to keep audio after a recording is transcribed; 0 keeps it forever.
    var keepAudioDays: Int {
        didSet { UserDefaults.standard.set(keepAudioDays, forKey: "keepAudioDays") }
    }
    /// Transcripts open on Original rather than Clean.
    var opensOriginal: Bool {
        didSet { UserDefaults.standard.set(opensOriginal, forKey: "opensOriginal") }
    }
    /// Let the on-device model write titles and summaries.
    var writesTitles: Bool {
        didSet { UserDefaults.standard.set(writesTitles, forKey: "writesTitles") }
    }

    /// Let the on-device model tidy the text (`Editor`).
    var tidiesText: Bool {
        didSet { UserDefaults.standard.set(tidiesText, forKey: "tidiesText") }
    }

    /// How far a moment (the star) reaches before and after the tap, in seconds.
    var momentBefore: Int {
        didSet { UserDefaults.standard.set(momentBefore, forKey: "momentBefore") }
    }
    var momentAfter: Int {
        didSet { UserDefaults.standard.set(momentAfter, forKey: "momentAfter") }
    }

    /// A notice when a recording is ready, with its title and summary.
    var notifiesWhenReady: Bool {
        didSet { UserDefaults.standard.set(notifiesWhenReady, forKey: "notifiesWhenReady") }
    }

    private init() {
        let defaults = UserDefaults.standard
        // Before 2026-11-11 there was one language, or Automatic (none).
        mixesLanguages = defaults.bool(forKey: "mixesLanguages")
        languages = defaults.stringArray(forKey: "transcriptionLocales")
            ?? defaults.string(forKey: "transcriptionLocale").map { [$0] } ?? []
        keepAudioDays = defaults.object(forKey: "keepAudioDays") as? Int ?? 30
        opensOriginal = defaults.bool(forKey: "opensOriginal")
        writesTitles = defaults.object(forKey: "writesTitles") as? Bool ?? true
        notifiesWhenReady = defaults.object(forKey: "notifiesWhenReady") as? Bool ?? true
        tidiesText = defaults.object(forKey: "tidiesText") as? Bool ?? true
        momentBefore = defaults.object(forKey: "momentBefore") as? Int ?? Highlight.defaultReach
        momentAfter = defaults.object(forKey: "momentAfter") as? Int ?? Highlight.defaultReach
    }
}
