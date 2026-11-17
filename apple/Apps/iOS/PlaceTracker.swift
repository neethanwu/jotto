import CoreLocation
import Observation
import UIKit

/// Settings → Places → Note where you record. While a recording goes on,
/// this iPhone follows where you are at low accuracy, so each recording
/// keeps the place it was said (`Places`), and following location keeps
/// jotto running with the phone locked, so each part from the watch turns
/// into text as it arrives instead of when jotto is next opened.
///
/// With Always, following starts when a recording does (the watch's nudge
/// wakes jotto) and stops once its parts are heard. With While Using, iOS
/// lets jotto start following only while it's in front, so it follows from
/// the last time jotto was opened, all day, coarsely between recordings,
/// and iOS shows the location arrow. The log notes fixes, their accuracy
/// and the battery, never where they were.
@MainActor @Observable
final class PlaceTracker: NSObject {
    static let shared = PlaceTracker()

    private static let key = "followsPlaces"
    private static let cardKey = "placesCardDismissed"
    private static let waitedKey = "placesCardRecording"

    /// What was chosen in Settings, kept apart from what iOS allows, so
    /// allowing location again in iOS Settings turns places back on.
    private(set) var wantsPlaces: Bool = UserDefaults.standard.bool(forKey: PlaceTracker.key) {
        didSet {
            guard wantsPlaces != oldValue else { return }
            UserDefaults.standard.set(wantsPlaces, forKey: Self.key)
            PhoneLog.shared.note("place_switch", wantsPlaces ? "on \(permissionLabel)" : "off")
            update(wantsPlaces ? "switch on" : "switch off")
        }
    }

    /// What the switch shows: on only when places are actually kept.
    var isOn: Bool { wantsPlaces && isAllowed }
    var isAllowed: Bool { permission == .authorizedAlways || permission == .authorizedWhenInUse }
    var isDenied: Bool { permission == .denied || permission == .restricted }
    /// iOS hasn't asked yet: the sheet explaining why comes first.
    var needsAsking: Bool { permission == .notDetermined }

    /// Turns places on: asks iOS (While Using, then Always) when it hasn't
    /// been asked, opens iOS Settings when location was turned off there.
    func turnOn() {
        wantsPlaces = true
        cardDismissed = true
        if isDenied {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } else {
            ask()
        }
    }

    func turnOff() { wantsPlaces = false }

    /// The card on Days offering places, after a watch recording waited
    /// for jotto to be opened. Once: gone for good when closed.
    var cardDismissed: Bool = UserDefaults.standard.bool(forKey: PlaceTracker.cardKey) {
        didSet { UserDefaults.standard.set(cardDismissed, forKey: Self.cardKey) }
    }
    private(set) var waitedRecording: String? = UserDefaults.standard.string(forKey: PlaceTracker.waitedKey)

    /// A watch recording's parts were heard only once jotto was opened.
    /// Not noted while location is off for jotto (or for the whole iPhone):
    /// that was a choice, and the card can't turn places on with one tap
    /// then. Settings → Places still explains and leads to iOS Settings.
    func recordingWaited(_ id: String) {
        guard !isOn, !isDenied, !cardDismissed, waitedRecording == nil else { return }
        waitedRecording = id
        UserDefaults.standard.set(id, forKey: Self.waitedKey)
        PhoneLog.shared.note("place_card", id)
    }

    var showsCard: Bool { !cardDismissed && !isOn && !isDenied && waitedRecording != nil }

    /// Plugged in (charging or full). Apple's model isn't rate-limited then.
    var isOnPower: Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }

    private(set) var permission: CLAuthorizationStatus = .notDetermined
    /// Precise Location is on for jotto; off, places are only roughly right.
    private(set) var isPrecise = true
    private(set) var isFollowing = false
    /// Following closely, for a recording; otherwise coarsely, between
    /// recordings with While Using.
    @ObservationIgnored private var isClose = false

    @ObservationIgnored private let manager = CLLocationManager()
    /// Asked for While Using on the way to Always.
    @ObservationIgnored private var wantsAlways = false
    @ObservationIgnored private var since: Date?
    @ObservationIgnored private var fixes = 0
    @ObservationIgnored private var lastFix: CLLocation?
    @ObservationIgnored private var batteryAtStart: Int?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var stuckBeats = 0
    @ObservationIgnored private var partsLastBeat = 0

    private override init() {
        super.init()
        manager.delegate = self
        permission = manager.authorizationStatus
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
    }

    var permissionLabel: String {
        switch permission {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While Using"
        case .denied, .restricted: "Not allowed"
        default: "Not asked"
        }
    }

    /// While Using first, then Always: iOS offers Always to an app that
    /// already has While Using, and asks at once while it's in front.
    private func ask() {
        switch manager.authorizationStatus {
        case .notDetermined:
            wantsAlways = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Follows while a recording goes on or parts are still to hear, and
    /// stops when there's neither; with While Using, from the last time
    /// jotto was opened, all day. Called whenever the pipeline's work
    /// changes: a recording starting, a part arriving, a nudge, a run
    /// ending, jotto coming to the front.
    func update(_ why: String) {
        let live = Pipeline.shared.hasLiveWork
        let wanted = isOn && (live || permission == .authorizedWhenInUse)
        if wanted, !isFollowing {
            // While Using: iOS gives no location to an app that starts
            // following out of sight.
            if permission == .authorizedWhenInUse, UIApplication.shared.applicationState == .background {
                if live { PhoneLog.shared.note("place_not_started", "\(why) while using, out of sight") }
                return
            }
            start(why)
        } else if !wanted, isFollowing {
            stop(why)
        }
        if isFollowing { tune(live: live) }
    }

    /// A recording has started: a fresh fix from just before stands for its start.
    func recordingStarted() {
        if let lastFix { take(lastFix) }
    }

    private func start(_ why: String) {
        manager.activityType = .other
        manager.allowsBackgroundLocationUpdates = true
        // Paused, iOS would suspend jotto while you sit still (a meeting),
        // and the point is that it doesn't.
        manager.pausesLocationUpdatesAutomatically = false
        // With While Using iOS shows it anyway; with Always, jotto follows
        // only while you record, which the Live Activity already shows.
        manager.showsBackgroundLocationIndicator = permission == .authorizedWhenInUse
        isClose = false
        tune(live: Pipeline.shared.hasLiveWork, quietly: true)
        manager.startUpdatingLocation()
        isFollowing = true
        since = .now
        fixes = 0
        lastFix = nil
        stuckBeats = 0
        partsLastBeat = 0
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryAtStart = battery
        PhoneLog.shared.note("place_start", "\(why) \(permissionLabel)\(isPrecise ? "" : " approximate") \(isClose ? "close" : "coarse") \(batteryText)")
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.beat()
            }
        }
    }

    /// A hundred metres while there's a recording; between recordings
    /// (While Using), three kilometres, which iOS gets from cell towers and
    /// Wi-Fi without GPS, and is enough to keep jotto running.
    private func tune(live: Bool, quietly: Bool = false) {
        guard live != isClose || quietly else { return }
        isClose = live
        manager.desiredAccuracy = live ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = live ? 50 : 1000
        if !quietly { PhoneLog.shared.note("place_tune", "\(live ? "close" : "coarse") \(batteryText)") }
    }

    private func stop(_ why: String) {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        heartbeat?.cancel()
        heartbeat = nil
        isFollowing = false
        let minutes = since.map { Int(Date.now.timeIntervalSince($0) / 60) } ?? 0
        let used = batteryAtStart.flatMap { start in battery.map { start - $0 } }
        PhoneLog.shared.note("place_stop", "\(why) \(minutes)min fixes=\(fixes) \(batteryText) used=\(used.map { "\($0)%" } ?? "?")")
        since = nil
    }

    /// Every five minutes while following: that jotto is still running, the
    /// battery, and a turn for the pipeline (which also closes a recording
    /// the watch went quiet on). Parts that keep failing out of sight with
    /// no recording going on stop it after fifteen minutes.
    private func beat() {
        let left = UIApplication.shared.backgroundTimeRemaining
        PhoneLog.shared.note("place_alive", "fixes=\(fixes) last=\(fixAge) acc=\(accuracy) left=\(left > 999 ? "-" : "\(Int(left))s") \(batteryText)")
        let parts = Pipeline.shared.partsToHear
        if permission == .authorizedAlways, !Pipeline.shared.hasLiveRecording, parts > 0, parts == partsLastBeat {
            stuckBeats += 1
        } else {
            stuckBeats = 0
        }
        partsLastBeat = parts
        if stuckBeats >= 3 {
            stop("stuck with \(parts) parts")
            return
        }
        Pipeline.shared.run()
    }

    /// A fix while following: each recording going on takes it in, if it
    /// has moved far enough to be somewhere new.
    private func take(_ fix: CLLocation) {
        guard isOn else { return }
        let store = LocalStore.shared
        var added = false
        for r in store.recordings.values where r.endedAt == nil && r.imported == nil {
            guard let marks = Places.adding(fix, to: r.places ?? [], startedAt: r.startedAt, approximate: !isPrecise) else { continue }
            let count = r.places?.count ?? 0
            store.update(r.id, startedAt: r.startedAt) { $0.places = marks }
            if marks.count > count {
                added = true
                PhoneLog.shared.note("place_mark", "\(r.id) \(marks.count) acc=\(Int(fix.horizontalAccuracy))m")
            }
        }
        if added { PlaceNames.shared.lookUp() }
    }

    /// A part has come in: how fresh a place it would get.
    func partArrived(_ index: Int) {
        guard isFollowing else { return }
        PhoneLog.shared.note("place_part", "\(index) fix=\(fixAge) acc=\(accuracy)")
    }

    private var fixAge: String {
        lastFix.map { "\(Int(Date.now.timeIntervalSince($0.timestamp)))s" } ?? "none"
    }

    private var accuracy: String {
        lastFix.map { "\(Int($0.horizontalAccuracy))m" } ?? "-"
    }

    private var battery: Int? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    var batteryText: String {
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let saver = ProcessInfo.processInfo.isLowPowerModeEnabled ? " low-power" : ""
        return "battery=\(battery.map { "\($0)%" } ?? "?")\(charging ? " charging" : "")\(saver)"
    }
}

extension PlaceTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let last = locations.last else { return }
            if fixes == 0, let since {
                PhoneLog.shared.note("place_first_fix", "\(Int(Date.now.timeIntervalSince(since)))s acc=\(Int(last.horizontalAccuracy))m")
            }
            fixes += locations.count
            lastFix = last
            if isClose { take(last) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix for now; Core Location keeps trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        let text = error.localizedDescription
        MainActor.assumeIsolated { PhoneLog.shared.note("place_error", text) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let before = permission
            permission = self.manager.authorizationStatus
            isPrecise = self.manager.accuracyAuthorization == .fullAccuracy
            PhoneLog.shared.note("place_auth", "\(permissionLabel)\(isPrecise ? "" : " approximate")")
            // Changed between While Using and Always: start over, so the
            // arrow and the all-day following match.
            if isFollowing, permission != before { stop("permission \(permissionLabel)") }
            if permission == .authorizedWhenInUse, wantsAlways {
                wantsAlways = false
                self.manager.requestAlwaysAuthorization()
            }
            update("permission \(permissionLabel)")
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { PhoneLog.shared.note("place_paused") }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { PhoneLog.shared.note("place_resumed") }
    }
}
