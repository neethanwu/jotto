import AppIntents

/// Puts the actions in the Shortcuts app, so the Action Button can run them
/// through a shortcut as well as through a control.
struct JottoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordOrMarkIntent(),
            phrases: ["Record with \(.applicationName)", "Mark in \(.applicationName)"],
            shortTitle: "Record or Mark",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: MarkInBackgroundIntent(),
            phrases: ["Mark without opening \(.applicationName)"],
            shortTitle: "Mark Without Opening",
            systemImageName: "star"
        )
    }
}
