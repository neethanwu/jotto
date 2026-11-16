import Observation
import UIKit
import UserNotifications

/// "Your recording is ready": its title and what it was about, once the
/// phone has finished with it. A banner even with jotto open, since you
/// may be on another tab; tapping one opens the transcript.
@MainActor @Observable
final class Notifier: NSObject {
    static let shared = Notifier()

    /// A notice was tapped: Days opens this transcript, then clears it.
    var opening: String?

    /// Older recordings that get done again (after a repair, say) stay quiet.
    private static let freshFor: TimeInterval = 12 * 3600

    private var center: UNUserNotificationCenter { .current() }

    /// Set as the delegate at launch, so a tap that launched the app is seen.
    func start() {
        center.delegate = self
    }

    /// Asks once, the first time the app is in front: recordings arrive
    /// while it's in the background, too late to ask then.
    /// From the Settings switch, a "no" given earlier sends you to iOS
    /// Settings, the only place it can be changed.
    func askIfNeeded(fromSwitch: Bool = false) async {
        guard AppConfig.shared.notifiesWhenReady else { return }
        let settings = await center.notificationSettings()
        if fromSwitch, settings.authorizationStatus == .denied,
           let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            await UIApplication.shared.open(url)
            return
        }
        guard settings.authorizationStatus == .notDetermined else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        PhoneLog.shared.note("notify_permission", granted ? "granted" : "denied")
    }

    /// Posts the notice for a finished recording, once.
    func ready(_ id: String) {
        let store = LocalStore.shared
        guard AppConfig.shared.notifiesWhenReady, let r = store.recordings[id],
              r.notifiedAt == nil, r.imported == nil, let ended = r.endedAt else { return }
        store.update(id, startedAt: r.startedAt) { $0.notifiedAt = .now }
        guard Date.now.timeIntervalSince(ended) < Self.freshFor else { return }

        let content = UNMutableNotificationContent()
        content.title = r.title ?? "Recording ready"
        content.subtitle = "\(Format.time(r.startedAt)) · \(Format.length(ended.timeIntervalSince(r.startedAt)))"
        content.body = Self.overview(r)
        content.sound = .default
        post(content, id: id)
        PhoneLog.shared.note("notified", "\(id) titled=\(r.title != nil)")
    }

    /// Time out of sight ran out with parts still to hear: says the
    /// recording is safe and that opening jotto finishes it, once. The
    /// "ready" notice takes its place when it comes, so there's never two.
    func askToOpen(_ id: String) {
        let store = LocalStore.shared
        guard AppConfig.shared.notifiesWhenReady, let r = store.recordings[id], r.notifiedAt == nil,
              r.askedToOpenAt == nil, r.imported == nil, let ended = r.endedAt,
              Date.now.timeIntervalSince(ended) < Self.freshFor else { return }
        store.update(id, startedAt: r.startedAt) { $0.askedToOpenAt = .now }

        let content = UNMutableNotificationContent()
        content.title = "Recording saved"
        content.subtitle = "\(Format.time(r.startedAt)) · \(Format.length(ended.timeIntervalSince(r.startedAt)))"
        content.body = "Open jotto to transcribe it. It keeps going if you lock your iPhone."
        content.sound = .default
        post(content, id: id)
        PhoneLog.shared.note("asked_to_open", id)
    }

    /// One notice per recording: a later one replaces an earlier one.
    private func post(_ content: UNMutableNotificationContent, id: String) {
        content.threadIdentifier = "ready"
        content.userInfo = ["session": id]
        let request = UNNotificationRequest(identifier: "ready-\(id)", content: content, trigger: nil)
        center.add(request) { error in
            if let error { PhoneLog.shared.later("notify_failed", error.localizedDescription) }
        }
    }

    /// The summary when there is one, else how the recording begins.
    private static func overview(_ r: LocalRecording) -> String {
        if let summary = r.summary, !summary.isEmpty { return summary }
        let said = LocalStore.transcript(r).filter { $0.backchannel != true }.map { $0.clean ?? $0.text }
        let text = said.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Nothing clear enough to write down. Check the language in Settings." }
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run { Notifier.shared.opening = id }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
