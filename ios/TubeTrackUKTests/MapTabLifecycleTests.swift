import CoreLocation
import SwiftUI
import Testing
import UIKit
@testable import TubeTrackUK

@Suite(.serialized)
struct MapTabLifecycleTests {
    @Test(arguments: [true, false]) @MainActor
    func coldLaunchStartsLocationWithoutTappingTheMap(showsClosestStation: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suiteName = "MapTabLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(showsClosestStation, forKey: "showsClosestStation")
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.setNetworkAvailable(false)
        let manager = StartupLocationManager()
        let provider = UserLocationProvider(manager: manager)
        provider.locationManagerDidChangeAuthorization(manager)
        let host = UIHostingController(rootView: RootTabView()
            .environment(state)
            .environment(provider)
            .environment(AppBackgroundImageStore(imageURLs: [], startsTimer: false))
            .environment(GameCenterService(defaults: defaults))
            .environment(TubeGameHighScoreStore(defaults: defaults))
            .environment(StationBoardActivityController())
            .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            provider.setMapTracking(false)
            state.setActive(false)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: suiteName)
        }
        for _ in 0..<100 {
            if manager.startCount > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.startCount > 0)
        #expect(provider.isRequesting)
        provider.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 51.3985, longitude: -0.0495)])
        for _ in 0..<100 {
            if let snapshot = state.beckMapCameraSnapshot,
               abs(snapshot.scale - Double(MapLocationFocusPolicy.schematicScale)) < 0.0001 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let snapshot = try #require(state.beckMapCameraSnapshot)
        #expect(abs(snapshot.scale - Double(MapLocationFocusPolicy.schematicScale)) < 0.0001)
        #expect(provider.location != nil)
        #expect(!provider.isRequesting)
    }

    @Test @MainActor func locationRequestBeforeArtworkLoadsSurvivesInitialLayout() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = TubeAppState()
        let graph = try TubeGraph.bundled()
        state.graph = graph
        let request = MapLocationFocusRequest(id: 1, latitude: 51.3985, longitude: -0.0495, snappedStationID: nil)
        let host = UIHostingController(rootView: MapTabsHarness(state: state, locationFocusRequest: request))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }
        for _ in 0..<100 {
            if let snapshot = state.beckMapCameraSnapshot,
               abs(snapshot.scale - Double(MapLocationFocusPolicy.schematicScale)) < 0.0001 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let snapshot = try #require(state.beckMapCameraSnapshot)
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let point = try #require(SharedMapProjection.artworkPoint(for: request.coordinate, document: document, graph: graph))
        #expect(abs(snapshot.scale - Double(MapLocationFocusPolicy.schematicScale)) < 0.0001)
        #expect(abs(point.x * snapshot.scale + snapshot.offsetX - snapshot.viewportWidth / 2) < 1)
        #expect(abs(point.y * snapshot.scale + snapshot.offsetY - snapshot.viewportHeight / 2) < 1)
    }

    @Test @MainActor func returningFromNearMePreservesZoomPanAndGestureSurface() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = TubeAppState()
        state.graph = try TubeGraph.bundled()
        let host = UIHostingController(rootView: MapTabsHarness(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }

        for _ in 0..<100 {
            if state.beckMapCameraSnapshot != nil,
               coordinator(in: host.view) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let original = try #require(state.beckMapCameraSnapshot)
        let gestures = try #require(coordinator(in: host.view))
        let anchor = CGPoint(x: original.viewportWidth * 0.7, y: original.viewportHeight * 0.4)
        // Zoom in, then out around an off-centre anchor, as in the reported flow.
        for magnification: CGFloat in [3, 0.3] {
            gestures.handlePinch(state: .began, magnification: 1, location: anchor)
            gestures.handlePinch(state: .changed, magnification: magnification, location: anchor)
            gestures.handlePinch(state: .ended, magnification: magnification, location: anchor)
        }
        let expected = try #require(state.beckMapCameraSnapshot)
        #expect(expected != original)

        for _ in 0..<3 {
            state.selectedTab = .nearMe
            try await Task.sleep(for: .milliseconds(300))
            state.selectedTab = .map
            try await Task.sleep(for: .milliseconds(500))
            #expect(state.beckMapCameraSnapshot == expected)
            #expect(coordinator(in: host.view) === gestures)
            gestures.handleTap(at: CGPoint(x: 2, y: 2))
            #expect(state.selectedTab == .map)
        }
    }

    @MainActor private func coordinator(in view: UIView) -> BeckMapGestureSurface.Coordinator? {
        for gesture in view.gestureRecognizers ?? [] {
            if let coordinator = gesture.delegate as? BeckMapGestureSurface.Coordinator {
                return coordinator
            }
        }
        return view.subviews.lazy.compactMap { coordinator(in: $0) }.first
    }
}

private final class StartupLocationManager: CLLocationManager {
    var startCount = 0
    override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    override func startUpdatingLocation() { startCount += 1 }
    override func stopUpdatingLocation() {}
    override func startUpdatingHeading() {}
    override func stopUpdatingHeading() {}
}

private struct MapTabsHarness: View {
    @State private var locationProvider = UserLocationProvider()
    @Bindable var state: TubeAppState
    var locationFocusRequest: MapLocationFocusRequest? = nil

    var body: some View {
        TabView(selection: $state.selectedTab) {
            NavigationStack {
                BeckMapScreen(
                    resetToken: 0,
                    locationFocusRequest: locationFocusRequest,
                    contentVerticalBias: 36,
                    onUserZoomIn: {},
                    onInteractionChange: { _ in },
                    onBackgroundTap: {}
                )
            }
            .tabItem { Text("Map") }
            .tag(AppTab.map)
            Text("Near Me")
                .tabItem { Text("Near Me") }
                .tag(AppTab.nearMe)
        }
        .environment(state)
        .environment(locationProvider)
    }
}
