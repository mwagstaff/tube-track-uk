import CoreLocation
import SwiftUI
import TubeTrackCore
import Testing
import UIKit
@testable import TubeTrackUK

@Suite(.serialized)
struct MapTabLifecycleTests {
    @Test(arguments: [true, false]) @MainActor
    func coldLaunchStartsLocationRegardlessOfLegacyBoardPreference(legacyBoardPreference: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suiteName = "MapTabLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(legacyBoardPreference, forKey: "showsClosestStation")
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.setNetworkAvailable(false)
        let manager = StartupLocationManager()
        let provider = UserLocationProvider(manager: manager)
        provider.locationManagerDidChangeAuthorization(manager)
        let host = UIHostingController(rootView: RootTabView()
            .environment(state)
            .environment(ScheduledJourneyStore(defaults: defaults, observesTokens: false))
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

    @Test(arguments: [false, true]) @MainActor
    func journeyTabSelectionSurvivesUpdatingBothStationFields(accessibleDarkMode: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suite = "JourneyTabSelection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.graph = try TubeGraph.bundled().includingNationalRailStations()
        state.setNetworkAvailable(false)
        let provider = UserLocationProvider(manager: StartupLocationManager())
        let schedules = ScheduledJourneyPresentation()
        let hub = try #require(StationIndex.bundled.hub(containing: "940GZZLUOXC"))
        let saved = ScheduledJourney.suggested(outbound: ScheduledBoard(hub: hub, line: .central))
        let cache: [String: Any] = ["journeys": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))],
                                  "revision": 1, "maximumJourneys": 3]
        defaults.set(try JSONSerialization.data(withJSONObject: cache), forKey: "scheduledJourneys.cache.\(AppInstall.identifier)")
        let scheduleStore = ScheduledJourneyStore(defaults: defaults,
            baseURL: URL(string: "http://127.0.0.1:1")!, observesTokens: false)
        let host = UIHostingController(rootView: RootTabView(schedulePresentation: schedules)
            .environment(state).environment(provider)
            .environment(scheduleStore)
            .environment(AppBackgroundImageStore(imageURLs: [], startsTimer: false))
            .environment(GameCenterService(defaults: defaults))
            .environment(TubeGameHighScoreStore(defaults: defaults))
            .environment(StationBoardActivityController())
            .environment(\.scenePhase, .active)
            .environment(\.colorScheme, accessibleDarkMode ? .dark : .light)
            .environment(\.dynamicTypeSize, accessibleDarkMode ? .accessibility3 : .large))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            provider.setMapTracking(false)
            state.setActive(false)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: suite)
        }
        func findTabs(_ controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            return controller.children.lazy.compactMap { findTabs($0) }.first
        }
        for _ in 0..<40 {
            if let tabs = findTabs(host), tabs.viewControllers?.count == 4, tabs.delegate != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Allow the appearance representable to install its tab observation.
        try await Task.sleep(for: .milliseconds(200))
        let tabs = try #require(findTabs(host))
        #expect(tabs.viewControllers?.count == 4)
        let journeys = try #require(tabs.viewControllers?[2])
        // Appearance customization must leave SwiftUI's complete native
        // delegate intact, including callbacks this test does not simulate.
        if let journeyTab = tabs.tabs.first(where: { $0.viewController === journeys }) {
            let previousTab = tabs.selectedTab
            #expect(tabs.delegate?.tabBarController?(tabs, shouldSelectTab: journeyTab) != false)
            tabs.selectedTab = journeyTab
            tabs.delegate?.tabBarController?(tabs, didSelectTab: journeyTab, previousTab: previousTab)
        } else {
            tabs.selectedViewController = journeys
            tabs.delegate?.tabBarController?(tabs, didSelect: journeys)
        }
        #expect(state.selectedTab == .journeys)
        state.journeyPlanner.stationField = .from
        try await Task.sleep(for: .milliseconds(400))
        #expect(tabs.presentedViewController != nil || host.presentedViewController != nil)
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        state.journeyPlanner.from = state.graph?.stationsByID["nr:KTH"]
        try await Task.sleep(for: .milliseconds(200))
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        state.journeyPlanner.stationField = nil
        for _ in 0..<60 {
            if state.selectedTab == .journeys, tabs.selectedViewController === journeys,
               tabs.presentedViewController == nil, host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        state.journeyPlanner.stationField = .to
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        state.journeyPlanner.to = state.graph?.stationsByID["940GZZLUOXC"]
        try await Task.sleep(for: .milliseconds(200))
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        state.journeyPlanner.stationField = nil
        for _ in 0..<60 {
            if state.selectedTab == .journeys, tabs.selectedViewController === journeys,
               tabs.presentedViewController == nil, host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        // Dismissing without a selection must also preserve the tab and fields.
        let from = state.journeyPlanner.from
        let to = state.journeyPlanner.to
        state.journeyPlanner.stationField = .from
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        state.journeyPlanner.stationField = nil
        try await Task.sleep(for: .milliseconds(400))
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        #expect(state.journeyPlanner.from == from)
        #expect(state.journeyPlanner.to == to)

        schedules.showsList = true
        try await Task.sleep(for: .milliseconds(500))
        #expect(state.selectedTab == .journeys)
        schedules.confirmDeletion(of: saved)
        try await Task.sleep(for: .milliseconds(800))
        func findAlert(_ controller: UIViewController) -> UIAlertController? {
            if let alert = controller as? UIAlertController { return alert }
            if let presented = controller.presentedViewController, let alert = findAlert(presented) { return alert }
            return controller.children.lazy.compactMap { findAlert($0) }.first
        }
        let confirmation = try #require(findAlert(host))
        #expect(confirmation.actions.contains { $0.title == "Delete journey" })
        #expect(confirmation.actions.contains { $0.title == "Cancel" })
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        #expect(schedules.showsList)
        #expect(scheduleStore.journeys == [saved])
        // A later update must not dismiss the confirmation or change tabs.
        state.journeyPlanner.accessibility = .platform
        try await Task.sleep(for: .milliseconds(500))
        #expect(findAlert(host) === confirmation)
        #expect(state.selectedTab == .journeys)
        schedules.showsDeleteConfirmation = false
        for _ in 0..<40 {
            if findAlert(host) == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(findAlert(host) == nil)
        #expect(scheduleStore.journeys == [saved])
        #expect(schedules.showsList)
        #expect(state.selectedTab == .journeys)
        schedules.editing = saved
        try await Task.sleep(for: .milliseconds(500))
        #expect(state.selectedTab == .journeys)
        #expect(tabs.selectedViewController === journeys)
        schedules.editing = nil
        try await Task.sleep(for: .milliseconds(500))
        #expect(schedules.showsList)
        #expect(state.selectedTab == .journeys)
    }

    @Test @MainActor func appearanceLeavesNativeTabDelegateIntact() async {
        let tabs = UITabBarController()
        let nativeDelegate = NativeTabDelegate()
        tabs.delegate = nativeDelegate
        let appearance = TabBarAppearanceController()
        tabs.addChild(appearance)
        tabs.view.addSubview(appearance.view)
        appearance.didMove(toParent: tabs)

        for transparent in [true, false, true] {
            appearance.backgroundIsTransparent = transparent
            appearance.applyAppearanceWhenAttached()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(tabs.delegate === nativeDelegate)
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

@MainActor
private final class NativeTabDelegate: NSObject, UITabBarControllerDelegate {}
