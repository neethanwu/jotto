import ActivityKit
import Foundation
import UIKit

/// Keeps the lock-screen and Dynamic Island activity in step with the
/// recording. iOS lets an app start one only while it is in front, so it
/// starts when jotto is open as a recording begins, or the first time
/// jotto is opened during one; after that it stays until the watch stops.
@MainActor
final class LiveActivities {
    static let shared = LiveActivities()

    private var current: Activity<RecordingActivity>? {
        Activity<RecordingActivity>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Start one for the recording going on now, if there is one and
    /// none is showing. Safe to call often.
    func sync() {
        let live = LocalStore.shared.recordings.values.filter { $0.endedAt == nil && $0.imported == nil }
            .max { $0.startedAt < $1.startedAt }
        #if DEBUG
        PhoneLog.shared.note("live_activity_sync", "enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled) live=\(live?.id ?? "-") showing=\(current?.attributes.sessionID ?? "-")")
        #endif
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Activities for recordings that have ended (or were deleted) go.
        let keep = live?.id
        Task { await Self.end { $0 != keep } }
        guard let live else { return }
        if current?.attributes.sessionID == live.id {
            update(live.id)
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        do {
            _ = try Activity.request(
                attributes: RecordingActivity(sessionID: live.id, startedAt: live.startedAt),
                content: .init(state: state(for: live.id), staleDate: nil)
            )
            PhoneLog.shared.note("live_activity_started", live.id)
        } catch {
            PhoneLog.shared.note("live_activity_failed", error.localizedDescription)
        }
    }

    /// Marks, sections or the latest line changed.
    func update(_ id: String) {
        guard let activity = current, activity.attributes.sessionID == id else { return }
        let state = state(for: id)
        guard state != activity.content.state else { return }
        Task { await Self.push(id, state) }
    }

    func end(_ id: String) {
        Task { await Self.end { $0 == id } }
    }

    // Activities aren't Sendable: each async step looks them up itself.
    nonisolated private static func end(where match: @Sendable (String) -> Bool) async {
        for activity in Activity<RecordingActivity>.activities where match(activity.attributes.sessionID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func push(_ id: String, _ state: RecordingActivity.ContentState) async {
        for activity in Activity<RecordingActivity>.activities where activity.attributes.sessionID == id {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    private func state(for id: String) -> RecordingActivity.ContentState {
        guard let r = LocalStore.shared.recordings[id] else { return .init() }
        let last = LocalStore.transcript(r).last { $0.backchannel != true }
        return .init(
            moments: r.marks.count,
            sections: r.sections?.count ?? 0,
            sectionOpen: Pipeline.shared.openSections[id] != nil,
            lastLine: last.map { String(($0.clean ?? $0.text).suffix(60)) }
        )
    }
}
