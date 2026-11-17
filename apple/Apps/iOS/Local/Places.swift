import CoreLocation
import MapKit

/// Where a recording was said, from the fixes `PlaceTracker` gets while it
/// goes on: the first place, then one more each time it has moved a few
/// hundred metres. Names come from Apple's maps; everything stays on this
/// iPhone, and a place goes out with a recording only when sending adds it.
enum Places {
    /// How far it has to move before a paragraph is marked as somewhere new.
    static let moved: CLLocationDistance = 400
    /// How far apart the start and the end have to be for the end to show
    /// next to the start ("Lumen Café → Willow Park").
    static let farEnough: CLLocationDistance = 1000
    /// Fixes coarser than this aren't used, unless Precise Location is off
    /// and they're all there is.
    static let coarsest: CLLocationAccuracy = 300
    /// With Precise Location off, fixes are a few kilometres either way.
    static let coarsestApproximate: CLLocationAccuracy = 10_000
    /// Raised when how places are named changes, so places named before
    /// are looked up again (their old name shows meanwhile).
    static let naming = 2

    /// `marks` with `fix` taken in, or nil when it changes nothing.
    static func adding(_ fix: CLLocation, to marks: [PlaceMark], startedAt: Date, approximate: Bool) -> [PlaceMark]? {
        let accuracy = fix.horizontalAccuracy
        guard accuracy >= 0, accuracy <= (approximate ? coarsestApproximate : coarsest) else { return nil }
        // A fix from before the recording, still fresh, stands for its start.
        let at = fix.timestamp.timeIntervalSince(startedAt)
        guard at > -120 else { return nil }
        let mark = PlaceMark(at: max(0, at), latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, accuracy: accuracy)
        guard let last = marks.last else { return [mark] }
        let distance = fix.distance(from: last.location)
        // A better fix of the same place, before its name is looked up.
        if !last.isLookedUp, accuracy < last.accuracy, distance <= last.accuracy {
            var better = marks
            better[better.count - 1] = PlaceMark(at: last.at, latitude: mark.latitude, longitude: mark.longitude, accuracy: accuracy)
            return better
        }
        guard distance > max(moved, 2 * max(accuracy, last.accuracy)) else { return nil }
        return marks + [mark]
    }

    /// Where the paragraph starting `start` seconds in was said.
    static func mark(at start: Double, in marks: [PlaceMark]) -> PlaceMark? {
        marks.last { $0.at <= start + 1 } ?? marks.first
    }

    /// Paragraphs (by id) said somewhere other than the one before them,
    /// with the place they moved to. The first paragraph isn't one: the
    /// recording's place is shown above the text.
    static func changes(_ blocks: [TranscriptBlock], marks: [PlaceMark]) -> [Int: PlaceMark] {
        guard marks.count > 1 else { return [:] }
        var out: [Int: PlaceMark] = [:]
        var current = mark(at: blocks.first?.start ?? 0, in: marks)?.name
        for block in blocks.dropFirst() where block.backchannel != true {
            guard let here = mark(at: block.start, in: marks), let name = here.name else { continue }
            if name != current {
                out[block.id] = here
                current = name
            }
        }
        return out
    }

    /// The start's name and, when it ended far from there under another
    /// name, the end's.
    static func route(_ marks: [PlaceMark]?) -> (start: String, end: String?)? {
        guard let marks, let first = marks.first(where: { $0.name != nil }), let start = first.name else { return nil }
        // An end known only by its city says nothing next to a street.
        guard let last = marks.last(where: { $0.name != nil && $0.name != $0.city }), let end = last.name, end != start,
              last.location.distance(from: first.location) >= farEnough else { return (start, nil) }
        return (start, end)
    }

    /// "Lumen Café → Willow Park", or the one place.
    static func label(_ marks: [PlaceMark]?) -> String? {
        guard let route = route(marks) else { return nil }
        return route.end.map { "\(route.start) → \($0)" } ?? route.start
    }

    /// The first place in full, for the line under a transcript's date.
    static func fullName(_ mark: PlaceMark) -> String? {
        guard let name = mark.name else { return nil }
        guard let city = mark.city, !city.isEmpty, city != name else { return name }
        return "\(name), \(city)"
    }

    /// Opens a place in Maps, pinned and named.
    @MainActor static func openInMaps(_ mark: PlaceMark) {
        let item = MKMapItem(location: mark.location, address: nil)
        item.name = mark.name
        item.openInMaps(launchOptions: [MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))])
    }

    /// ISO 6709, as audio files carry a place: "+37.3349-122.0090/".
    static func iso6709(_ mark: PlaceMark) -> String {
        String(format: "%+08.4f%+09.4f/", mark.latitude, mark.longitude)
    }
}

extension PlaceMark {
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

/// Looks up the names of places, one at a time and slowly: Apple limits
/// how often an app may ask. A recording's places are looked up as they're
/// marked; any left (no network, or asked too often) when jotto is next
/// opened or a recording ends.
@MainActor
final class PlaceNames {
    static let shared = PlaceNames()

    private var running = false
    /// Asked too often: not before then.
    private var notBefore: Date?
    /// Names already found, by place to about a hundred metres.
    private var known: [String: (name: String?, city: String?)] = [:]

    private init() {}

    func lookUp() {
        guard !running, notBefore.map({ $0 < .now }) ?? true else { return }
        running = true
        Task {
            await lookUpAll()
            running = false
        }
    }

    private func lookUpAll() async {
        var looked = 0
        while let (id, index, mark) = next() {
            let found: (name: String?, city: String?)
            if let cached = known[key(mark)] {
                found = cached
            } else {
                do {
                    found = try await name(of: mark)
                    known[key(mark)] = found
                    looked += 1
                } catch let error as MKError where error.code == .placemarkNotFound {
                    // Apple has nothing there, or not from here: mainland
                    // China's maps don't name places abroad. It stays nameless.
                    found = (nil, nil)
                    known[key(mark)] = found
                    PhoneLog.shared.note("place_name_none")
                } catch {
                    let throttled = (error as? MKError)?.code == .loadingThrottled
                    notBefore = Date.now.addingTimeInterval(throttled ? 120 : 60)
                    PhoneLog.shared.note("place_name_failed", throttled ? "throttled" : error.localizedDescription)
                    return
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
            guard let r = LocalStore.shared.recordings[id] else { continue }
            LocalStore.shared.update(id, startedAt: r.startedAt) { r in
                guard var marks = r.places, index < marks.count, marks[index] == mark else { return }
                // Named before and nothing from Apple this time: the old name stays.
                if found.name != nil || mark.name == nil {
                    marks[index].name = found.name
                    marks[index].city = found.city
                    marks[index].nameless = found.name == nil ? true : nil
                }
                marks[index].naming = Places.naming
                r.places = marks
            }
        }
        if looked > 0 {
            PhoneLog.shared.note("place_names", "\(looked)")
            await Library.shared.refresh()
        }
    }

    /// The next place without a name, from the newest recording back.
    private func next() -> (String, Int, PlaceMark)? {
        for r in LocalStore.shared.recordings.values.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard let marks = r.places else { continue }
            if let i = marks.firstIndex(where: { !$0.isLookedUp }) { return (r.id, i, marks[i]) }
        }
        return nil
    }

    /// The area it was in ("Central Park", "Jing'an Temple", a mall), else
    /// the street ("Fumin Road"), else the neighbourhood or district, else
    /// the city. The nearest shop or building isn't used, as at a hundred
    /// metres it's often the one next door, nor an address with its number,
    /// which may be someone's home.
    private func name(of mark: PlaceMark) async throws -> (name: String?, city: String?) {
        guard let request = MKReverseGeocodingRequest(location: mark.location) else { return (nil, nil) }
        guard let item = try await request.mapItems.first else { return (nil, nil) }
        let city = item.addressRepresentations?.cityName ?? item.placemark.locality
        // Only roughly known (Precise Location off): the city.
        if mark.accuracy > 1000 { return (city ?? item.name, nil) }
        // MapKit's newer address types don't carry areas or neighbourhoods yet.
        let placemark = item.placemark
        let street = item.name.flatMap { $0 == placemark.thoroughfare ? $0 : nil }
        let name = Self.area(item) ?? street ?? placemark.subLocality ?? city ?? item.name
        return (name, city)
    }

    /// Areas come smallest first, and the last is often the island or
    /// borough it's on: on a street in Wan Chai, the only one is "Hong
    /// Kong Island", which says less than the district does. One that's
    /// also a region of the address is left out, unless it's the place
    /// itself.
    private static func area(_ item: MKMapItem) -> String? {
        let placemark = item.placemark
        let regions = Set([placemark.administrativeArea, placemark.subAdministrativeArea, placemark.locality,
                           placemark.subLocality, item.addressRepresentations?.cityName].compactMap { $0 })
        return placemark.areasOfInterest?.first { $0 == item.name || !regions.contains($0) }
    }

    private func key(_ mark: PlaceMark) -> String {
        String(format: "%.3f,%.3f,%d", mark.latitude, mark.longitude, mark.accuracy > 1000 ? 1 : 0)
    }
}
