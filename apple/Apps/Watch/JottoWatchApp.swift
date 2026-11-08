import SwiftUI

@main
struct JottoWatchApp: App {
    private let recorder = Recorder.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = WatchTransfer.shared
    }

    var body: some Scene {
        WindowGroup {
            RecorderView(recorder: recorder, transfer: WatchTransfer.shared)
                #if DEBUG
                // Simulator screenshots: `SIMCTL_CHILD_JOTTO_AUTOSTART=1 xcrun simctl launch …`
                .task {
                    if ProcessInfo.processInfo.environment["JOTTO_AUTOSTART"] != nil { recorder.start() }
                }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            recorder.lifecycle("\(phase)")
            if phase == .active { recorder.resumeIfInterrupted() }
        }
    }
}
