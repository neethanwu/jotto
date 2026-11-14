import AppIntents

// Watch actions for controls, the Action Button and Shortcuts. Compiled into
// both the watch app and its widget extension; only the app can reach the
// recorder, so the extension's copy does nothing (JOTTO_WIDGETS).

/// Starts a recording, or marks a highlight if one is running. Opens jotto.
struct RecordOrMarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Record or Mark"
    static let description = IntentDescription("Starts recording, or marks a highlight if jotto is already recording.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !JOTTO_WIDGETS
        Recorder.shared.primaryAction(source: "record_or_mark")
        #endif
        return .result()
    }
}

/// Marks a highlight without opening jotto, while the recording carries on
/// in the background. Only marks: with nothing recording it does nothing,
/// since a recording shouldn't start out of sight.
struct MarkInBackgroundIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Without Opening"
    static let description = IntentDescription("Marks a highlight in the current recording without opening jotto.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !JOTTO_WIDGETS
        Recorder.shared.mark(source: "mark_background")
        #endif
        return .result()
    }
}
