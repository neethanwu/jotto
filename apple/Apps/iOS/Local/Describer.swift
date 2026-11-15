import Foundation
import FoundationModels

/// Title, alternatives and a one-line summary from Apple's on-device
/// model, when the device has it (Apple Intelligence on). Titles came out
/// well in testing; its clean-up of the text itself didn't, so that stays
/// rule-based (`Cleanup`).
enum Describer {
    @Generable
    struct Description {
        @Guide(description: "What the conversation was about, in 2–6 words, like a calendar entry. Sentence case, no quotes, no period.")
        var title: String
        @Guide(description: "Three other titles in the same style, each from a different angle.", .count(3))
        var suggestions: [String]
        @Guide(description: "One or two plain sentences on what was said or decided, under 200 characters.")
        var summary: String

        /// What the pipeline keeps, whichever model wrote it.
        var plain: (title: String, suggestions: [String], summary: String) { (title, suggestions, summary) }
    }

    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    private static let instructions = """
    You name and summarize recordings for jotto, an app that records conversations on an Apple Watch. \
    Write the title, suggestions and summary in the language the transcript is mostly in. If it mixes Chinese and English, write in Chinese and keep English terms as said. \
    Only use what is in the transcript; never invent names or facts. Say what happened, not "the speakers discuss".
    """

    /// How much of the transcript to send so the question, the shape of
    /// the answer and the answer itself all fit the model's context (4,096
    /// tokens). Chinese takes about a token a character, English about a
    /// quarter of one, so a long Chinese recording sampled like an English
    /// one never fit, and failed the same way every time it was asked.
    private static func fittingLimit(_ paragraphs: [String]) async -> Int {
        var limit = 2400
        if #available(iOS 26.4, *) {
            let model = SystemLanguageModel.default
            let budget = model.contextSize - 1400
            while limit > 400, let tokens = try? await model.tokenCount(for: prompt(paragraphs, limit: limit)), tokens > budget {
                limit = limit * 2 / 3
            }
            return limit
        }
        let text = paragraphs.joined()
        let wide = text.unicodeScalars.filter { $0.value >= 0x2E80 }.count
        if Double(wide) > Double(text.unicodeScalars.count) * 0.3 { limit = 1200 }
        return limit
    }

    static func tooLong(_ error: Error) -> Bool {
        if #available(iOS 27, *), let e = error as? LanguageModelError, case .contextSizeExceeded = e { return true }
        if let e = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = e { return true }
        return false
    }

    /// Whether asking again later can go differently: no when the model
    /// won't write about this text, can't read its language, or can't fit
    /// it even cut down; yes when it was only busy or rate-limited; nil
    /// for anything else.
    static func isPassing(_ error: Error) -> Bool? {
        if #available(iOS 27, *), let e = error as? LanguageModelError {
            switch e {
            case .rateLimited, .timeout: return true
            default: return false
            }
        }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .rateLimited, .concurrentRequests, .assetsUnavailable: return true
            default: return false
            }
        }
        return nil
    }

    /// The model has a small context, so long transcripts are sampled:
    /// the start sets the topic, the end the outcome.
    static func prompt(_ paragraphs: [String], limit: Int = 2400) -> String {
        let text = paragraphs.joined(separator: "\n")
        guard text.count > limit else { return text }
        return String(text.prefix(Int(Double(limit) * 0.6))) + "\n[…]\n" + String(text.suffix(Int(Double(limit) * 0.4)))
    }

    static func describe(_ paragraphs: [String]) async throws -> Description {
        var limit = await fittingLimit(paragraphs)
        let response: LanguageModelSession.Response<Description>
        while true {
            do {
                let session = LanguageModelSession(instructions: instructions)
                response = try await session.respond(to: prompt(paragraphs, limit: limit), generating: Description.self)
                break
            } catch where tooLong(error) && limit > 400 {
                // Counted short: sample less of it and ask again.
                limit = limit / 2
            }
        }
        var d = response.content
        let tidy = { (s: String) in
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」『』.。"))
        }
        d.title = tidy(d.title)
        d.suggestions = d.suggestions.map(tidy).filter { !$0.isEmpty && $0.lowercased() != d.title.lowercased() }
        d.summary = String(d.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        return d
    }
}
