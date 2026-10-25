import Foundation

/// Read side of the backend (`server/src/routes/sessions.ts`).
/// Uploads go through `Uploader` instead, so they survive suspension.
struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    let startedAt: Date
    let endedAt: Date?
    let status: String
}

struct SessionDetail: Decodable {
    struct Segment: Decodable {
        let index: Int
        let status: String
    }

    let id: String
    let status: String
    let startedAt: Date
    let endedAt: Date?
    let segmentCount: Int?
    let segments: [Segment]
    let blocks: [TranscriptBlock]
}

struct TranscriptBlock: Decodable, Identifiable {
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

enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No server address and token yet"
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

    @MainActor
    static func request(_ path: String, method: String = "GET") throws -> URLRequest {
        let config = AppConfig.shared
        guard config.isReady, let base = config.baseURL else { throw APIError.notConfigured }
        let collection = base.appending(path: "v1/sessions")
        // `appending(path: "")` would add a trailing slash, which the server 404s.
        var request = URLRequest(url: path.isEmpty ? collection : collection.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try decoder.decode(T.self, from: data)
    }

    @MainActor
    static func sessions() async throws -> [SessionSummary] {
        struct List: Decodable { let sessions: [SessionSummary] }
        return try await send(request(""), as: List.self).sessions
    }

    @MainActor
    static func session(_ id: String) async throws -> SessionDetail {
        try await send(request(id), as: SessionDetail.self)
    }

    @MainActor
    static func delete(_ id: String) async throws {
        let (data, response) = try await URLSession.shared.data(for: request(id, method: "DELETE"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }
}
