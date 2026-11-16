import CoreLocation
import Observation
import UIKit

/// Spike, in test builds only (Settings → Beta → Places while recording):
/// while a recording goes on, this iPhone follows where you are at low
/// accuracy, so each part can carry the place it was said. Following
/// location also keeps jotto running with the phone locked, so each part
/// from the watch is heard as it arrives instead of when jotto is next
/// opened. What it tests: that this holds through a long recording with the
/// phone left alone, and what it costs in battery. The log notes fixes,
/// their accuracy and the battery, never where they were.
@MainActor @Observable
final class PlaceTracker: NSObject {
    static let shared = PlaceTracker()

    private static let key = "followsPlaces"

    var isOn: Bool = UserDefaults.standard.bool(forKey: PlaceTracker.key) {
        didSet {
            guard isOn != oldValue else { return }
            UserDefaults.standard.set(isOn, forKey: Self.key)
            PhoneLog.shared.note("place_switch", isOn ? "on \(permissionLabel)" : "off")
            if isOn { ask() }
            update(isOn ? "switch on" : "switch off")
        }
    }

    private(set) var permission: CLAuthorizationStatus = .notDetermined
    private(set) var isFollowing = false

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
    }

    var permissionLabel: String {
        switch permission {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using"
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
    /// stops when there's neither. Called whenever the pipeline's work
    /// changes: a recording starting, a part arriving, a nudge, a run ending.
    func update(_ why: String) {
        let allowed = permission == .authorizedAlways || permission == .authorizedWhenInUse
        let wanted = isOn && allowed && Pipeline.shared.hasLiveWork
        if wanted, !isFollowing {
            start(why)
        } else if !wanted, isFollowing {
            stop(why)
        }
    }

    private func start(_ why: String) {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.activityType = .other
        manager.allowsBackgroundLocationUpdates = true
        // Paused, iOS would suspend jotto while you sit still (a meeting),
        // and the point is that it doesn't.
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
        isFollowing = true
        since = .now
        fixes = 0
        lastFix = nil
        stuckBeats = 0
        partsLastBeat = 0
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryAtStart = battery
        PhoneLog.shared.note("place_start", "\(why) \(permissionLabel) \(batteryText)")
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.beat()
            }
        }
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
        UIDevice.current.isBatteryMonitoringEnabled = false
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
        if !Pipeline.shared.hasLiveRecording, parts > 0, parts == partsLastBeat {
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

    private var batteryText: String {
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        return "battery=\(battery.map { "\($0)%" } ?? "?")\(charging ? " charging" : "")"
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
            permission = self.manager.authorizationStatus
            let precise = self.manager.accuracyAuthorization == .fullAccuracy
            PhoneLog.shared.note("place_auth", "\(permissionLabel)\(precise ? "" : " approximate")")
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
