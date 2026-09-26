import CoreLocation
import Observation
import OSLog

@MainActor
@Observable
final class UserLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    @ObservationIgnored private let requestTimeout: Duration

    private(set) var location: CLLocation?
    private(set) var heading: CLLocationDirection?
    @ObservationIgnored private var mapTracking = false
    @ObservationIgnored private var isUpdatingMapLocation = false
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var isRequesting = false
    private(set) var errorMessage: String?
    private(set) var hasRequestedLocation = false

    @ObservationIgnored private let manager: CLLocationManager
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TubeTrackUK",
        category: "Location"
    )
    @ObservationIgnored private var hasReceivedAuthorizationStatus = false
    @ObservationIgnored private var authorizationRequestInFlight = false
    @ObservationIgnored private var locationRequestInFlight = false
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    override convenience init() {
        self.init(manager: CLLocationManager())
    }

    init(manager: CLLocationManager, requestTimeout: Duration = .seconds(15)) {
        self.manager = manager
        self.requestTimeout = requestTimeout
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.headingFilter = 5
        manager.delegate = self
    }

    var needsSettingsPermission: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func setMapTracking(_ active: Bool) {
        if mapTracking == active {
            if active, !isUpdatingMapLocation, !isRequesting { requestLocation() }
            return
        }
        mapTracking = active
        if active {
            requestLocation()
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            isUpdatingMapLocation = false
            heading = nil
            // Cancel the map-owned request when its screen leaves the foreground.
            timeoutTask?.cancel()
            timeoutTask = nil
            locationRequestInFlight = false
            isRequesting = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard mapTracking, newHeading.headingAccuracy >= 0 else {
            heading = nil
            return
        }
        heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func requestLocation() {
        hasRequestedLocation = true
        errorMessage = nil
        logger.debug("Location requested")
        if mapTracking, isUpdatingMapLocation, let location,
           MapLocationFocusPolicy.isUsable(location) {
            return
        }

        guard !locationRequestInFlight, !authorizationRequestInFlight else {
            return
        }

        isRequesting = true
        scheduleTimeout()
        guard hasReceivedAuthorizationStatus else {
            // Core Location guarantees an initial authorization callback after
            // the delegate is installed. Avoid synchronously querying its
            // authorization service on the main actor while we wait for it.
            return
        }

        continueRequest(for: authorizationStatus)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        authorizationStatus = status
        hasReceivedAuthorizationStatus = true
        logger.debug("Location authorization changed: \(status.rawValue, privacy: .public)")

        guard hasRequestedLocation else { return }
        continueRequest(for: status)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last(where: { Self.isFreshFix($0) }) else {
            // Wait for a usable fix; the request timeout handles persistent failure.
            return
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        locationRequestInFlight = false
        location = latestLocation
        isRequesting = false
        errorMessage = nil
        startMapUpdatesIfNeeded()
        logger.debug("Location request completed")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let locationError = error as? CLError
        if mapTracking && locationError?.code == .locationUnknown { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        locationRequestInFlight = false
        isRequesting = false

        logger.error(
            "Location request failed: \(locationError?.code.rawValue ?? -1, privacy: .public)"
        )

        if locationError?.code == .denied {
            authorizationStatus = manager.authorizationStatus
            if authorizationStatus == .authorizedAlways
                || authorizationStatus == .authorizedWhenInUse {
                errorMessage = "Location Services are turned off on this iPhone."
            }
            return
        }

        errorMessage = "We couldn’t determine your location. Please try again."
    }

    private func continueRequest(for status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            guard !locationRequestInFlight else { return }
            isRequesting = true
            guard !authorizationRequestInFlight else { return }
            authorizationRequestInFlight = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !locationRequestInFlight else { return }
            authorizationRequestInFlight = false
            beginLocationRequest()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            isUpdatingMapLocation = false
            location = nil
            heading = nil
            authorizationRequestInFlight = false
            locationRequestInFlight = false
            isRequesting = false
            timeoutTask?.cancel()
            timeoutTask = nil
        @unknown default:
            authorizationRequestInFlight = false
            isRequesting = false
            errorMessage = "Your location is not currently available."
            timeoutTask?.cancel()
            timeoutTask = nil
        }
    }

    private func beginLocationRequest() {
        guard !locationRequestInFlight else { return }
        locationRequestInFlight = true
        isRequesting = true
        scheduleTimeout()
        if mapTracking {
            if isUpdatingMapLocation { manager.stopUpdatingLocation() }
            isUpdatingMapLocation = false
            startMapUpdatesIfNeeded()
        } else {
            manager.requestLocation()
        }
    }

    private func startMapUpdatesIfNeeded() {
        guard mapTracking, !isUpdatingMapLocation else { return }
        isUpdatingMapLocation = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    // A coarse first fix can populate Near Me while GPS refines it. Map centering
    // retains its stricter accuracy policy; don't discard all location data here.
    static func isFreshFix(_ location: CLLocation, now: Date = .now) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy >= 0
            && abs(location.timestamp.timeIntervalSince(now)) <= 120
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.requestTimeout ?? .seconds(15))
            } catch {
                return
            }
            guard let self, self.isRequesting else { return }
            if self.locationRequestInFlight {
                self.manager.stopUpdatingLocation()
                self.manager.stopUpdatingHeading()
                self.isUpdatingMapLocation = false
            }
            self.authorizationRequestInFlight = false
            self.locationRequestInFlight = false
            self.isRequesting = false
            self.errorMessage = "Finding your location is taking too long. Please try again."
            self.logger.error("Location request timed out")
        }
    }

}
