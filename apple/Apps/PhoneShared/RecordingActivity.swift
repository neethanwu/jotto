import ActivityKit
import AppIntents
import Foundation

/// A recording on the lock screen and in the Dynamic Island (designs 10
/// and 11). Compiled into the app and its widget extension. The app
/// starts it when it is open during a recording (iOS only lets an app in
/// front start one), keeps it current, and ends it when the watch stops.
struct RecordingActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var moments: Int = 0
        var sections: Int = 0
        var sectionOpen = false
        /// The latest line heard, for the expanded island only.
        var lastLine: String?

        var marks: Int { moments + sections }
    }

    let sessionID: String
    let startedAt: Date
}

/// Mark this moment, from the lock screen or the island. Runs in the app.
struct MarkMomentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark this moment"
    static let isDiscoverable = false

    @Parameter(title: "Recording") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !JOTTO_LIVE_EXTENSION
        if let r = LocalStore.shared.recordings[sessionID] {
            Pipeline.shared.markNow(sessionID, startedAt: r.startedAt)
        }
        #endif
        return .result()
    }
}

/// Start or end a section, from the lock screen or the island. Runs in the app.
struct ToggleSectionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start or end a section"
    static let isDiscoverable = false

    @Parameter(title: "Recording") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !JOTTO_LIVE_EXTENSION
        if let r = LocalStore.shared.recordings[sessionID] {
            Pipeline.shared.toggleSection(sessionID, startedAt: r.startedAt)
        }
        #endif
        return .result()
    }
}
