import Foundation

/// Read side of the backend (`server/src/routes/`). Uploads go through
/// `Uploader` instead, so they survive suspension.
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

enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Not connected to a server yet"
        case let .http(code, body): "Server returned \(code): \(body)"
        }
    }
}

enum API {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            return try Date(raw, strategy: .iso8601)
        }
        return decoder
    }()

    /// A request under `/v1/`, e.g. `v1("sessions/\(id)")`.
    @MainActor
    static func v1(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        let config = AppConfig.shared
        guard config.isReady, let base = config.baseURL else { throw APIError.notConfigured }
        var url = base.appending(path: "v1").appending(path: path)
        if !query.isEmpty { url = url.appending(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// A request under `/v1/sessions`, as the uploader builds them.
    @MainActor
    static func request(_ path: String, method: String = "GET") throws -> URLRequest {
        // `appending(path: "")` would add a trailing slash, which the server 404s.
        try v1(path.isEmpty ? "sessions" : "sessions/\(path)", method: method)
    }

    @discardableResult
    static func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    static func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        try decoder.decode(T.self, from: try await data(request))
    }

    @MainActor
    static func sessions() async throws -> [SessionSummary] {
        if AppConfig.shared.processesLocally { return LocalStore.shared.sessions() }
        struct List: Decodable { let sessions: [SessionSummary] }
        return try await send(request(""), as: List.self).sessions
    }

    @MainActor
    static func session(_ id: String) async throws -> SessionDetail {
        if AppConfig.shared.processesLocally { return try LocalStore.shared.session(id) }
        return try await send(request(id), as: SessionDetail.self)
    }

    // The server itself, whatever the processing setting: for the import.

    @MainActor
    static func serverSessions() async throws -> [SessionSummary] {
        struct List: Decodable { let sessions: [SessionSummary] }
        return try await send(request(""), as: List.self).sessions
    }

    @MainActor
    static func serverSession(_ id: String) async throws -> SessionDetail {
        try await send(request(id), as: SessionDetail.self)
    }

    @MainActor
    static func serverAudio(session: String, index: Int) async throws -> Data {
        try await data(request("\(session)/audio/\(index)"))
    }

    @MainActor
    static func rename(_ id: String, to title: String) async throws {
        if AppConfig.shared.processesLocally { return LocalStore.shared.rename(id, to: title) }
        var request = try request(id, method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title])
        try await data(request)
    }

    @MainActor
    static func delete(_ id: String) async throws {
        if AppConfig.shared.processesLocally { return LocalStore.shared.delete(id) }
        try await data(request(id, method: "DELETE"))
    }

    @MainActor
    static func search(_ query: String) async throws -> SearchResults {
        if AppConfig.shared.processesLocally { return LocalStore.shared.search(query) }
        return try await send(v1("search", query: [URLQueryItem(name: "q", value: query)]), as: SearchResults.self)
    }

    @MainActor
    static func stats() async throws -> Stats {
        if AppConfig.shared.processesLocally { return LocalStore.shared.stats() }
        return try await send(v1("stats"), as: Stats.self)
    }

    /// One segment's audio, cached on disk. The phone usually still has the
    /// watch's copy (`Uploader.audioURL`), so this is the fallback.
    @MainActor
    static func audio(session: String, index: Int) async throws -> URL {
        let local = Uploader.audioURL(session: session, index: index)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let cached = URL.cachesDirectory.appending(path: "Audio/\(session)/\(index).m4a")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let data = try await data(request("\(session)/audio/\(index)"))
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cached)
        return cached
    }
}
