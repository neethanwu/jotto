import AppIntents
import Foundation

// Jotto in the Shortcuts app: start and stop a recording, and get
// transcripts as text through a send template, to hand to whatever comes
// next in a shortcut (a notes app, an agent, a web request). With the
// "When I get a notification from Jotto" automation, a recording can go
// somewhere by itself a minute after it ends.

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

enum IntentFailure: LocalizedError {
    case nothingYet, nothingThatDay, notRecording
    var errorDescription: String? {
        switch self {
        case .nothingYet: "There are no finished recordings yet."
        case .nothingThatDay: "Nothing was recorded that day."
        case .notRecording: "Nothing is recording."
        }
    }
}

@MainActor
private func titled(_ detail: SessionDetail) -> (detail: SessionDetail, title: String) {
    (detail, detail.title ?? Format.provisionalTitle(detail.startedAt))
}

/// The newest finished recording, as text.
struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Transcript"
    static let description = IntentDescription("The newest finished recording as text, laid out by a send template.")

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
    static let description = IntentDescription("Every finished recording from a day, in order, laid out by a send template.")

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
    static let description = IntentDescription("Starts a Jotto recording, on your watch if Jotto is open there, otherwise on this iPhone.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = try await RecordStarter.start()
        return .result(dialog: started.on == .watch ? "Recording on your watch." : "Recording on your iPhone.")
    }
}

/// Stops the recording going on this iPhone, or asks the watch to stop.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"

    @MainActor
    func perform() async throws -> some IntentResult {
        if PhoneRecorder.shared.isRecording {
            PhoneRecorder.shared.stop()
        } else if let live = LocalStore.shared.recordings.values.first(where: { $0.endedAt == nil && $0.imported == nil }) {
            Inbox.shared.askWatchToStop(live.id)
        } else {
            throw IntentFailure.notRecording
        }
        return .result()
    }
}

/// Marks this moment in the recording going on.
struct MarkNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark This Moment"

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let live = LocalStore.shared.recordings.values
            .filter({ $0.endedAt == nil && $0.imported == nil })
            .max(by: { $0.startedAt < $1.startedAt }) else { throw IntentFailure.notRecording }
        Pipeline.shared.markNow(live.id, startedAt: live.startedAt)
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
