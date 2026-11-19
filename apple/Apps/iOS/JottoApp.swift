import BackgroundTasks
import SwiftUI

@main
struct JottoApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything writes to Documents: tells a first launch apart.
        Onboarding.settle()
        // Start receiving from the watch and resume pending uploads at launch.
        MainActor.assumeIsolated { PhoneLog.shared.note("launch") }
        _ = Inbox.shared
        _ = Library.shared
        MainActor.assumeIsolated {
            AudioFiles.removeServerLeftovers()
            Notifier.shared.start()
            // Reconnects to a model download that went on while closed.
            _ = SpeechPack.shared
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
            if phase == .background {
                Pipeline.shared.scheduleCatchUp()
                Pipeline.shared.letGoOfModelIfIdle()
            }
            if phase == .active {
                Pipeline.shared.cameToFront()
                // Parts still to hear carry on if jotto is put away.
                Pipeline.shared.finishInBackgroundIfNeeded()
                LiveActivities.shared.sync()
                Task { await Notifier.shared.askIfNeeded() }
                Task { await Library.shared.refresh() }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch ends, as iOS requires: the turn it gives jotto in
        // the background to finish what a wake from the watch didn't.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Pipeline.catchUpID, using: .main) { task in
            guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            MainActor.assumeIsolated { Pipeline.shared.catchUp(task) }
        }
        return true
    }

    /// The speech model's download finished while jotto wasn't running.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { SpeechPack.shared.backgroundCompletion = completionHandler }
    }
}
