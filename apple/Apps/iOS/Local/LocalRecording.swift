import Foundation

/// One recording as the phone keeps it when it does the work itself:
/// the watch's segments, what was heard in each, and what came of it.
/// Stored as Documents/Recordings/<id>.json; audio stays in Documents/Sessions.
struct LocalRecording: Codable, Identifiable, Hashable {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    /// How many segments the watch says it made; known once it stops.
    var segmentCount: Int?
    var segments: [Int: LocalSegment] = [:]
    /// Clean text by raw paragraph text, so it survives re-layout.
    var clean: [String: String] = [:]
    var title: String?
    var titleByUser = false
    var titleSuggestions: [String] = []
    var summary: String?
    /// Highlights, as seconds from the start.
    var marks: [Double] = []
    /// Set when clean-up is done; the recording is then ready.
    var polishedAt: Date?
    /// Set once a title and summary have been written (may lag polish:
    /// the on-device model is rate-limited in the background).
    var describedAt: Date?
    /// Segments given up on after the recording ended (see `Pipeline`).
    var missing: Int = 0

    var isEnded: Bool { endedAt != nil }
    var transcribed: [LocalSegment] { segments.values.filter { $0.phrases != nil }.sorted { $0.index < $1.index } }

    var status: String {
        if endedAt == nil { return "recording" }
        return polishedAt == nil ? "processing" : "ready"
    }

    /// Every segment the watch made has been heard (or given up on).
    var allTranscribed: Bool {
        guard let segmentCount else { return false }
        let done = segments.values.filter { $0.phrases != nil || $0.failed != nil }.count
        return done + missing >= segmentCount
    }
}

struct LocalSegment: Codable, Hashable {
    let index: Int
    /// Seconds from the start of the recording.
    let offset: Double
    let duration: Double
    /// Nil until transcribed.
    var phrases: [Phrase]?
    var failed: String?
}

/// A stretch of speech, in seconds from the start of its segment.
struct Phrase: Codable, Hashable {
    let start: Double
    let end: Double
    let text: String
}
