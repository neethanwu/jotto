import Foundation
import Observation

/// The app's settings, kept in UserDefaults.
@MainActor @Observable
final class AppConfig {
    static let shared = AppConfig()

    /// The language on-device transcription listens for; empty means
    /// let each recording pick from the iPhone's languages. Read by `OnDeviceTranscriber`.
    var transcriptionLocale: String {
        didSet { UserDefaults.standard.set(transcriptionLocale.isEmpty ? nil : transcriptionLocale, forKey: "transcriptionLocale") }
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

    /// A notice when a recording is ready, with its title and summary.
    var notifiesWhenReady: Bool {
        didSet { UserDefaults.standard.set(notifiesWhenReady, forKey: "notifiesWhenReady") }
    }

    private init() {
        let defaults = UserDefaults.standard
        transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? ""
        keepAudioDays = defaults.object(forKey: "keepAudioDays") as? Int ?? 30
        opensOriginal = defaults.bool(forKey: "opensOriginal")
        writesTitles = defaults.object(forKey: "writesTitles") as? Bool ?? true
        notifiesWhenReady = defaults.object(forKey: "notifiesWhenReady") as? Bool ?? true
    }
}
