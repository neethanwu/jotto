import AppIntents
import SwiftUI
import WidgetKit

/// Controls for Control Center and the Apple Watch Ultra's Action Button.
@main
struct JottoWidgets: WidgetBundle {
    var body: some Widget {
        RecordOrMarkControl()
        MarkInBackgroundControl()
    }
}

struct RecordOrMarkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.neethanwu.jotto.record-or-mark") {
            ControlWidgetButton(action: RecordOrMarkIntent()) {
                Label("Record or Mark", systemImage: "record.circle")
            }
        }
        .displayName("Record or Mark")
        .description("Starts recording, or marks a highlight while recording.")
    }
}

struct MarkInBackgroundControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.neethanwu.jotto.mark-background") {
            ControlWidgetButton(action: MarkInBackgroundIntent()) {
                Label("Mark", systemImage: "bookmark")
            }
        }
        .displayName("Mark Without Opening")
        .description("Test: marks a highlight without opening Jotto.")
    }
}
