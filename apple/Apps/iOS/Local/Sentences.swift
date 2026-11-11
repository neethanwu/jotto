import Foundation

/// Cuts what a model heard, word by word, into sentences with their own
/// times. One recognizer result can run a minute or more without a break;
/// sentences give the transcript real timestamps and short paragraphs,
/// and let a highlight land on what was said around it.
enum Sentences {
    private static let ends: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";"]
    private static let soft: Set<Character> = ["，", ",", "、", "：", ":"]

    /// A sentence ends at closing punctuation, at a pause, or once it runs
    /// long (at the next comma or small pause, else regardless).
    static let pause = 0.9
    static let longUnits = 30.0
    static let maxUnits = 60.0

    static func phrases(_ tokens: [Mixer.Token]) -> [Phrase] {
        var out: [Phrase] = []
        var current: [Mixer.Token] = []

        func flush() {
            defer { current = [] }
            guard let first = current.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let last = current.last else { return }
            let text = current.map(\.text).joined()
                .replacingOccurrences(of: #"\s+([，。！？、；：])"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            out.append(Phrase(start: first.start, end: max(first.start, last.end), text: text))
        }

        for (i, token) in tokens.enumerated() {
            current.append(token)
            let mark = token.text.trimmingCharacters(in: .whitespaces).last
            let gap = i + 1 < tokens.count ? tokens[i + 1].start - token.end : 0
            let units = Self.units(current)
            if let mark, ends.contains(mark), units >= 4 {
                flush()
            } else if gap >= pause {
                flush()
            } else if units >= longUnits, gap >= 0.25 || mark.map(soft.contains) == true {
                flush()
            } else if units >= maxUnits {
                flush()
            }
        }
        flush()
        return out
    }

    /// Roughly how much there is to read: a CJK character is one, a Latin
    /// letter a third (so ~30 units is a Chinese clause or ~15 words).
    static func units(_ tokens: [Mixer.Token]) -> Double {
        tokens.reduce(0) { $0 + units($1.text) }
    }

    static func units(_ text: String) -> Double {
        text.reduce(0) { $0 + (isCJK($1) ? 1 : ($1.isLetter || $1.isNumber) ? 1.0 / 3 : 0) }
    }

    static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
    }
}
