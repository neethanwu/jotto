import SwiftUI

@main
struct JottoWatchApp: App {
    @State private var recorder = Recorder()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = WatchTransfer.shared
    }

    var body: some Scene {
        WindowGroup {
            RecorderView(recorder: recorder, transfer: WatchTransfer.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            recorder.lifecycle("\(phase)")
        }
    }
}
