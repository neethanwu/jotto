import Foundation

/// Merges what several languages' models heard into one transcript,
/// keeping the surer language for each stretch of speech.
enum Mixer {
    /// One word (or character, in Chinese) a model heard.
    struct Token {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double
        var mid: Double { (start + end) / 2 }
        var length: Double { max(0.05, end - start) }
    }

    struct Piece: Equatable {
        let start: Double
        let end: Double
        let text: String
        let language: String
    }

    private static let sentenceEnds: Set<Character> = ["。", ".", "!", "?", "！", "？"]

    /// Where one model thinks a sentence ends: after closing punctuation,
    /// at a pause, or around a long token (a guess at a stretch it didn't
    /// understand).
    private static func cuts(_ tokens: [Token]) -> [Double] {
        var out: [Double] = []
        for (i, t) in tokens.enumerated() {
            if t.length > 2 { out += [t.start, t.end] }
            if let last = t.text.trimmingCharacters(in: .whitespaces).last, sentenceEnds.contains(last) { out.append(t.end) }
            if i + 1 < tokens.count, tokens[i + 1].start - t.end >= 0.3 { out.append((t.end + tokens[i + 1].start) / 2) }
        }
        if let last = tokens.last { out.append(last.end) }
        return out
    }

    static func merge(_ heard: [String: [Token]]) -> [Piece] {
        // Cut points from every language; ones close together are one cut.
        let raw = heard.values.flatMap(cuts).sorted()
        var cuts: [Double] = []
        var group: [Double] = []
        for c in raw {
            if let first = group.first, c - first > 0.6 {
                cuts.append(group.reduce(0, +) / Double(group.count))
                group = []
            }
            group.append(c)
        }
        if !group.isEmpty { cuts.append(group.reduce(0, +) / Double(group.count)) }
        let edges = [-Double.infinity] + cuts.dropLast() + [Double.infinity]

        var pieces: [Piece] = []
        for w in 0..<(edges.count - 1) {
            let lo = edges[w], hi = edges[w + 1]
            var best: (language: String, tokens: [Token], score: Double)?
            var inWindow: [String: [Token]] = [:]
            for (language, tokens) in heard {
                let here = tokens.filter { $0.mid >= lo && $0.mid < hi }
                if !here.isEmpty { inWindow[language] = here }
            }
            let widest = inWindow.values.map { $0.reduce(0) { $0 + $1.length } }.max() ?? 0
            for (language, here) in inWindow {
                let covered = here.reduce(0) { $0 + $1.length }
                guard covered >= widest * 0.5 else { continue }
                let score = here.reduce(0) { $0 + $1.confidence * $1.length } / covered
                if score > (best?.score ?? -1) { best = (language, here, score) }
            }
            guard let best else { continue }
            var text = best.tokens.map(\.text).joined()
            if pieces.isEmpty || pieces.last?.language != best.language {
                text = text.drop { $0.isWhitespace || $0.isPunctuation }.description
            }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let piece = Piece(start: best.tokens.first!.start, end: best.tokens.last!.end, text: text, language: best.language)
            if let last = pieces.last, last.language == piece.language {
                pieces[pieces.count - 1] = Piece(start: last.start, end: piece.end, text: last.text + piece.text, language: last.language)
            } else {
                pieces.append(piece)
            }
        }
        return pieces.map { Piece(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespaces), language: $0.language) }
    }
}
