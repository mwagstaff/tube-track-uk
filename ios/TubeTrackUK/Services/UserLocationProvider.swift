import CoreLocation
import Observation
import OSLog

@MainActor
@Observable
final class UserLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private static let requestTimeout: Duration = .seconds(15)

    private(set) var location: CLLocation?
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

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
    }

    var needsSettingsPermission: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestLocation() {
        hasRequestedLocation = true
        errorMessage = nil
        logger.debug("Location requested")

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
        guard let latestLocation = locations.last else {
            finishWithError("We couldn’t determine your location. Please try again.")
            return
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        locationRequestInFlight = false
        location = latestLocation
        isRequesting = false
        errorMessage = nil
        logger.debug("Location request completed")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        locationRequestInFlight = false
        isRequesting = false

        let locationError = error as? CLError
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
        guard !locationRequestInFlight else { return }

        switch status {
        case .notDetermined:
            isRequesting = true
            guard !authorizationRequestInFlight else { return }
            authorizationRequestInFlight = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationRequestInFlight = false
            beginOneShotRequest()
        case .denied, .restricted:
            authorizationRequestInFlight = false
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

    private func beginOneShotRequest() {
        guard !locationRequestInFlight else { return }
        locationRequestInFlight = true
        isRequesting = true
        scheduleTimeout()
        manager.requestLocation()
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.requestTimeout)
            } catch {
                return
            }
            guard let self, self.isRequesting else { return }
            if self.locationRequestInFlight {
                self.manager.stopUpdatingLocation()
            }
            self.authorizationRequestInFlight = false
            self.locationRequestInFlight = false
            self.isRequesting = false
            self.errorMessage = "Finding your location is taking too long. Please try again."
            self.logger.error("Location request timed out")
        }
    }

    private func finishWithError(_ message: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        locationRequestInFlight = false
        isRequesting = false
        errorMessage = message
        logger.error("Location request returned no locations")
    }
}
