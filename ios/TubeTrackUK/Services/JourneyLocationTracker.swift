import CoreLocation
import Foundation
import Observation
import TubeTrackCore

/// Location is evaluated on-device. Only the inferred leg/phase is sent to the API.
@MainActor @Observable
final class JourneyLocationTracker: NSObject, @preconcurrency CLLocationManagerDelegate {
    var session: TrackedJourney? {
        didSet {
            if oldValue?.id != session?.id || oldValue?.legIndex != session?.legIndex || oldValue?.phase != session?.phase {
                originFix = nil; destinationFix = nil
            }
        }
    }
    var suppressAutomaticUntil = Date.distantPast
    private(set) var message: String?
    @ObservationIgnored var onProgress: ((Int, String) -> Void)?
    @ObservationIgnored var onRefresh: (() -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var originFix: CLLocation?
    @ObservationIgnored private var destinationFix: CLLocation?
    @ObservationIgnored private var lastTransition = Date.distantPast

    override init() {
        super.init(); manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.activityType = .otherNavigation
        manager.showsBackgroundLocationIndicator = true
    }
    func start() {
        guard session != nil else { return }
        enabled = true; message = "Finding your position; you can change your current leg at any time."
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: begin()
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: message = "Location is unavailable. Use the journey progress controls."
        }
    }
    func stop() { enabled = false; manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false; originFix = nil; destinationFix = nil }
    private func begin() { guard enabled else { return }; manager.allowsBackgroundLocationUpdates = true; manager.startUpdatingLocation() }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) { begin() }
        else if [.denied, .restricted].contains(manager.authorizationStatus) {
            manager.stopUpdatingLocation(); message = "Location is unavailable. Use the journey progress controls."
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        message = "Position uncertain. Your current leg is unchanged; use the progress controls if needed."
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard enabled, let session else { return }
        guard Date.now < session.endsAt else { stop(); return }
        onRefresh?()
        guard let fix = locations.last, JourneyProgressEvidence.usable(fix), Date.now >= suppressAutomaticUntil,
              Date.now.timeIntervalSince(lastTransition) > 30,
              let from = Self.coordinate(session.currentLeg.from.id), let to = Self.coordinate(session.currentLeg.to.id) else { return }
        let origin = fix.distance(from: from), destination = fix.distance(from: to)
        if session.phase == "waiting" {
            if origin < 120 { originFix = fix }
            if let start = originFix, JourneyProgressEvidence.departed(start: start, current: fix, origin: from, destination: to) {
                transition(session.legIndex, "onboard")
            }
        } else if session.phase == "onboard" {
            // A sustained accurate fix at the interchange, not one GPS jump or a train passing nearby.
            if destination < 100, fix.speed >= 0, fix.speed < 2.5 {
                if let first = destinationFix, fix.timestamp.timeIntervalSince(first.timestamp) >= 15 {
                    if let next = session.transitIndices.first(where: { $0 > session.legIndex }) { transition(next, "waiting") }
                    else { transition(session.legIndex, "complete") }
                } else if destinationFix == nil { destinationFix = fix }
            } else { destinationFix = nil }
        }
        message = "Location is following your journey. Confirm the train if several services are nearby."
    }
    private func transition(_ index: Int, _ phase: String) {
        lastTransition = .now; originFix = nil; destinationFix = nil; onProgress?(index, phase)
    }
    private static func coordinate(_ id: String) -> CLLocation? {
        guard let stop = DepartureStop.bundled.first(where: { $0.id == id || $0.stopIDs.contains(id) || $0.railCodes.contains(id) }) else { return nil }
        return CLLocation(latitude: stop.latitude, longitude: stop.longitude)
    }
}

enum JourneyProgressEvidence {
    static func usable(_ fix: CLLocation, now: Date = .now) -> Bool {
        fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 60
            && abs(fix.timestamp.timeIntervalSince(now)) < 30
    }
    static func departed(start: CLLocation, current: CLLocation, origin: CLLocation, destination: CLLocation) -> Bool {
        let elapsed = current.timestamp.timeIntervalSince(start.timestamp)
        return elapsed >= 15 && elapsed <= 180 && current.speed > 3
            && current.distance(from: origin) > 250
            && current.distance(from: destination) + 150 < start.distance(from: destination)
            && current.distance(from: start) / elapsed < 55
    }
}
