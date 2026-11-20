import AVFoundation
import Foundation
import Security

/// "Your own API key": transcription, titles and formatting through a
/// service the person pays for, instead of the models on this iPhone.
/// OpenRouter by default (one key for everything); any service with the
/// OpenAI API shape otherwise, at its address. From the App Store in China
/// mainland, Alibaba Cloud's Bailian and SiliconFlow take OpenRouter's
/// place, and only services that operate there are suggested (`StoreRegion`). The key lives in the
/// Keychain, and audio goes from the phone straight to that service.
enum Cloud {
    enum Service: String, CaseIterable, Identifiable {
        case openRouter, bailian, siliconFlow, compatible
        var id: String { rawValue }
        var name: String {
            switch self {
            case .openRouter: "OpenRouter"
            case .bailian: "Bailian"
            case .siliconFlow: "SiliconFlow"
            case .compatible: "Other service"
            }
        }
    }

    /// The services to choose from where this iPhone's App Store is: one
    /// with a key for everything (two in China mainland), and one at an
    /// address you enter.
    @MainActor static var services: [Service] {
        StoreRegion.shared.isChinaMainland ? [.bailian, .siliconFlow, .compatible] : [.openRouter, .compatible]
    }

    /// The service picked, or the store's own where it isn't offered.
    @MainActor static var service: Service {
        services.contains(config.cloudService) ? config.cloudService : services[0]
    }

    /// Once the App Store is known: a service it doesn't offer gives way
    /// to one it does, and an address left as it came, for a service
    /// outside China mainland, is emptied there.
    @MainActor static func settle() {
        if !services.contains(config.cloudService) { config.cloudService = services[0] }
        if StoreRegion.shared.isChinaMainland, provider(of: config.cloudBaseURL).map(chinaProviders.contains) == false {
            config.cloudBaseURL = ""
        }
        // Nor a model of a service from elsewhere, picked or left as it came.
        if StoreRegion.shared.isChinaMainland {
            if compatibleTranscribeModels.contains(where: { $0.id == config.compatibleTranscribeModel }) {
                config.compatibleTranscribeModel = ""
            }
            if compatibleWriteModels.contains(where: { $0.id == config.compatibleWriteModel }) {
                config.compatibleWriteModel = chinaCompatibleWriteModels[0].id
            }
        }
    }

    /// What a model is picked for: hearing the audio, or writing titles
    /// and tidying the text.
    enum ModelSlot: Hashable { case transcribe, write }

    /// A model to suggest, as the service names it; any other can be
    /// typed in. `by` is the service it's on, for services you reach by
    /// address.
    struct Suggestion: Hashable {
        let id: String
        let name: String
        var by: String?
    }

    /// On OpenRouter.
    static let transcribeModels: [Suggestion] = [
        .init(id: "microsoft/mai-transcribe-2", name: "MAI-2"),
        .init(id: "elevenlabs/scribe-v2", name: "Scribe v2"),
        .init(id: "openai/gpt-transcribe", name: "GPT Transcribe"),
        .init(id: "google/gemini-3.5-transcribe", name: "Gemini 3.5 Transcribe"),
    ]
    static let writeModels: [Suggestion] = [
        .init(id: "anthropic/claude-haiku-5.5", name: "Claude Haiku 5.5"),
        .init(id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5"),
        .init(id: "openai/gpt-6-luna", name: "GPT-6 Luna"),
        .init(id: "google/gemini-4-hydrogen", name: "Gemini 4 Hydrogen"),
    ]
    static let defaultTranscribeModel = "microsoft/mai-transcribe-2"
    static let defaultWriteModel = "anthropic/claude-haiku-5.5"

    /// On services reached by address, under their own names: OpenAI's
    /// and Groq's (Groq's Whisper gives times for each stretch; OpenAI's
    /// GPT Transcribe gives the text, which is then spread over the speech).
    static let compatibleTranscribeModels: [Suggestion] = [
        .init(id: "gpt-transcribe", name: "GPT Transcribe", by: "OpenAI"),
        .init(id: "whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", by: "Groq"),
        .init(id: "whisper-large-v3", name: "Whisper Large v3", by: "Groq"),
    ]
    static let compatibleWriteModels: [Suggestion] = [
        .init(id: "gpt-6-luna", name: "GPT-6 Luna", by: "OpenAI"),
        .init(id: "openai/gpt-oss-120b", name: "GPT-OSS 120B", by: "Groq"),
        .init(id: "openai/gpt-oss-20b", name: "GPT-OSS 20B", by: "Groq"),
    ]
    static let defaultCompatibleTranscribeModel = "gpt-transcribe"
    static let defaultCompatibleWriteModel = "gpt-6-luna"

    /// On SiliconFlow (China mainland), through the same transcription
    /// request as Whisper's. Tried in November 2026 on English and on
    /// Chinese with English words: Qwen3-ASR kept the punctuation and the
    /// English best; XingChen gives times; SenseVoice is the smallest.
    static let siliconFlowTranscribeModels: [Suggestion] = [
        .init(id: "Qwen/Qwen3-ASR-1.7B", name: "Qwen3-ASR 1.7B"),
        .init(id: "XingChenAGI/XingChenASR-V3.2", name: "XingChen ASR V3.2"),
        .init(id: "FunAudioLLM/SenseVoiceSmall", name: "SenseVoice Small"),
    ]
    static let siliconFlowWriteModels: [Suggestion] = [
        .init(id: "deepseek-ai/DeepSeek-V4-Flash", name: "DeepSeek V4 Flash"),
        .init(id: "deepseek-ai/DeepSeek-V4-Pro", name: "DeepSeek V4 Pro"),
        .init(id: "zai-org/GLM-5.3", name: "GLM-5.3"),
    ]
    static let defaultSiliconFlowTranscribeModel = "Qwen/Qwen3-ASR-1.7B"
    static let defaultSiliconFlowWriteModel = "deepseek-ai/DeepSeek-V4-Flash"
    static let siliconFlowBase = "https://api.siliconflow.cn/v1"

    /// On Alibaba Cloud's Bailian (China mainland). Qwen3-ASR Flash is
    /// the full Qwen3-ASR, not the 0.6B that runs on this iPhone; it takes
    /// audio in a chat request rather than a transcription one, and gives
    /// text without times. Qwen Plus and Flash answer without thinking
    /// first unless asked to.
    static let bailianTranscribeModels: [Suggestion] = [
        .init(id: "qwen3-asr-flash", name: "Qwen3-ASR Flash"),
    ]
    static let bailianWriteModels: [Suggestion] = [
        .init(id: "qwen-plus", name: "Qwen Plus"),
        .init(id: "qwen-flash", name: "Qwen Flash"),
        .init(id: "deepseek-v3.2", name: "DeepSeek V3.2"),
    ]
    static let defaultBailianTranscribeModel = "qwen3-asr-flash"
    static let defaultBailianWriteModel = "qwen-plus"
    /// The shared address, which takes a key from any workspace.
    static let bailianBase = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    /// At an address, in China mainland: services that operate there.
    /// DeepSeek's and Alibaba Cloud's own write; neither takes audio in
    /// the transcription request, so transcription is typed in.
    static let chinaCompatibleWriteModels: [Suggestion] = [
        .init(id: "deepseek-chat", name: "DeepSeek Chat", by: "DeepSeek"),
        .init(id: "qwen-plus", name: "Qwen Plus", by: "Alibaba Cloud"),
    ]
    static let chinaProviders: Set<String> = ["DeepSeek", "Alibaba Cloud", "SiliconFlow"]

    /// The known service an address belongs to, by its host.
    static func provider(of base: String) -> String? {
        guard let host = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines))?.host()?.lowercased() else { return nil }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("openai.com") { return "OpenAI" }
        if on("groq.com") { return "Groq" }
        if on("deepseek.com") { return "DeepSeek" }
        if on("aliyuncs.com") { return "Alibaba Cloud" }
        if on("siliconflow.cn") { return "SiliconFlow" }
        if on("openrouter.ai") { return "OpenRouter" }
        return nil
    }

    /// Services from outside China mainland, by their hosts: from the App
    /// Store there, an address at one of them isn't used.
    static func isAbroad(_ base: String) -> Bool {
        guard let host = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines))?.host()?.lowercased() else { return false }
        let abroad = ["openai.com", "openrouter.ai", "anthropic.com", "googleapis.com", "groq.com", "together.xyz",
                      "together.ai", "mistral.ai", "x.ai", "deepinfra.com", "fireworks.ai", "elevenlabs.io",
                      "azure.com", "siliconflow.com"]
        return abroad.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The address entered can't be used where this iPhone's App Store is.
    @MainActor static var addressBlocked: Bool {
        service == .compatible && StoreRegion.shared.isChinaMainland && isAbroad(config.cloudBaseURL)
    }

    /// What to suggest for the service in use; at an address we know,
    /// that service's own models first.
    @MainActor static func suggestions(_ slot: ModelSlot) -> [Suggestion] {
        switch service {
        case .openRouter: return slot == .transcribe ? transcribeModels : writeModels
        case .bailian: return slot == .transcribe ? bailianTranscribeModels : bailianWriteModels
        case .siliconFlow: return slot == .transcribe ? siliconFlowTranscribeModels : siliconFlowWriteModels
        case .compatible: break
        }
        let all = compatibleSuggestions(slot)
        guard let here = provider(of: config.cloudBaseURL) else { return all }
        return all.filter { $0.by == here } + all.filter { $0.by != here }
    }

    /// The model in use for each job, on the service in use.
    @MainActor static var transcribeModel: String {
        switch service {
        case .openRouter: config.transcribeModel
        case .bailian: config.bailianTranscribeModel
        case .siliconFlow: config.siliconFlowTranscribeModel
        case .compatible: config.compatibleTranscribeModel
        }
    }
    @MainActor static var writeModel: String {
        switch service {
        case .openRouter: config.writeModel
        case .bailian: config.bailianWriteModel
        case .siliconFlow: config.siliconFlowWriteModel
        case .compatible: config.compatibleWriteModel
        }
    }

    @MainActor static func setModel(_ model: String, for slot: ModelSlot) {
        switch (service, slot) {
        case (.openRouter, .transcribe): config.transcribeModel = model
        case (.openRouter, .write): config.writeModel = model
        case (.bailian, .transcribe): config.bailianTranscribeModel = model
        case (.bailian, .write): config.bailianWriteModel = model
        case (.siliconFlow, .transcribe): config.siliconFlowTranscribeModel = model
        case (.siliconFlow, .write): config.siliconFlowWriteModel = model
        case (.compatible, .transcribe): config.compatibleTranscribeModel = model
        case (.compatible, .write): config.compatibleWriteModel = model
        }
    }

    /// At an address: OpenAI's and Groq's, or in China mainland only
    /// services that operate there.
    @MainActor private static func compatibleSuggestions(_ slot: ModelSlot) -> [Suggestion] {
        if StoreRegion.shared.isChinaMainland { return slot == .transcribe ? [] : chinaCompatibleWriteModels }
        return slot == .transcribe ? compatibleTranscribeModels : compatibleWriteModels
    }

    /// The address now points at a service we know, and a model picked
    /// is one of another known service's: switch to this one's own.
    @MainActor static func matchModelsToAddress() {
        guard service == .compatible, let here = provider(of: config.cloudBaseURL) else { return }
        for slot in [ModelSlot.transcribe, .write] {
            let all = compatibleSuggestions(slot)
            let current = slot == .transcribe ? config.compatibleTranscribeModel : config.compatibleWriteModel
            if let picked = all.first(where: { $0.id == current }), picked.by != here,
               let own = all.first(where: { $0.by == here }) {
                setModel(own.id, for: slot)
            }
        }
    }

    /// Models whose service won't take m4a; their audio goes as WAV.
    private static let wavOnly: Set<String> = ["microsoft/mai-transcribe-2", "meta/muse-voice-transcribe-1.0"]

    static func displayName(_ model: String, in list: [Suggestion]) -> String {
        if model.isEmpty { return "Not set" }
        return list.first { $0.id == model }?.name ?? model.split(separator: "/").last.map(String.init) ?? model
    }

    // MARK: Settings

    @MainActor static var config: AppConfig { .shared }

    /// On, with a key to use, at an address that can be used here.
    @MainActor static var isOn: Bool { config.usesOwnKey && key != nil && !addressBlocked }

    @MainActor static var key: String? { Keychain.read(account: service.rawValue) }

    @MainActor static var baseURL: URL? { baseURL(for: service) }

    @MainActor static func baseURL(for service: Service) -> URL? {
        switch service {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
        case .bailian: URL(string: bailianBase)
        case .siliconFlow: URL(string: siliconFlowBase)
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
        /// OpenRouter, picked or at its address under Other service: its
        /// requests take audio as JSON, and a reasoning setting of its own.
        var isOpenRouter: Bool { service == .openRouter || base.host()?.lowercased().hasSuffix("openrouter.ai") == true }
        /// Alibaba Cloud's, picked or at its address: Qwen3-ASR there hears
        /// audio sent in a chat request, and models that can think are told not to.
        var isBailian: Bool { service == .bailian || Cloud.provider(of: base.absoluteString) == "Alibaba Cloud" }
    }

    @MainActor private static func endpoint() throws -> Endpoint {
        guard let key else { throw Failure.noKey }
        guard let base = baseURL, !addressBlocked else { throw Failure.badAddress }
        return Endpoint(base: base, key: key, service: service)
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
        case 408, 429, 500...599: throw Failure.unreachable("It answered \(status); jotto will try again.")
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }
            throw Failure.refused(message ?? "The service answered \(status).")
        }
    }

    private static func authorized(_ url: URL, _ endpoint: Endpoint) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        if endpoint.isOpenRouter {
            request.setValue("jotto", forHTTPHeaderField: "X-Title")
        }
        return request
    }

    /// Whether the key and address work: a cheap request that needs both.
    /// What trying a key said: it works, the service turned it down (or
    /// the address can't be one), or the service couldn't be asked.
    enum Check { case works, turnedDown, unanswered }

    static func check(key: String, service: Service, base: String) async -> Check {
        let address = switch service {
        case .openRouter: "https://openrouter.ai/api/v1/key"
        case .bailian: bailianBase + "/models"
        case .siliconFlow: siliconFlowBase + "/models"
        // OpenRouter's list of models is open to anyone: its key check instead.
        case .compatible: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            + (provider(of: base) == "OpenRouter" ? "/key" : "/models")
        }
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
        let model = transcribeModel
        let address = endpoint.base.appending(path: "audio/transcriptions")
        let data: Data
        if endpoint.isBailian, model.lowercased().contains("asr") {
            let t = try await transcribeInChat(url, model: model, endpoint: endpoint)
            return (try await spread(phrases(t, duration: duration), url: url), t.language)
        } else if endpoint.isOpenRouter {
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
            let audio = try await Task.detached { try Data(contentsOf: url) }.value
            // Times for each stretch where the model gives them (Whisper);
            // fewer options on each 400, down to the bare text.
            let attempts: [[(String, String)]] = [
                [("response_format", "verbose_json"), ("timestamp_granularities[]", "segment")],
                [("response_format", "verbose_json")],
                [("response_format", "json")],
            ]
            var last: Error = Failure.unreadable
            var answer: Data?
            for options in attempts {
                let boundary = "jotto-\(UUID().uuidString)"
                var request = authorized(address, endpoint)
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                var body = Data()
                for (name, value) in [("model", model)] + options {
                    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
                }
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"part.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
                body.append(audio)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                request.httpBody = body
                do {
                    let got = try await send(request)
                    // Some answer an option they don't take with nothing
                    // at all (Qwen3-ASR on SiliconFlow, to verbose_json).
                    guard (try? JSONDecoder().decode(Transcription.self, from: got)) != nil else {
                        last = Failure.unreadable
                        continue
                    }
                    answer = got
                    break
                } catch let Failure.refused(why) {
                    last = Failure.refused(why)
                }
            }
            guard let answer else { throw last }
            data = answer
        }
        guard let t = try? JSONDecoder().decode(Transcription.self, from: data) else { throw Failure.unreadable }
        let out = phrases(t, duration: duration)
        let timed = !(t.segments?.isEmpty ?? true) || !(t.words?.isEmpty ?? true)
        return (timed ? out : try await spread(out, url: url), t.language)
    }

    /// Text without times, as one phrase: spread over the speech in the
    /// audio, as with Qwen3-ASR on this iPhone, so playback still follows
    /// it sentence by sentence.
    private static func spread(_ phrases: [Phrase], url: URL) async throws -> [Phrase] {
        guard !phrases.isEmpty else { return phrases }
        let text = phrases.map(\.text).joined(separator: " ")
        let spread = try? await Task.detached(operation: { () throws -> [Phrase] in
            let samples = try QwenTranscriber.load(url)
            let energy = QwenASR.frameEnergy(samples, hop: QwenASR.sampleRate / 100)
            return QwenTranscriber.timed(text, energy: energy, offset: 0)
        }).value
        return spread?.isEmpty == false ? spread! : phrases
    }

    /// Qwen3-ASR on Bailian: the audio as WAV in a chat request, the text
    /// in the reply, and the language it heard beside it.
    private static func transcribeInChat(_ url: URL, model: String, endpoint: Endpoint) async throws -> Transcription {
        let audio = try await Task.detached { try Self.wav16k(from: url) }.value
        let encoded = audio.base64EncodedString()
        // Bailian takes up to 10 MB: about four minutes; parts are about one.
        guard encoded.utf8.count < 10_000_000 else { throw Failure.refused("This part is too long for Qwen3-ASR Flash.") }
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": [
                ["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64," + encoded]],
            ]]],
            "stream": false,
            // Numbers, dates and amounts written as figures, as other services do.
            "asr_options": ["enable_itn": true],
        ]
        var request = authorized(endpoint.base.appending(path: "chat/completions"), endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { throw Failure.unreadable }
        let language = (message["annotations"] as? [[String: Any]])?.lazy.compactMap { $0["language"] as? String }.first
        return Transcription(text: text, language: language, segments: nil, words: nil)
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

    /// 16 kHz mono 16-bit WAV, made from the samples rather than the file's
    /// own format, so it's that size whatever the part was recorded at.
    private static func wav16k(from url: URL) throws -> Data {
        let samples = try QwenTranscriber.load(url)
        var data = Data(capacity: 44 + samples.count * 2)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(QwenASR.sampleRate), bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for s in samples { put(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
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
        // The WAV header gets its lengths only when the file is closed:
        // read before, it says there's no audio, and MAI-2 hears nothing.
        target.close()
        return try Data(contentsOf: out)
    }

    // MARK: Writing

    /// Models that think before they answer, by name.
    static func thinks(_ model: String) -> Bool {
        let name = model.split(separator: "/").last.map(String.init)?.lowercased() ?? model
        return ["gpt-5", "gpt-6", "o1", "o3", "o4", "gpt-oss", "gemini-3", "gemini-4"].contains { name.hasPrefix($0) }
    }

    /// One chat completion; the reply's text.
    @MainActor static func chat(system: String, user: String, json: Bool = false) async throws -> String {
        let endpoint = try endpoint()
        var request = authorized(endpoint.base.appending(path: "chat/completions"), endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": writeModel,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if endpoint.isBailian {
            // Qwen3.5 and later think first unless told not to.
            body["enable_thinking"] = false
            body["temperature"] = 0.2
        } else if thinks(writeModel) {
            // A title or a tidied paragraph needs little thought, and
            // OpenAI's thinking models turn down any temperature but their own.
            if endpoint.isOpenRouter {
                body["reasoning"] = ["effort": "low"]
            } else {
                body["reasoning_effort"] = "low"
            }
        } else {
            body["temperature"] = 0.2
        }
        if json { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do {
            data = try await send(request)
        } catch Failure.refused where json {
            // Some models turn down JSON mode (GLM on SiliconFlow): the
            // prompt asks for JSON anyway, so ask again without it.
            body["response_format"] = nil
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            data = try await send(request)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw Failure.unreadable }
        return content
    }

    /// Title, three other titles and a summary, as the on-device `Describer` gives them.
    @MainActor static func describe(_ paragraphs: [String]) async throws -> (title: String, suggestions: [String], summary: String) {
        let system = """
        You name and summarize recordings for jotto, an app that records conversations on a watch or phone. \
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
