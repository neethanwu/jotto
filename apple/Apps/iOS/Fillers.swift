import Foundation

/// What the clean-up took out of a paragraph: the raw text split into
/// pieces, each either kept or removed (fillers, stutters, false starts).
/// The Original view strikes the removed pieces through.
///
/// Compares raw and clean word by word (character by character for CJK),
/// ignoring punctuation and case, and keeps the longest common sequence.
enum Fillers {
    struct Piece: Hashable {
        let text: String
        let removed: Bool
    }

    struct Result: Hashable {
        let pieces: [Piece]
        /// Runs of removed words, roughly "fillers gone".
        let removedRuns: Int
    }

    static func diff(raw: String, clean: String) -> Result {
        let a = tokens(raw)
        let b = tokens(clean).map(\.key).filter { !$0.isEmpty }
        let keys = a.map(\.key)
        let kept = lcsMask(keys, b)

        var pieces: [Piece] = []
        var runs = 0
        var inRun = false
        for (i, token) in a.enumerated() {
            // Punctuation and spaces have no key: they follow their neighbour.
            let removed = token.key.isEmpty ? inRun && nextRemoved(after: i, a, kept) : !kept[i]
            if !token.key.isEmpty {
                if removed && !inRun { runs += 1 }
                inRun = removed
            }
            if let last = pieces.last, last.removed == removed {
                pieces[pieces.count - 1] = Piece(text: last.text + token.text, removed: removed)
            } else {
                pieces.append(Piece(text: token.text, removed: removed))
            }
        }
        return Result(pieces: pieces, removedRuns: runs)
    }

    private struct Token {
        let text: String
        let key: String
    }

    private static func nextRemoved(after i: Int, _ a: [Token], _ kept: [Bool]) -> Bool {
        for j in (i + 1)..<a.count where !a[j].key.isEmpty { return !kept[j] }
        return false
    }

    /// Words with their trailing spaces; CJK characters one by one;
    /// punctuation on its own with an empty key.
    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            out.append(Token(text: word, key: word.lowercased()))
            word = ""
        }
        for ch in s {
            if isCJK(ch) {
                flush()
                out.append(Token(text: String(ch), key: String(ch)))
            } else if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                word.append(ch)
            } else {
                flush()
                // Attach spaces and punctuation as their own keyless pieces.
                out.append(Token(text: String(ch), key: ""))
            }
        }
        flush()
        return out
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
    }

    /// For each element of `a` (keyless ones ignored): is it part of the LCS with `b`?
    private static func lcsMask(_ a: [String], _ b: [String]) -> [Bool] {
        let idx = a.indices.filter { !a[$0].isEmpty }
        let n = idx.count, m = b.count
        var mask = [Bool](repeating: false, count: a.count)
        guard n > 0, m > 0 else { return mask }
        var table = [[UInt16]](repeating: [UInt16](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[idx[i]] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < n && j < m {
            if a[idx[i]] == b[j] {
                mask[idx[i]] = true
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return mask
    }
}
