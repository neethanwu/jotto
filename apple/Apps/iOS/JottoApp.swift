import SwiftUI

@main
struct JottoApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Start receiving from the watch and resume pending uploads at launch.
        MainActor.assumeIsolated { PhoneLog.shared.note("launch") }
        _ = Inbox.shared
        _ = Library.shared
        MainActor.assumeIsolated {
            AudioFiles.removeServerLeftovers()
            Notifier.shared.start()
        }
        #if DEBUG
        MainActor.assumeIsolated { Pipeline.shared.simulateRecordingIfRequested() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            PhoneLog.shared.note("scene", "\(phase)")
            // Coming to the foreground is a good moment to skip any backoff.
            if phase == .active {
                Pipeline.shared.run()
                LiveActivities.shared.sync()
                Task { await Notifier.shared.askIfNeeded() }
                Task { await Library.shared.refresh() }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {}
