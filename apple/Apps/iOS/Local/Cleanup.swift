import Foundation

/// Clean-up without a model: drop fillers and stutters, keep every word
/// that carries meaning. The Original view strikes out what this removes.
enum Cleanup {
    private static let rules: [(NSRegularExpression, String)] = [
        // Chinese fillers anywhere, with the comma that follows them.
        (#"[嗯呃额]+[，,、]?"#, ""),
        // 啊/哦 opening a clause, with or without a comma.
        (#"(^|[，。！？,.!?；;\s])(啊|哦|噢|诶|欸)[，,]?"#, "$1"),
        // A particle trailing off mid-sentence: "我觉得啊，" → "我觉得，".
        (#"(\p{Han})(啊|呀|哈)(?=[，,])"#, "$1"),
        // Filler 就是/然后/那个 doubled up: 就是就是 → 就是.
        (#"(\p{Han}{2,4})\1+"#, "$1"),
        // English fillers.
        (#"(?i)\b(um+|uh+|erm|hmm+|uhm)\b[,]?\s*"#, ""),
        // Repeated English words: "the the" → "the".
        (#"(?i)\b([a-z']+)(\s+\1\b)+"#, "$1"),
        // Tidy what's left.
        (#"\s+([，。！？、；：])"#, "$1"),
        (#"[，,]{2,}"#, "，"),
        (#"^[，,、\s]+"#, ""),
        (#"\s{2,}"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func clean(_ text: String) -> String {
        var s = text
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
