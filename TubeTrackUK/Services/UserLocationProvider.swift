import CoreLocation
import Observation

@MainActor
@Observable
final class UserLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var location: CLLocation?
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var isRequesting = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let manager: CLLocationManager
    @ObservationIgnored private var requestInitiated = false

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var needsSettingsPermission: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestLocation() {
        errorMessage = nil
        requestInitiated = true
        authorizationStatus = manager.authorizationStatus

        guard CLLocationManager.locationServicesEnabled() else {
            isRequesting = false
            errorMessage = "Location Services are turned off on this iPhone."
            return
        }

        switch authorizationStatus {
        case .notDetermined:
            isRequesting = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginOneShotRequest()
        case .denied, .restricted:
            isRequesting = false
        @unknown default:
            isRequesting = false
            errorMessage = "Your location is not currently available."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard requestInitiated else { return }

        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            beginOneShotRequest()
        case .denied, .restricted:
            isRequesting = false
        case .notDetermined:
            break
        @unknown default:
            isRequesting = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last else { return }
        location = latestLocation
        isRequesting = false
        errorMessage = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        isRequesting = false
        if let locationError = error as? CLError, locationError.code == .denied {
            authorizationStatus = manager.authorizationStatus
            return
        }
        errorMessage = "We couldn’t determine your location. Please try again."
    }

    private func beginOneShotRequest() {
        isRequesting = true
        manager.requestLocation()
    }
}
