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
    /// The same paragraphs tidied by the on-device model (`Editor`), by
    /// raw text; the rule-based text where its answer didn't hold up.
    var tidy: [String: String]?
    /// Set once every paragraph has been through `Editor`.
    var tidiedAt: Date?
    var title: String?
    var titleByUser = false
    var titleSuggestions: [String] = []
    var summary: String?
    /// Highlights, as seconds from the start.
    var marks: [Double] = []
    /// Stretches marked with [ ]. Optional so recordings saved earlier still load.
    var sections: [MarkedSection]?
    /// Set when clean-up is done; the recording is then ready.
    var polishedAt: Date?
    /// Set once a title and summary have been written (may lag polish:
    /// the on-device model is rate-limited in the background).
    var describedAt: Date?
    /// Titles asked for and not written, counting only failures that
    /// would come round again; after a few it keeps its plain name.
    var describeTries: Int?
    /// The language it was heard in (a locale identifier), decided from
    /// the first part; nil until then. `mixed` for the experiment that
    /// runs every language and keeps the surest, stretch by stretch.
    var locale: String?
    static let mixed = "mixed"
    /// When the watch last said anything about it (started, a part, a mark).
    var heardAt: Date?
    /// When the "ready" notice went out (or was skipped), so it goes once.
    var notifiedAt: Date?
    /// When the notice asking to open jotto went out (time ran out out of
    /// sight with parts still to hear), so it goes once.
    var askedToOpenAt: Date?
    /// Segments given up on after the recording ended (see `Pipeline`).
    var missing: Int = 0
    /// The transcript as the test server made it, for recordings imported
    /// from it (speakers and its polish included). Nil for the phone's own.
    var imported: [TranscriptBlock]?

    struct MarkedSection: Codable, Hashable {
        let start: Double
        let end: Double
    }

    var isEnded: Bool { endedAt != nil }

    var highlights: [Highlight] {
        (marks.map(Highlight.moment(at:)) + (sections ?? []).map { Highlight.section(from: $0.start, to: $0.end) })
            .sorted { $0.at < $1.at }
    }
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
    /// Already had its one more go after failing (`Pipeline.retryFailedOnce`).
    var retried: Bool?
}

/// A stretch of speech, in seconds from the start of its segment.
struct Phrase: Codable, Hashable {
    let start: Double
    let end: Double
    let text: String
    /// Who said it, when a service with your own key tells speakers apart.
    /// Numbered per part: parts are heard separately.
    var speaker: String? = nil
}
