import Foundation
import FoundationModels
import NaturalLanguage

/// Tidies each paragraph with Apple's on-device model, the way a
/// dictation app does: fillers and false starts out, a self-correction
/// kept as corrected, proper sentences and punctuation. Same words,
/// same order, nothing added. Runs after the rule-based clean-up
/// (`Cleanup`), paragraph by paragraph, while jotto is open: the model
/// is rate-limited in the background.
///
/// Every answer is checked against what was said (`accept`); one that
/// drops or invents too much is thrown away and the rule-based text stays.
enum Editor {
    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    static let instructions = """
    You are the editor in a dictation app. You get one passage of raw speech-to-text and return it as clean written text, the way a good assistant tidies a voice note: same language, same words and meaning, same order, first person kept.

    Remove: fillers (嗯 呃 啊 哎 哦 那个 就是说 然后呢 um uh like you know I mean), stutters and repeated words, and false starts. When the speaker corrects themselves, keep only the correction.
    Fix: punctuation and sentence breaks; Chinese takes full-width punctuation (，。？！). A word the recognizer clearly misheard, when the context makes the right one obvious.
    Keep: every point, name, number and term. English words inside Chinese stay in English as said. Don't summarize, explain, translate or reply to the passage.

    Example
    Raw: 呃我觉得那个就是我们这个这个方案的话呃预算可能不太够然后我们下周一啊不是下周二再开个会吧
    Clean: 我觉得我们这个方案的预算可能不太够。我们下周二再开个会吧。

    Example
    Raw: so um we we need to like ship the the beta on friday uh no actually thursday because the the client demo is on friday you know
    Clean: We need to ship the beta on Thursday, because the client demo is on Friday.

    Reply with the clean passage only.
    """

    /// The tidied paragraph, or nil when the model's answer doesn't hold
    /// up against `rough` (the rule-based clean-up of the same words).
    static func tidy(_ rough: String) async throws -> String? {
        // A lone "嗯" or "OK": nothing to tidy.
        guard Sentences.units(rough) >= 4 else { return nil }
        let reply: String
        if await Cloud.isOn {
            reply = try await Cloud.chat(system: instructions, user: rough)
        } else {
            let session = LanguageModelSession(instructions: instructions)
            reply = try await session.respond(to: rough, options: GenerationOptions(temperature: 0.2)).content
        }
        var out = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Clean:", "Clean：", "clean:"] where out.hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」"))
        return accept(out, rough: rough) ? out : nil
    }

    /// Several passages in one request. Out of sight on battery, Apple's
    /// model answers about eight requests and then nothing for a quarter
    /// of an hour or more; a recording formatted a paragraph at a time
    /// needs one per paragraph, in batches a few for the whole of it. Only
    /// used there: tried on a Mac, a batch came back plainer than the same
    /// passages one at a time, and without each passage's language named
    /// it turned English passages into Chinese. Each passage comes back
    /// under its own number and is checked on its own, as `tidy` does.
    static let batchInstructions = instructions.replacingOccurrences(of: "Reply with the clean passage only.", with: """
    You get several passages at once. Each starts with a line giving its number and the language it was mostly said in, like "[2] English". Clean each passage on its own, as above, in that language: an English passage stays English, a Chinese one stays Chinese. Reply with every passage in the same order, each after a line with just its number:

    Example
    [1] Chinese
    呃我们下周一啊不是下周二再开个会吧
    [2] English
    so um we we need to like ship it on friday
    Reply:
    [1]
    我们下周二再开个会吧。
    [2]
    We need to ship it on Friday.

    Never merge, split, drop, reorder or translate passages. Reply with the numbered passages only.
    """)

    /// The language a passage is mostly in, named in English for the batch.
    static func languageName(_ text: String) -> String {
        let code = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
        return name.hasPrefix("Chinese") ? "Chinese" : name
    }

    struct BatchMismatch: Error {}

    /// The tidied passages in order, nil for one that doesn't hold up
    /// against its rough text. Throws `BatchMismatch` when the answer
    /// doesn't come back as the same numbered passages.
    static func tidyBatch(_ roughs: [String]) async throws -> [String?] {
        let languages = roughs.map(languageName)
        let numbered = roughs.enumerated().map { "[\($0.offset + 1)] \(languages[$0.offset])\n\($0.element)" }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: batchInstructions)
        let reply = try await session.respond(to: numbered, options: GenerationOptions(temperature: 0.2)).content
        var parts: [Int: [String]] = [:]
        var current: Int?
        for line in reply.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]"),
               let n = Int(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) {
                current = n
                let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                // "[2] English" echoed back is the header, not the text.
                let echo = (1...roughs.count).contains(n) && rest == languages[n - 1]
                parts[n] = rest.isEmpty || echo ? [] : [rest]
            } else if let n = current, !trimmed.isEmpty {
                parts[n, default: []].append(trimmed)
            }
        }
        guard parts.count == roughs.count, (1...roughs.count).allSatisfy({ parts[$0] != nil }) else { throw BatchMismatch() }
        return roughs.enumerated().map { i, rough in
            guard Sentences.units(rough) >= 4 else { return nil }
            let out = (parts[i + 1] ?? []).joined(separator: rough.unicodeScalars.contains { $0.value >= 0x2E80 } ? "" : " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」").union(.whitespaces))
            return accept(out, rough: rough) ? out : nil
        }
    }

    /// The next passages to send together: up to six, and about 900 tokens
    /// of text (Chinese about a token a character, other text about a
    /// quarter of one), so the passages, their answer and the instructions
    /// fit the model's 4,096. Always at least one.
    static func batch(_ roughs: [String]) -> Int {
        var count = 0, tokens = 0.0
        for rough in roughs.prefix(6) {
            let wide = rough.unicodeScalars.filter { $0.value >= 0x2E80 }.count
            let cost = Double(wide) + Double(rough.unicodeScalars.count - wide) / 3.5
            if count > 0, tokens + cost > 900 { break }
            count += 1
            tokens += cost
        }
        return max(1, count)
    }

    /// An error about this passage rather than the model being busy: it
    /// won't get better by asking again. iOS 27 reports these as a new
    /// error type, which this used to miss, so a paragraph the model
    /// wouldn't touch was tried again at every launch.
    static func isAboutThisText(_ error: Error) -> Bool {
        Describer.isPassing(error) == false
    }

    /// Most of what was said is still there, in order, and little is new.
    static func accept(_ out: String, rough: String) -> Bool {
        guard !out.isEmpty, !out.contains("\n\n") else { return false }
        let o = Fillers.overlap(rough, out)
        guard o.total > 0 else { return false }
        // Short passages can lose a filler or two the rules missed.
        let keep = o.total < 12 ? 0.6 : 0.72
        return Double(o.matched) / Double(o.total) >= keep
            && Double(o.matched) / Double(max(1, o.added + o.matched)) >= 0.75
    }
}
