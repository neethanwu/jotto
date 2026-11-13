import AppIntents
import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// Jotto in the Shortcuts app. Recording: start, stop and mark, each
// handing on the recording. Transcripts: finished ones not yet sent on,
// one recording's, the latest, or a whole day's, laid out by a send
// template, as a Transcript that works as text (Mail, ChatGPT, Notes) and
// as a named .md or .txt file (Save File into iCloud Drive or an Obsidian
// vault), with its title for a subject line. Recordings are entities, so
// Shortcuts also offers "Find Recording" (by day, title, ready) and "Open
// Recording". With a "when Jotto sends a notification" automation and
// Get Finished Transcripts, every recording goes somewhere by itself about
// a minute after it ends.
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

/// A transcript laid out by a send template. Passed to an action that
/// takes text it is the text; to one that takes a file (Save File) it is
/// a file named by its date and title; its title can be picked out for a
/// subject line.
struct TranscriptEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Transcript", numericFormat: "\(placeholder: .int) transcripts"
    )

    @Property(title: "Title") var title: String
    @Property(title: "Text") var text: String
    @Property(title: "Date") var date: Date
    /// "2026-11-13 0830 Coffee with Priya.md"
    @Property(title: "File Name") var fileName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(date.formatted(date: .abbreviated, time: .shortened))")
    }

    init() {
        title = ""
        text = ""
        date = .now
        fileName = ""
    }

    init(title: String, text: String, date: Date, markdown: Bool) {
        self.init()
        self.title = title
        self.text = text
        self.date = date
        // Characters file systems and sync services trip on, out.
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let stamp = date.formatted(.iso8601.year().month().day()) + " " + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .replacingOccurrences(of: ":", with: "")
        self.fileName = "\(stamp) \(safe.prefix(80)).\(markdown ? "md" : "txt")"
    }

    @MainActor
    init(_ detail: SessionDetail, title: String, template: SendTemplate) {
        self.init(title: title, text: Composer.compose(detail, title: title, with: template),
                  date: detail.startedAt, markdown: template.format == .markdown)
    }
}

extension TranscriptEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        // A file first, named so it lands well in a folder; text from it
        // is the same words, for actions that want text.
        FileRepresentation(exportedContentType: .plainText) { transcript in
            let folder = URL.temporaryDirectory.appending(path: "Transcripts/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: transcript.fileName.isEmpty ? "Transcript.txt" : transcript.fileName)
            try Data(transcript.text.utf8).write(to: url)
            return SentTransferredFile(url)
        }
        ProxyRepresentation(exporting: \.text)
    }
}

/// Which recordings have been sent where, so Get Finished Transcripts
/// gives each one once per destination, and catches up on any an
/// automation missed.
@MainActor
enum HandedOn {
    private static func key(_ destination: String) -> String {
        "handedOn." + destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Ready, and with its title written (or long enough ago that it
    /// won't be): what the "ready" notice is sent for.
    private static func deliverable(_ r: LocalRecording) -> Bool {
        guard r.status == "ready" else { return false }
        return r.describedAt != nil || r.notifiedAt != nil || (r.polishedAt ?? .now) < Date.now.addingTimeInterval(-600)
    }

    /// The ones not yet handed on to `destination`, oldest first, marked
    /// as handed on. The first time a destination is used, only the
    /// newest counts as new, not everything ever recorded.
    static func take(for destination: String, limit: Int = 10) -> [LocalRecording] {
        let defaults = UserDefaults.standard
        let all = LocalStore.shared.recordings
        let ready = all.values.filter(deliverable).sorted { $0.startedAt < $1.startedAt }
        var seen = defaults.stringArray(forKey: key(destination)).map(Set.init) ?? Set(ready.dropLast().map(\.id))
        let fresh = Array(ready.filter { !seen.contains($0.id) }.prefix(limit))
        seen.formUnion(fresh.map(\.id))
        defaults.set(Array(seen.filter { all[$0] != nil }), forKey: key(destination))
        return fresh
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

/// The transcripts of finished recordings not yet sent to a destination:
/// the one action an automation needs. (The type keeps its first name so
/// shortcuts made with it go on working.)
struct GetNewTranscriptsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Finished Transcripts"
    static let description = IntentDescription(
        "Transcripts of recordings that are completely done (every part heard, formatted and titled) and haven't been sent to this destination yet, oldest first, laid out by a send template. Use it in an automation for when Jotto sends a notification: each recording goes out once, and any that a missed run left behind go with the next. Give each automation its own destination, like Email or Obsidian.",
        categoryName: "Transcripts",
        searchKeywords: ["automation", "new", "ready", "export", "sync", "save", "send"]
    )

    @Parameter(title: "Template", description: "Leave empty for the one you used last.")
    var template: TemplateEntity?

    @Parameter(title: "Destination", description: "A name for where they go, like Email or Obsidian. Each name keeps its own track of what it has had.", default: "Shortcuts")
    var destination: String

    static var parameterSummary: some ParameterSummary {
        Summary("Get finished transcripts not yet sent to \(\.$destination) with \(\.$template)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TranscriptEntity]> {
        let using = template?.template ?? SendTemplates.shared.preferred
        let items = HandedOn.take(for: destination).compactMap { r -> TranscriptEntity? in
            guard let detail = try? LocalStore.shared.session(r.id) else { return nil }
            let item = titled(detail)
            return TranscriptEntity(item.detail, title: item.title, template: using)
        }
        PhoneLog.shared.note("shortcut_new", "\(items.count) for \(destination)")
        return .result(value: items)
    }
}

/// One recording's transcript.
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
    func perform() async throws -> some IntentResult & ReturnsValue<TranscriptEntity> {
        guard let r = LocalStore.shared.recordings[recording.id] else { throw IntentFailure.gone }
        guard r.status == "ready" else { throw IntentFailure.notReady }
        let item = titled(try LocalStore.shared.session(r.id))
        let using = template?.template ?? SendTemplates.shared.preferred
        return .result(value: TranscriptEntity(item.detail, title: item.title, template: using))
    }
}

/// The newest finished recording, as text.
struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Transcript"
    static let description = IntentDescription(
        "The newest finished recording's transcript, laid out by a send template. For an automation, Get Finished Transcripts is surer: it sends each recording once.",
        categoryName: "Transcripts",
        searchKeywords: ["text", "export", "newest", "last"]
    )

    @Parameter(title: "Template", description: "Leave empty for the one you used last.")
    var template: TemplateEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the latest transcript with \(\.$template)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TranscriptEntity> {
        guard let latest = LocalStore.shared.recordings.values
            .filter({ $0.status == "ready" })
            .max(by: { $0.startedAt < $1.startedAt }) else { throw IntentFailure.nothingYet }
        let item = titled(try LocalStore.shared.session(latest.id))
        let using = template?.template ?? SendTemplates.shared.preferred
        return .result(value: TranscriptEntity(item.detail, title: item.title, template: using))
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
    func perform() async throws -> some IntentResult & ReturnsValue<TranscriptEntity> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day ?? .now)
        let items = LocalStore.shared.recordings.values
            .filter { $0.status == "ready" && calendar.isDate($0.startedAt, inSameDayAs: start) }
            .compactMap { try? LocalStore.shared.session($0.id) }
            .filter { !$0.blocks.isEmpty }
            .map(titled)
        guard !items.isEmpty else { throw IntentFailure.nothingThatDay }
        let using = template?.template ?? SendTemplates.shared.preferred
        return .result(value: TranscriptEntity(
            title: start.formatted(.dateTime.weekday(.wide).day().month(.wide)),
            text: Composer.composeDay(items, day: start, with: using),
            date: start, markdown: using.format == .markdown
        ))
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
