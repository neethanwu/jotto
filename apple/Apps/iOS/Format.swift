import Foundation

/// How times and lengths read across the app: "46 min", "1 h 12 min",
/// clock times in 24 h, offsets as "0:23" or "1:02:03".
enum Format {
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 1 { return "\(max(0, Int(seconds))) s" }
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Running clock for timers: "4:07", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Wall-clock time of day, "10:00".
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// "31 Oct"
    static func dayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "Thu 31 Oct"
    static func weekdayDayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }

    /// A title for a recording Jotto hasn't named yet.
    static func provisionalTitle(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Morning recording"
        case 12..<17: "Afternoon recording"
        case 17..<22: "Evening recording"
        default: "Night recording"
        }
    }

    static func speaker(_ label: String?) -> String {
        guard let label, let n = Int(label) else { return "Speaker" }
        return "Speaker \(n + 1)"
    }
}
