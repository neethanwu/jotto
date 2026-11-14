import Foundation

/// What the watch-face complications show, shared between the watch app
/// (which writes it) and the widget extension (which reads it) through
/// the app group. Without the group the complications still open jotto;
/// they just can't say it's recording.
enum WatchFace {
    static let group = "group.com.neethanwu.jotto"
    static let kind = "com.neethanwu.jotto.face"

    struct State {
        /// Set while a recording is going.
        var recordingSince: Date?
        var todayCount = 0
        var todaySeconds: Double = 0
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func load() -> State {
        guard let d = defaults else { return State() }
        let since = d.object(forKey: "recordingSince") as? Double
        // Today's numbers are from the day they were written.
        let day = d.object(forKey: "todayDay") as? Double
        let isToday = day.map { Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0)) } ?? false
        return State(
            recordingSince: since.map(Date.init(timeIntervalSince1970:)),
            todayCount: isToday ? d.integer(forKey: "todayCount") : 0,
            todaySeconds: isToday ? d.double(forKey: "todaySeconds") : 0
        )
    }

    static func save(_ state: State) {
        guard let d = defaults else { return }
        if let since = state.recordingSince {
            d.set(since.timeIntervalSince1970, forKey: "recordingSince")
        } else {
            d.removeObject(forKey: "recordingSince")
        }
        d.set(state.todayCount, forKey: "todayCount")
        d.set(state.todaySeconds, forKey: "todaySeconds")
        d.set(Date.now.timeIntervalSince1970, forKey: "todayDay")
    }

    /// "4 today · 3 h 18", or "Nothing yet today".
    static func todayLine(_ s: State) -> String {
        guard s.todayCount > 0 else { return "Nothing yet today" }
        let minutes = Int(s.todaySeconds / 60)
        let length = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
        return "\(s.todayCount) today · \(length)"
    }
}
