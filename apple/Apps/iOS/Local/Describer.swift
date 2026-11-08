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
    }

    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    private static let instructions = """
    You name and summarize recordings for Jotto, an app that records conversations on an Apple Watch. \
    Write the title, suggestions and summary in the language the transcript is mostly in. If it mixes Chinese and English, write in Chinese and keep English terms as said. \
    Only use what is in the transcript; never invent names or facts. Say what happened, not "the speakers discuss".
    """

    /// The model has a small context, so long transcripts are sampled:
    /// the start sets the topic, the end the outcome.
    static func prompt(_ paragraphs: [String], limit: Int = 2400) -> String {
        let text = paragraphs.joined(separator: "\n")
        guard text.count > limit else { return text }
        return String(text.prefix(Int(Double(limit) * 0.6))) + "\n[…]\n" + String(text.suffix(Int(Double(limit) * 0.4)))
    }

    static func describe(_ paragraphs: [String]) async throws -> Description {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt(paragraphs), generating: Description.self)
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
