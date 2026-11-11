import Foundation

/// What the screens show: a recording in the list, in full, and search
/// results. Shaped like the beta server's JSON; recordings imported from
/// it keep their transcript in that shape.
struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let startedAt: Date
    let endedAt: Date?
    let status: String
    let title: String?
    let summary: String?
    let segmentCount: Int?
    let missingSegments: Int?
    let segmentsDone: Int?
    let segmentsReceived: Int?
    /// Latest line of transcript while recording.
    let lastLine: String?
    /// Moments and sections marked on the watch.
    var highlights: Int? = nil
}

struct SessionDetail: Decodable, Identifiable {
    struct Segment: Decodable {
        let index: Int
        let status: String
        let offset: Double
        let duration: Double
        let hasAudio: Bool
    }

    let id: String
    let status: String
    let startedAt: Date
    let endedAt: Date?
    let title: String?
    let titleByUser: Bool?
    let titleSuggestions: [String]?
    let summary: String?
    let segmentCount: Int?
    let missingSegments: Int?
    let segments: [Segment]
    let blocks: [TranscriptBlock]
    var highlights: [Highlight]? = nil
}

/// A moment (the star) or a section ([ ]) marked on the watch, as the
/// stretch of the recording it covers, in seconds from the start.
struct Highlight: Codable, Hashable, Identifiable {
    /// Where the star was pressed, or where the section began.
    let at: Double
    let start: Double
    let end: Double
    let isSection: Bool

    var id: String { "\(isSection ? "s" : "m")\(at)" }

    /// People mark after they hear it, so a moment reaches further back.
    static let before: Double = 30
    static let after: Double = 10

    static func moment(at t: Double) -> Highlight {
        Highlight(at: t, start: max(0, t - before), end: t + after, isSection: false)
    }

    static func section(from start: Double, to end: Double) -> Highlight {
        Highlight(at: start, start: start, end: end, isSection: true)
    }

    func covers(_ block: TranscriptBlock) -> Bool {
        block.start < end && block.end > start
    }
}

struct TranscriptBlock: Codable, Identifiable, Hashable {
    let id: Int
    let section: Int
    let speaker: String?
    let start: Double
    let end: Double
    let text: String
    /// Polished text; nil while polish hasn't caught up.
    let clean: String?
    let backchannel: Bool?
}

struct SearchResults: Decodable {
    struct Hit: Decodable, Hashable {
        let start: Double
        let text: String
    }

    struct Session: Decodable, Identifiable, Hashable {
        let id: String
        let title: String?
        let startedAt: Date
        let endedAt: Date?
        let hits: [Hit]
    }

    let query: String
    let matches: Int
    let sessions: [Session]
}

struct Stats: Decodable {
    struct Window: Decodable {
        let recordings: Int
        let seconds: Int
    }

    let recordings: Int
    let seconds: Int
    let lastSevenDays: Window
    let audioRetentionDays: Int
}

/// What the screens read and change. Everything lives on this iPhone
/// (`LocalStore`); the names stay from when a server answered them.
@MainActor
enum API {
    static func sessions() async throws -> [SessionSummary] { LocalStore.shared.sessions() }

    static func session(_ id: String) async throws -> SessionDetail { try LocalStore.shared.session(id) }

    static func rename(_ id: String, to title: String) async throws { LocalStore.shared.rename(id, to: title) }

    static func delete(_ id: String) async throws { LocalStore.shared.delete(id) }

    static func search(_ query: String) async throws -> SearchResults { LocalStore.shared.search(query) }

    static func stats() async throws -> Stats { LocalStore.shared.stats() }

    /// One segment's audio, if the phone still keeps it.
    static func audio(session: String, index: Int) async throws -> URL {
        let url = AudioFiles.url(session: session, index: index)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
}
