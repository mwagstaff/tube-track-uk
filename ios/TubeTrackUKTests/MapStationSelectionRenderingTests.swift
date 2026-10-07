import SwiftUI
import XCTest
@testable import TubeTrackUK

@MainActor
final class MapStationSelectionRenderingTests: XCTestCase {
    func testInterchangeSelectionInTheMapCanvas() async throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let defaultsName = "MapStationSelectionRendering.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        let location = UserLocationProvider()
        state.selectedTab = .nearMe
        state.graph = graph
        var windows: [UIWindow] = []
        defer {
            for window in windows {
                window.isHidden = true
                window.rootViewController = nil
            }
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let cases: [(BeckMapRegion, String)] = [
            (.londonRailAndTube, "910GBLFR"),
            (.londonRailAndTube, "940GZZLUBND"),
            (.londonRailAndTube, "910GNWCRELL"),
            (.londonRailAndTube, "940GZZLUBLG"),
            (.londonRailAndTube, "940GZZLUKPK"),
            (.londonRailAndTube, "910GKNTSHTW"),
            (.londonRailAndTube, "910GLEYTNMR"),
            (.fullUnderground, "940GZZLUBND")
        ]
        for (region, stationID) in cases {
            let document = try BeckMapRepository().load(region: region, graph: graph)
            let presentation = BeckMapPresentationSnapshot(
                selectedLineID: nil, selectedStationID: stationID,
                affectedSegmentIDs: [], affectedStationIDs: [],
                disruptionDisplayMode: .normal, networkFilter: nil,
                networkFeaturedLineIDs: [], networkFeaturedSegmentIDs: [],
                networkSectionLineIDs: [], closedLineIDs: [], mobileCoverageMode: .off,
                mobileCoverageBySegmentID: [:], mobileCoverageByStationID: [:],
                stationOnlyCoverageStationIDs: [],
                selectedStationHubIDs: BeckMapStationSelection.stationIDs(for: stationID, in: graph)
            )
            for scheme in [ColorScheme.light, .dark] {
                state.sharedMapViewport = nil
                let size = CGSize(width: 390, height: 500)
                let view = BeckMapCanvas(
                    document: document, renderCache: .init(document: document),
                    presentation: presentation, disruptionIDsBySegmentID: [:], liveTrains: [],
                    referenceOverlayVisible: false, resetToken: 0, locationFocusRequest: nil,
                    contentVerticalBias: 0, onUserZoomIn: {}, onInteractionChange: { _ in },
                    stationSelectionGeneration: 0, onStationTap: { _, _, _ in },
                    onDisruptionTap: { _ in }, onBackgroundTap: {}
                )
                .frame(width: size.width, height: size.height)
                .environment(state)
                .environment(location)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, scheme == .dark ? .accessibility3 : .large)
                let host = UIHostingController(rootView: view.ignoresSafeArea())
                let window = UIWindow(windowScene: scene)
                windows.append(window)
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(900))
                let image = UIGraphicsImageRenderer(size: size).image { _ in
                    XCTAssertTrue(host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "station-selection-\(document.identifier)-\(stationID)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }
}
