import CoreLocation
import Testing
@testable import TubeTrackUK

@MainActor
struct UserLocationProviderTests {
    @Test func trackingRequestedBeforeAuthorizationCallbackStartsAutomatically() {
        let manager = TestLocationManager()
        let provider = UserLocationProvider(manager: manager)
        provider.setMapTracking(true)
        #expect(provider.isRequesting)
        #expect(manager.startCount == 0)
        provider.locationManagerDidChangeAuthorization(manager)
        #expect(manager.startCount == 1)
        provider.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 51.3985, longitude: -0.0495)])
        #expect(provider.location != nil)
        #expect(!provider.isRequesting)
        provider.setMapTracking(false)
    }

    @Test func interruptionBeforeFirstFixRestartsWithoutRequiringTheLocationButton() {
        let manager = TestLocationManager()
        let provider = UserLocationProvider(manager: manager)
        provider.locationManagerDidChangeAuthorization(manager)
        provider.setMapTracking(true)
        provider.setMapTracking(false)
        #expect(!provider.isRequesting)
        provider.setMapTracking(true)
        #expect(manager.startCount == 2)
        #expect(provider.isRequesting)
        provider.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 51.3985, longitude: -0.0495)])
        #expect(provider.location != nil)
        #expect(!provider.isRequesting)
        provider.setMapTracking(false)
    }

    @Test func oneShotRequestBecomesContinuousIfTheMapOpensBeforeItsFixArrives() {
        let manager = TestLocationManager()
        let provider = UserLocationProvider(manager: manager)
        provider.locationManagerDidChangeAuthorization(manager)
        provider.requestLocation()
        #expect(manager.requestCount == 1)
        provider.setMapTracking(true)
        provider.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 51.3985, longitude: -0.0495)])
        #expect(manager.startCount == 1)
        #expect(!provider.isRequesting)
        provider.setMapTracking(false)
    }

    @Test func coarseInitialFixPopulatesTheCardWhileWaitingForAccurateMapCentering() {
        let manager = TestLocationManager()
        let provider = UserLocationProvider(manager: manager)
        provider.locationManagerDidChangeAuthorization(manager)
        provider.setMapTracking(true)
        let coarse = CLLocation(coordinate: .init(latitude: 51.3985, longitude: -0.0495),
                                altitude: 0, horizontalAccuracy: 2_000, verticalAccuracy: -1, timestamp: .now)
        provider.locationManager(manager, didUpdateLocations: [coarse])
        #expect(provider.location == coarse)
        #expect(!provider.isRequesting)
        #expect(!MapLocationFocusPolicy.isUsable(coarse))
        provider.setMapTracking(false)
    }

    @Test func failedInitialFixCanRestartAndCannotLeaveAnIndefiniteSpinner() async throws {
        let manager = TestLocationManager()
        let provider = UserLocationProvider(manager: manager, requestTimeout: .milliseconds(10))
        provider.locationManagerDidChangeAuthorization(manager)
        provider.setMapTracking(true)
        let deadline = ContinuousClock.now + .seconds(5)
        while provider.isRequesting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!provider.isRequesting)
        #expect(provider.errorMessage != nil)
        provider.setMapTracking(true)
        #expect(manager.startCount == 2)
        #expect(provider.isRequesting)
        provider.setMapTracking(false)
    }
}

private final class TestLocationManager: CLLocationManager {
    var startCount = 0
    var requestCount = 0
    override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    override func startUpdatingLocation() { startCount += 1 }
    override func stopUpdatingLocation() {}
    override func requestLocation() { requestCount += 1 }
    override func startUpdatingHeading() {}
    override func stopUpdatingHeading() {}
}
