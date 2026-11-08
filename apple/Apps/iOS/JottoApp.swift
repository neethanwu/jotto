import SwiftUI

@main
struct JottoApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Start receiving from the watch and resume pending uploads at launch.
        MainActor.assumeIsolated { PhoneLog.shared.note("launch") }
        _ = Inbox.shared
        _ = Uploader.shared
        _ = Library.shared
        #if DEBUG
        Uploader.shared.enqueueDemoRecordingIfRequested()
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
                Uploader.shared.retryAll()
                Task { await Library.shared.refresh() }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS relaunches the app when background uploads finish; hand the
    /// completion handler to the uploader so it can call it when done.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            PhoneLog.shared.note("bg_url_events")
            Uploader.shared.backgroundCompletion = completionHandler
        }
    }
}
