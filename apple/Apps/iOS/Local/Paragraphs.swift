import Foundation

/// Turns segment transcripts into paragraphs. A port of the server's
/// `polish/layout.ts`: same rules, so transcripts read the same either way.
enum Paragraphs {
    struct Utterance {
        let start: Double
        let end: Double
        let text: String
    }

    struct Block {
        let id: Int
        let section: Int
        var start: Double
        var end: Double
        var text: String
        var backchannel = false
    }

    /// Pause that starts a new paragraph.
    static let paragraphGap = 2.5
    /// Silence that starts a new section.
    static let sectionGap = 90.0
    /// Longer paragraphs are split at sentence ends.
    static let maxBlockChars = 400

    static func stitch(_ segments: [LocalSegment]) -> [Utterance] {
        segments.sorted { $0.index < $1.index }.flatMap { seg in
            (seg.phrases ?? []).compactMap { p in
                let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : Utterance(start: seg.offset + p.start, end: seg.offset + p.end, text: text)
            }
        }
    }

    static func blocks(_ utterances: [Utterance]) -> [Block] {
        var blocks: [Block] = []
        var section = 0
        var prevEnd: Double?
        var open: Int?

        for u in utterances {
            if let prevEnd, u.start - prevEnd >= sectionGap { section += 1 }
            prevEnd = max(prevEnd ?? 0, u.end)

            // No speaker labels on device, so a lone "嗯" only stands apart
            // when it's its own phrase; it doesn't end the paragraph.
            if isBackchannel(u.text), open != nil {
                blocks.append(Block(id: blocks.count, section: section, start: u.start, end: u.end, text: u.text, backchannel: true))
                continue
            }

            let pieces = splitSentences(u.text, max: maxBlockChars)
            let span = u.end - u.start
            let total = Double(max(1, u.text.count))
            var consumed = 0
            for (i, piece) in pieces.enumerated() {
                let start = u.start + span * Double(consumed) / total
                consumed += piece.count
                let end = u.start + span * Double(consumed) / total
                if let o = open, i == 0, blocks[o].section == section,
                   start - blocks[o].end < paragraphGap,
                   blocks[o].text.count + piece.count <= maxBlockChars {
                    blocks[o].text = join(blocks[o].text, piece)
                    blocks[o].end = end
                } else {
                    blocks.append(Block(id: blocks.count, section: section, start: start, end: end, text: piece))
                    open = blocks.count - 1
                }
            }
        }
        return blocks
    }

    static func splitSentences(_ text: String, max: Int) -> [String] {
        guard text.count > max else { return [text] }
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?；;".contains(ch) || (ch == "." ) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var pieces: [String] = []
        var piece = ""
        for s in sentences {
            if !piece.isEmpty, piece.count + s.count > max {
                pieces.append(piece)
                piece = ""
            }
            piece = piece.isEmpty ? s.trimmingCharacters(in: .whitespaces) : join(piece, s.trimmingCharacters(in: .whitespaces))
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }

    private static let backchannel = try! NSRegularExpression(
        pattern: "^(嗯哼|嗯嗯|嗯|对对对|对对|对|是的|是|好的|好|哦|噢|啊|ok|okay|yeah|yes|right|mm-?hmm|uh-huh)+$",
        options: [.caseInsensitive]
    )

    static func isBackchannel(_ text: String) -> Bool {
        let bare = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }
        let s = String(String.UnicodeScalarView(bare))
        guard !s.isEmpty, s.count <= 6 else { return false }
        return backchannel.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// A space between Latin words, none between CJK.
    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        let latin = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
        return (latin(last) || ",.!?".contains(last)) && latin(first) ? a + " " + b : a + b
    }
}
