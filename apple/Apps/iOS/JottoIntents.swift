import AppIntents
import Foundation

// Jotto in the Shortcuts app. Recording: start, stop and mark, each
// handing on the recording. Transcripts: one recording's, the latest, or
// a whole day's, as text through a send template, for whatever comes
// next in a shortcut (a notes app, an agent, a web request). Recordings
// are entities, so Shortcuts also offers "Find Recordings" (by day,
// title, ready) and "Open Recording". With a "when Jotto posts a
// notification" automation, a recording can go somewhere by itself a
// minute after it ends.
//
// Titles, descriptions and phrases here must not name Apple products
// (App Store rule ITMS-90626): "phone" and "watch", never the brands.

/// A send template, picked in Shortcuts.
struct TemplateEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Send Template"
    static let defaultQuery = TemplateQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    @MainActor
    var template: SendTemplate? { SendTemplates.shared.all.first { $0.id == id } }
}

struct TemplateQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TemplateEntity] {
        SendTemplates.shared.all.filter { identifiers.contains($0.id) }.map { TemplateEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TemplateEntity] {
        SendTemplates.shared.all.map { TemplateEntity(id: $0.id, name: $0.name) }
    }
}

/// A recording, in Shortcuts: what Start and Stop hand on, what Get
/// Transcript and Open Recording take, and what "Find Recordings" (which
/// Shortcuts makes from the query below) filters by day, title or
/// whether it's ready.
struct RecordingEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Recording", numericFormat: "\(placeholder: .int) recordings"
    )
    static let defaultQuery = RecordingQuery()

    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Date") var date: Date
    @Property(title: "Length") var length: Measurement<UnitDuration>
    /// Transcribed and tidied, so its transcript can be had.
    @Property(title: "Is Ready") var isReady: Bool
    @Property(title: "Summary") var summary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(date.formatted(date: .abbreviated, time: .shortened)) · \(Format.length(length.converted(to: .seconds).value))"
        )
    }

    init(id: String, title: String, date: Date, seconds: Double, isReady: Bool, summary: String) {
        self.id = id
        self.title = title
        self.date = date
        self.length = Measurement(value: seconds, unit: .seconds)
        self.isReady = isReady
        self.summary = summary
    }

    @MainActor
    init(_ r: LocalRecording) {
        self.init(
            id: r.id,
            title: r.title ?? Format.provisionalTitle(r.startedAt),
            date: r.startedAt,
            seconds: (r.endedAt ?? .now).timeIntervalSince(r.startedAt),
            isReady: r.status == "ready",
            summary: r.summary ?? ""
        )
    }

    /// One that has only just started, before the phone has a record of it.
    @MainActor
    static func started(_ id: String) -> RecordingEntity {
        LocalStore.shared.recordings[id].map(RecordingEntity.init)
            ?? RecordingEntity(id: id, title: Format.provisionalTitle(.now), date: .now, seconds: 0, isReady: false, summary: "")
    }
}

struct RecordingQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [RecordingEntity] {
        identifiers.compactMap { LocalStore.shared.recordings[$0] }.map(RecordingEntity.init)
    }

    /// Newest first.
    @MainActor
    func allEntities() async throws -> [RecordingEntity] {
        LocalStore.shared.recordings.values
            .sorted { $0.startedAt > $1.startedAt }
            .map(RecordingEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [RecordingEntity] {
        Array(try await allEntities().prefix(12))
    }

    @MainActor
    func entities(matching string: String) async throws -> [RecordingEntity] {
        try await allEntities().filter {
            $0.title.localizedCaseInsensitiveContains(string) || $0.summary.localizedCaseInsensitiveContains(string)
        }
    }
}

enum IntentFailure: LocalizedError {
    case nothingYet, nothingThatDay, notRecording, notReady, gone
    var errorDescription: String? {
        switch self {
        case .nothingYet: "There are no finished recordings yet."
        case .nothingThatDay: "Nothing was recorded that day."
        case .notRecording: "Nothing is recording."
        case .notReady: "That recording is still being transcribed. Its transcript is usually ready about a minute after it ends."
        case .gone: "That recording isn't in Jotto any more."
        }
    }
}

@MainActor
private func titled(_ detail: SessionDetail) -> (detail: SessionDetail, title: String) {
    (detail, detail.title ?? Format.provisionalTitle(detail.startedAt))
}

/// One recording's transcript, as text.
struct GetTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Transcript"
    static let description = IntentDescription(
        "A recording's transcript as text, laid out by a send template. Use it with Find Recordings, or with the recording Stop Recording gives.",
        categoryName: "Transcripts",
        searchKeywords: ["text", "export", "notes"]
    )

    @Parameter(title: "Recording")
    var recording: RecordingEntity

    @Parameter(title: "Template", description: "Leave empty for the one you used last.")
    var template: TemplateEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the transcript of \(\.$recording) with \(\.$template)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let r = LocalStore.shared.recordings[recording.id] else { throw IntentFailure.gone }
        guard r.status == "ready" else { throw IntentFailure.notReady }
        let item = titled(try LocalStore.shared.session(r.id))
        let using = template?.template ?? SendTemplates.shared.preferred
        return .result(value: Composer.compose(item.detail, title: item.title, with: using))
    }
}

/// The newest finished recording, as text.
struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Transcript"
    static let description = IntentDescription(
        "The newest finished recording's transcript as text, laid out by a send template. Made for the automation that runs when Jotto's \"ready\" notice comes in.",
        categoryName: "Transcripts",
        searchKeywords: ["text", "export", "newest", "last"]
    )

    @Parameter(title: "Template", description: "Leave empty for the one you used last.")
    var template: TemplateEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the latest transcript with \(\.$template)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let latest = LocalStore.shared.recordings.values
            .filter({ $0.status == "ready" })
            .max(by: { $0.startedAt < $1.startedAt }) else { throw IntentFailure.nothingYet }
        let item = titled(try LocalStore.shared.session(latest.id))
        let using = template?.template ?? SendTemplates.shared.preferred
        return .result(value: Composer.compose(item.detail, title: item.title, with: using))
    }
}

/// Every finished recording from one day, in order, as one text.
struct GetDayTranscriptsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get a Day's Transcripts"
    static let description = IntentDescription(
        "Every finished recording from a day, in order, as one text laid out by a send template. Leave the day empty for today.",
        categoryName: "Transcripts",
        searchKeywords: ["text", "export", "today", "daily"]
    )

    @Parameter(title: "Day", kind: .date)
    var day: Date?

    @Parameter(title: "Template", description: "Leave empty for the one you used last.")
    var template: TemplateEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get transcripts from \(\.$day) with \(\.$template)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day ?? .now)
        let items = LocalStore.shared.recordings.values
            .filter { $0.status == "ready" && calendar.isDate($0.startedAt, inSameDayAs: start) }
            .compactMap { try? LocalStore.shared.session($0.id) }
            .filter { !$0.blocks.isEmpty }
            .map(titled)
        guard !items.isEmpty else { throw IntentFailure.nothingThatDay }
        let using = template?.template ?? SendTemplates.shared.preferred
        return .result(value: Composer.composeDay(items, day: start, with: using))
    }
}

/// Starts recording: on the watch if its app is open and in reach, else
/// on this iPhone (which can start the microphone from a shortcut because
/// the recording shows as a Live Activity).
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription(
        "Starts a Jotto recording: on your watch if Jotto is open there, otherwise on this phone. Gives the recording, so a later step can open it or get its transcript.",
        categoryName: "Recording",
        searchKeywords: ["record", "begin", "microphone"]
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<RecordingEntity> & ProvidesDialog {
        let started = try await RecordStarter.start()
        return .result(
            value: RecordingEntity.started(started.id),
            dialog: started.on == .watch ? "Recording on your watch." : "Recording on this phone."
        )
    }
}

/// Stops the recording going on this iPhone, or asks the watch to stop.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription(
        "Stops the Jotto recording going on, on this phone or on your watch, and gives that recording. Its transcript is usually ready about a minute later: Jotto posts a notice then, which an automation can pick up.",
        categoryName: "Recording",
        searchKeywords: ["end", "finish", "record"]
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<RecordingEntity> & ProvidesDialog {
        let id: String
        if PhoneRecorder.shared.isRecording, let phone = PhoneRecorder.shared.sessionID {
            id = phone
            PhoneRecorder.shared.stop()
        } else if let live = LocalStore.shared.recordings.values
            .filter({ $0.endedAt == nil && $0.imported == nil })
            .max(by: { $0.startedAt < $1.startedAt }) {
            id = live.id
            Inbox.shared.askWatchToStop(live.id)
        } else {
            throw IntentFailure.notRecording
        }
        return .result(value: RecordingEntity.started(id), dialog: "Stopped. The transcript follows in about a minute.")
    }
}

/// Marks this moment in the recording going on.
struct MarkNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark This Moment"
    static let description = IntentDescription(
        "Puts a star on what's being said now in the recording going on, the same as tapping the star. The highlight reaches back and forward as set in Jotto's settings.",
        categoryName: "Recording",
        searchKeywords: ["star", "highlight", "bookmark"]
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let live = LocalStore.shared.recordings.values
            .filter({ $0.endedAt == nil && $0.imported == nil })
            .max(by: { $0.startedAt < $1.startedAt }) else { throw IntentFailure.notRecording }
        Pipeline.shared.markNow(live.id, startedAt: live.startedAt)
        return .result(dialog: "Marked at \(Format.clock(Date.now.timeIntervalSince(live.startedAt))).")
    }
}

/// Opens a recording's transcript in Jotto.
struct OpenRecordingIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Recording"
    static let description = IntentDescription(
        "Opens a recording's transcript in Jotto.",
        categoryName: "Transcripts",
        searchKeywords: ["show", "view"]
    )

    @Parameter(title: "Recording")
    var target: RecordingEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard LocalStore.shared.recordings[target.id] != nil else { throw IntentFailure.gone }
        // The same way in as tapping a "ready" notice.
        Notifier.shared.opening = target.id
        return .result()
    }
}

struct JottoPhoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Record with \(.applicationName)", "Start a \(.applicationName) recording"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop \(.applicationName) recording"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: MarkNowIntent(),
            phrases: ["Mark in \(.applicationName)"],
            shortTitle: "Mark This Moment",
            systemImageName: "star"
        )
        AppShortcut(
            intent: GetLatestTranscriptIntent(),
            phrases: ["Get my latest \(.applicationName) transcript"],
            shortTitle: "Latest Transcript",
            systemImageName: "text.alignleft"
        )
        AppShortcut(
            intent: GetDayTranscriptsIntent(),
            phrases: ["Get today's \(.applicationName) transcripts"],
            shortTitle: "Day's Transcripts",
            systemImageName: "calendar"
        )
    }
}
