import Foundation
import FoundationModels

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
