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
                    let env = ProcessInfo.processInfo.environment
                    if env["JOTTO_AUTOSTART"] != nil {
                        // Started a few seconds in (`JOTTO_AUTOSTART_AFTER=5`), as a
                        // tap would be, once the link to the phone is up.
                        if let after = env["JOTTO_AUTOSTART_AFTER"].flatMap(Double.init) {
                            try? await Task.sleep(for: .seconds(after))
                        }
                        recorder.start()
                        // A recording already some minutes in (`JOTTO_AUTOSTART_AGO=255`),
                        // and the star just pressed (`JOTTO_AUTOMARK=1`).
                        if let ago = env["JOTTO_AUTOSTART_AGO"].flatMap(Double.init) { recorder.backdate(ago) }
                        if env["JOTTO_AUTOMARK"] != nil {
                            // Once the level bars have filled.
                            try? await Task.sleep(for: .seconds(3.5))
                            recorder.mark(source: "screenshot")
                        }
                    }
                }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            recorder.lifecycle("\(phase)")
            if phase == .active { recorder.resumeIfInterrupted() }
        }
    }
}
