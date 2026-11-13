import AVFoundation
import Foundation
import Security

/// "Your own API key": transcription, titles and formatting through a
/// service the person pays for, instead of the models on this iPhone.
/// OpenRouter by default (one key for everything); any service with the
/// OpenAI API shape otherwise. The key lives in the Keychain, and audio
/// goes from the phone straight to that service.
enum Cloud {
    enum Service: String, CaseIterable, Identifiable {
        case openRouter, compatible
        var id: String { rawValue }
        var name: String { self == .openRouter ? "OpenRouter" : "OpenAI-compatible" }
    }

    /// What a model is picked for: hearing the audio, or writing titles
    /// and tidying the text.
    enum ModelSlot: Hashable { case transcribe, write }

    /// Suggested models; any other can be typed in.
    static let transcribeModels: [(id: String, name: String)] = [
        ("microsoft/mai-transcribe-2", "MAI-2"),
        ("elevenlabs/scribe-v2", "Scribe v2"),
        ("openai/gpt-transcribe", "GPT Transcribe"),
        ("google/gemini-3.5-transcribe", "Gemini 3.5 Transcribe"),
    ]
    static let writeModels: [(id: String, name: String)] = [
        ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5"),
        ("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5"),
        ("openai/gpt-5-mini", "GPT-5 mini"),
    ]
    static let defaultTranscribeModel = "microsoft/mai-transcribe-2"
    static let defaultWriteModel = "anthropic/claude-haiku-5.5"

    /// Models whose service won't take m4a; their audio goes as WAV.
    private static let wavOnly: Set<String> = ["microsoft/mai-transcribe-2", "meta/muse-voice-transcribe-1.0"]

    static func displayName(_ model: String, in list: [(id: String, name: String)]) -> String {
        list.first { $0.id == model }?.name ?? model.split(separator: "/").last.map(String.init) ?? model
    }

    // MARK: Settings

    @MainActor static var config: AppConfig { .shared }

    /// On, with a key to use.
    @MainActor static var isOn: Bool { config.usesOwnKey && key != nil }

    @MainActor static var key: String? { Keychain.read(account: config.cloudService.rawValue) }

    @MainActor static var baseURL: URL? {
        switch config.cloudService {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
        case .compatible:
            URL(string: config.cloudBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
    }

    enum Failure: LocalizedError {
        case noKey, badAddress, rejected, unreachable(String), refused(String), unreadable
        var errorDescription: String? {
            switch self {
            case .noKey: "No API key yet. Add one in Settings → Processing."
            case .badAddress: "The service address doesn't look right. Check it in Settings → Processing."
            case .rejected: "The API key was turned down. Check it in Settings → Processing."
            case let .unreachable(why): "Couldn't reach the transcription service. \(why)"
            case let .refused(why): why
            case .unreadable: "The service's answer couldn't be read."
            }
        }

        /// Worth trying again later (network, busy), rather than giving up on the part.
        var isPassing: Bool {
            switch self {
            case .unreachable, .rejected, .noKey, .badAddress: true
            case .refused, .unreadable: false
            }
        }
    }

    // MARK: Requests

    private struct Endpoint {
        let base: URL
        let key: String
        let service: Service
    }

    @MainActor private static func endpoint() throws -> Endpoint {
        guard let key else { throw Failure.noKey }
        guard let base = baseURL else { throw Failure.badAddress }
        return Endpoint(base: base, key: key, service: config.cloudService)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 120
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw Failure.rejected
        case 408, 429, 500...599: throw Failure.unreachable("It answered \(status); Jotto will try again.")
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }
            throw Failure.refused(message ?? "The service answered \(status).")
        }
    }

    private static func authorized(_ url: URL, _ endpoint: Endpoint) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        if endpoint.service == .openRouter {
            request.setValue("Jotto", forHTTPHeaderField: "X-Title")
        }
        return request
    }

    /// Whether the key and address work: a cheap request that needs both.
    /// What trying a key said: it works, the service turned it down (or
    /// the address can't be one), or the service couldn't be asked.
    enum Check { case works, turnedDown, unanswered }

    static func check(key: String, service: Service, base: String) async -> Check {
        let address = service == .openRouter ? "https://openrouter.ai/api/v1/key"
            : base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/models"
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true, url.host() != nil else { return .turnedDown }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return .unanswered }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return .works
        case 401, 403: return .turnedDown
        // Some services have no list of models to ask for: say nothing.
        default: return .unanswered
        }
    }

    // MARK: Transcription

    private struct Transcription: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
            let speaker: Label?
        }
        struct Word: Decodable {
            let word: String
            let start: Double
            let end: Double
            let speaker: Label?
        }
        /// Speakers come as numbers from some services and strings from others.
        struct Label: Decodable {
            let value: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let n = try? c.decode(Int.self) { value = String(n) }
                else { value = try c.decode(String.self).replacingOccurrences(of: "speaker_", with: "") }
            }
        }
        let text: String
        let language: String?
        let segments: [Segment]?
        let words: [Word]?
    }

    /// One part's audio, as phrases with times (and speakers, where the
    /// model tells them apart).
    @MainActor static func transcribe(_ url: URL, duration: Double) async throws -> (phrases: [Phrase], language: String?) {
        let endpoint = try endpoint()
        let model = config.transcribeModel
        let address = endpoint.base.appending(path: "audio/transcriptions")
        let data: Data
        if endpoint.service == .openRouter {
            let wav = wavOnly.contains(model)
            let audio = try await Task.detached { try wav ? Self.wav(from: url) : Data(contentsOf: url) }.value
            let base: [String: Any] = ["model": model, "input_audio": ["data": audio.base64EncodedString(), "format": wav ? "wav" : "m4a"]]
            // Not every model takes every option; fewer on each 400.
            let attempts: [[String: Any]] = [
                base.merging(["response_format": "verbose_json", "timestamp_granularities": ["segment"],
                              "provider": ["options": ["azure": ["diarization": ["enabled": true]],
                                                       "elevenlabs": ["diarize": true],
                                                       "assemblyai": ["speaker_labels": true],
                                                       "deepgram": ["diarize": true],
                                                       "mistral": ["diarize": true]]]]) { $1 },
                base.merging(["response_format": "verbose_json"]) { $1 },
                base.merging(["response_format": "json"]) { $1 },
            ]
            var last: Error = Failure.unreadable
            var answer: Data?
            for body in attempts {
                var request = authorized(address, endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                do {
                    answer = try await send(request)
                    break
                } catch let Failure.refused(why) {
                    last = Failure.refused(why)
                }
            }
            guard let answer else { throw last }
            data = answer
        } else {
            let boundary = "jotto-\(UUID().uuidString)"
            var request = authorized(address, endpoint)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
            }
            field("model", model)
            field("response_format", "verbose_json")
            field("timestamp_granularities[]", "segment")
            let audio = try await Task.detached { try Data(contentsOf: url) }.value
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"part.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
            body.append(audio)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body
            data = try await send(request)
        }
        guard let t = try? JSONDecoder().decode(Transcription.self, from: data) else { throw Failure.unreadable }
        return (phrases(t, duration: duration), t.language)
    }

    /// Speakers from the words when the segments don't carry them
    /// (ElevenLabs), else the segments, else the whole text as one phrase.
    private static func phrases(_ t: Transcription, duration: Double) -> [Phrase] {
        if let words = t.words, words.contains(where: { $0.speaker != nil }),
           !(t.segments ?? []).contains(where: { $0.speaker != nil }) {
            var out: [Phrase] = []
            var run: [Mixer.Token] = []
            var speaker: String?
            var previous = ""
            func flush() {
                out += Sentences.phrases(run).map { Phrase(start: $0.start, end: $0.end, text: $0.text, speaker: speaker) }
                run = []
            }
            for w in words {
                if w.speaker?.value != speaker, !run.isEmpty { flush() }
                speaker = w.speaker?.value
                // Latin words keep a space between them; CJK doesn't.
                let latin = { (c: Character?) in c.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
                let text = !previous.isEmpty && (latin(w.word.first) || latin(previous.last)) && !w.word.hasPrefix(" ") ? " " + w.word : w.word
                previous = w.word
                run.append(Mixer.Token(text: text, start: w.start, end: w.end, confidence: 1))
            }
            flush()
            return out
        }
        if let segments = t.segments, !segments.isEmpty {
            return segments.compactMap { s in
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : Phrase(start: s.start, end: max(s.start, s.end), text: text, speaker: s.speaker?.value)
            }
        }
        let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [Phrase(start: 0, end: duration, text: text)]
    }

    /// 16 kHz mono 16-bit WAV, for models that won't take AAC (≈1.9 MB a minute).
    private static func wav(from url: URL) throws -> Data {
        let source = try AVAudioFile(forReading: url)
        let out = URL.temporaryDirectory.appending(path: "jotto-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: source.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let target = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = source.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { throw Failure.unreadable }
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try target.write(from: buffer)
        }
        return try Data(contentsOf: out)
    }

    // MARK: Writing

    /// One chat completion; the reply's text.
    @MainActor static func chat(system: String, user: String, json: Bool = false) async throws -> String {
        let endpoint = try endpoint()
        var request = authorized(endpoint.base.appending(path: "chat/completions"), endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": config.writeModel,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw Failure.unreadable }
        return content
    }

    /// Title, three other titles and a summary, as the on-device `Describer` gives them.
    @MainActor static func describe(_ paragraphs: [String]) async throws -> (title: String, suggestions: [String], summary: String) {
        let system = """
        You name and summarize recordings for Jotto, an app that records conversations on a watch or phone. \
        Write in the language the transcript is mostly in; if it mixes Chinese and English, write in Chinese and keep English terms as said. \
        Only use what is in the transcript; never invent names or facts. Say what happened, not "the speakers discuss". \
        Reply with JSON only: {"title": "2–6 words, like a calendar entry, sentence case, no quotes or period", \
        "suggestions": ["three other titles from different angles"], "summary": "one or two plain sentences, under 200 characters"}
        """
        let reply = try await chat(system: system, user: Describer.prompt(paragraphs, limit: 24_000), json: true)
        let trimmed = reply.drop { $0 != "{" }.reversed().drop { $0 != "}" }.reversed()
        guard let data = String(trimmed).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String else { throw Failure.unreadable }
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」『』.。")) }
        let suggestions = ((object["suggestions"] as? [String]) ?? []).map(clean).filter { !$0.isEmpty && $0 != clean(title) }
        let summary = String(((object["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        return (clean(title), Array(suggestions.prefix(3)), summary)
    }
}

/// The API key, one per service, kept on this device only.
enum Keychain {
    private static let service = "com.neethanwu.jotto.apikey"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String?, account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(key.utf8)
        // Readable in the background after the first unlock, for the pipeline.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
