import AppIntents
import SwiftUI
import WidgetKit

/// The watch-face complication, and controls for Control Center and the
/// Apple Watch Ultra's Action Button.
@main
struct JottoWidgets: WidgetBundle {
    var body: some Widget {
        JottoComplication()
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
                Label("Mark", systemImage: "star")
            }
        }
        .displayName("Mark Without Opening")
        .description("Marks a highlight in the recording under way, without opening jotto.")
    }
}
