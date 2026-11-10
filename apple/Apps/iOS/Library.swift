import Foundation
import Observation

/// What the phone has heard from the watch about each recording, before
/// (or without) the server knowing: started, which segments arrived, ended.
/// Lets the timeline show a live recording the moment it starts, and a
/// finished one whose audio is still on the watch.
struct LocalSession: Codable, Hashable {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    var segmentCount: Int?
    var received: Set<Int> = []
}

/// One row of the Days timeline.
struct TimelineEntry: Identifiable, Hashable {
    enum State: Hashable {
        case live
        case processing(done: Int, total: Int?, polishing: Bool)
        case onWatch(parts: Int)
        case done
    }

    let id: String
    let startedAt: Date
    let endedAt: Date?
    let state: State
    let title: String
    let summary: String?
    let lastLine: String?
    let missing: Int

    var length: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

@MainActor @Observable
final class Library {
    static let shared = Library()

    private(set) var server: [SessionSummary] = []
    private(set) var local: [String: LocalSession] = [:]
    private(set) var loadError: String?
    private(set) var loadedOnce = false

    /// A recording with no word from the watch for this long is no longer
    /// shown as live (the watch app was killed, or ran out of battery).
    private static let liveTimeout: TimeInterval = 12 * 3600
    private static let localFile = URL.documentsDirectory.appending(path: "local-sessions.json")

    private init() {
        if let data = try? Data(contentsOf: Self.localFile),
           let saved = try? JSONDecoder().decode([String: LocalSession].self, from: data) {
            local = saved
        }
    }

    // MARK: - From the watch

    func watchStarted(_ id: String, at date: Date) {
        if local[id] == nil { local[id] = LocalSession(id: id, startedAt: date) }
        saveLocal()
    }

    func watchSent(_ id: String, startedAt: Date, index: Int) {
        local[id, default: LocalSession(id: id, startedAt: startedAt)].received.insert(index)
        saveLocal()
    }

    func watchFinished(_ id: String, startedAt: Date, endedAt: Date, segmentCount: Int) {
        local[id, default: LocalSession(id: id, startedAt: startedAt)].endedAt = endedAt
        local[id]?.segmentCount = segmentCount
        saveLocal()
    }

    private func saveLocal() {
        // Forget sessions the server has finished, and anything over a month old.
        let ready = Set(server.filter { $0.status == "ready" }.map(\.id))
        let cutoff = Date.now.addingTimeInterval(-30 * 86400)
        local = local.filter { !ready.contains($0.key) && $0.value.startedAt > cutoff }
        if let data = try? JSONEncoder().encode(local) {
            try? data.write(to: Self.localFile, options: .atomic)
        }
    }

    // MARK: - From the server

    func refresh() async {
        #if DEBUG
        // Simulator screenshots: `SIMCTL_CHILD_JOTTO_DEMO_DAYS=1 xcrun simctl launch …`
        if ProcessInfo.processInfo.environment["JOTTO_DEMO_DAYS"] != nil {
            server = Self.demo
            loadedOnce = true
            return
        }
        #endif
        guard AppConfig.shared.isReady || AppConfig.shared.processesLocally else { return }
        do {
            server = try await API.sessions()
            loadError = nil
            saveLocal()
        } catch {
            loadError = error.localizedDescription
        }
        loadedOnce = true
    }

    /// Something is still changing, so poll faster.
    var isBusy: Bool {
        entries.contains { $0.state != .done }
            || (!AppConfig.shared.processesLocally && !Uploader.shared.jobs.isEmpty)
    }

    func applyRename(_ id: String, title: String) {
        guard let i = server.firstIndex(where: { $0.id == id }) else { return }
        let s = server[i]
        server[i] = SessionSummary(
            id: s.id, startedAt: s.startedAt, endedAt: s.endedAt, status: s.status, title: title,
            summary: s.summary, segmentCount: s.segmentCount, missingSegments: s.missingSegments,
            segmentsDone: s.segmentsDone, segmentsReceived: s.segmentsReceived, lastLine: s.lastLine
        )
    }

    func remove(_ id: String) {
        server.removeAll { $0.id == id }
        local[id] = nil
        saveLocal()
    }

    // MARK: - Timeline

    var entries: [TimelineEntry] {
        var out: [String: TimelineEntry] = [:]
        for s in server {
            out[s.id] = makeEntry(server: s, local: local[s.id])
        }
        for (id, l) in local where out[id] == nil {
            out[id] = makeEntry(local: l)
        }
        return out.values.sorted { $0.startedAt > $1.startedAt }
    }

    func entries(on day: Date) -> [TimelineEntry] {
        let calendar = Calendar.current
        return entries.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
    }

    /// Days that have at least one recording, as start-of-day dates.
    var daysWithRecordings: Set<Date> {
        Set(entries.map { Calendar.current.startOfDay(for: $0.startedAt) })
    }

    var liveEntry: TimelineEntry? { entries.first { $0.state == .live } }

    /// When the first recording started, so the week strip can reach it.
    var earliest: Date? { entries.last?.startedAt }

    private func isLive(_ l: LocalSession) -> Bool {
        guard l.endedAt == nil else { return false }
        return Date.now.timeIntervalSince(l.startedAt) < Self.liveTimeout
    }

    private func makeEntry(server s: SessionSummary, local l: LocalSession?) -> TimelineEntry {
        let state: TimelineEntry.State
        if s.status == "ready" {
            state = .done
        } else if s.status == "recording",
                  l.map(isLive) ?? (Date.now.timeIntervalSince(s.startedAt) < Self.liveTimeout) {
            state = .live
        } else if let l, let count = l.segmentCount, l.received.count < count,
                  (s.segmentsReceived ?? 0) < count {
            state = .onWatch(parts: count - max(l.received.count, s.segmentsReceived ?? 0))
        } else {
            let total = s.segmentCount ?? l?.segmentCount
            let done = s.segmentsDone ?? 0
            state = .processing(done: done, total: total, polishing: total.map { done >= $0 } ?? false)
        }
        return TimelineEntry(
            id: s.id,
            startedAt: s.startedAt,
            endedAt: s.endedAt ?? l?.endedAt,
            state: state,
            title: s.title ?? Format.provisionalTitle(s.startedAt),
            summary: s.summary,
            lastLine: s.lastLine,
            missing: s.missingSegments ?? 0
        )
    }

    private func makeEntry(local l: LocalSession) -> TimelineEntry {
        let state: TimelineEntry.State
        if isLive(l) {
            state = .live
        } else if let count = l.segmentCount, l.received.count < count {
            state = .onWatch(parts: count - l.received.count)
        } else {
            state = .processing(done: 0, total: l.segmentCount, polishing: false)
        }
        return TimelineEntry(
            id: l.id, startedAt: l.startedAt, endedAt: l.endedAt, state: state,
            title: Format.provisionalTitle(l.startedAt), summary: nil, lastLine: nil, missing: 0
        )
    }
}

#if DEBUG
extension Library {
    /// A full day of finished recordings, plus a couple of earlier days.
    static let demo: [SessionSummary] = {
        let today = Calendar.current.startOfDay(for: .now)
        func at(_ dayOffset: Int, _ hour: Int, _ minutes: Int, _ title: String, _ summary: String) -> SessionSummary {
            let start = today.addingTimeInterval(TimeInterval(dayOffset * 86400 + hour * 3600))
            return SessionSummary(
                id: UUID().uuidString, startedAt: start, endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                status: "ready", title: title, summary: summary, segmentCount: minutes / 2, missingSegments: 0,
                segmentsDone: minutes / 2, segmentsReceived: minutes / 2, lastLine: nil
            )
        }
        func recording() -> SessionSummary {
            SessionSummary(
                id: UUID().uuidString, startedAt: .now.addingTimeInterval(-300), endedAt: nil,
                status: "recording", title: nil, summary: nil, segmentCount: nil, missingSegments: 0,
                segmentsDone: 0, segmentsReceived: 0, lastLine: nil
            )
        }
        return [
            at(0, 8, 46, "Coffee with Priya", "The pilot runs six weeks. We review after week two and decide then whether to open it up."),
            at(0, 10, 72, "Design review", "Design locks Friday. Engineering starts Monday, and the export screen moves out of the first build."),
            at(0, 12, 52, "Lunch with Alex", "Alex wants the watch to start recording from the Action Button, and asks about calls."),
            at(0, 14, 38, "Standup", "Three people out. The TestFlight build goes to twenty people on Friday."),
            at(0, 16, 64, "User interview · Mei", "Mei would join a pilot if it starts when she raises her wrist."),
            at(0, 18, 20, "Notes on the walk home", "Write the key guide before the product page."),
            at(-2, 9, 30, "Planning", "Order of work for the open-source release."),
            at(-9, 11, 45, "Kickoff", "Scope, risks and who owns what."),
        ] + (ProcessInfo.processInfo.environment["JOTTO_DEMO_DAYS"] == "live" ? [recording()] : [])
    }()
}
#endif

