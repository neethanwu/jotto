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
    /// Paragraphs formatted so far, while the on-device model works.
    var formatting: SessionDetail.Tidying? = nil
    /// The on-device model is writing its title and summary right now.
    var naming = false
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
    /// The language it was heard in, a locale identifier.
    var language: String? = nil
    /// Paragraphs tidied so far and in all, while the on-device model works through them.
    var tidying: Tidying? = nil

    struct Tidying: Decodable, Hashable {
        let done: Int
        let total: Int
    }
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

    /// How far a moment reaches either side of the tap: 10 seconds each
    /// way by default, up to 30 (Settings → Highlights).
    static let defaultReach = 10
    static let maxReach = 30
    static var before: Double { reach("momentBefore") }
    static var after: Double { reach("momentAfter") }
    private static func reach(_ key: String) -> Double {
        Double(UserDefaults.standard.object(forKey: key) as? Int ?? defaultReach)
    }

    static func moment(at t: Double) -> Highlight {
        Highlight(at: t, start: max(0, t - before), end: t + after, isSection: false)
    }

    static func section(from start: Double, to end: Double) -> Highlight {
        Highlight(at: start, start: start, end: end, isSection: true)
    }

    /// A paragraph that only grazes the stretch (a second or two at its
    /// edge) isn't counted, unless the star was pressed during it.
    func covers(_ block: TranscriptBlock) -> Bool {
        let overlap = min(block.end, end) - max(block.start, start)
        guard overlap > 0 else { return false }
        if !isSection, block.start <= at, at <= block.end { return true }
        return overlap >= min(3, (block.end - block.start) / 2)
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
    /// Fillers and repeats taken out by rule, which Original strikes
    /// through. Nil for recordings imported from the server.
    var trimmed: String? = nil
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
