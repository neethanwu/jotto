import SwiftUI

@main
struct JottoApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Start receiving from the watch and resume pending uploads at launch.
        _ = Inbox.shared
        _ = Uploader.shared
        #if DEBUG
        Uploader.shared.enqueueDemoRecordingIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Transcripts", systemImage: "text.quote") {
                    SessionsView(config: .shared, uploader: .shared)
                }
                Tab("Debug", systemImage: "ladybug") {
                    InboxView(inbox: .shared)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming to the foreground is a good moment to skip any backoff.
            if phase == .active { Uploader.shared.retryAll() }
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
            Uploader.shared.backgroundCompletion = completionHandler
        }
    }
}
