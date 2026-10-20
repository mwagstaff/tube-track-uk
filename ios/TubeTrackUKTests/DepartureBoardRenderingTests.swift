import SwiftUI
import XCTest
@testable import TubeTrackUK

@MainActor final class DepartureBoardRenderingTests: XCTestCase {
    func testBoardsAtPhoneLandscapeAndAccessibilitySizes() async throws {
        let suite = "departure-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DepartureRenderProtocol.self]
        let client = TubeTrackAPIClient(configuration: .init(baseURL: URL(string: "https://departure.test")!),
                                        session: URLSession(configuration: config))
        let app = TubeAppState(defaults: defaults, apiClient: client, monitorsConnectivity: false)
        let request = DepartureBoardRequest(originID: "nr:KTH", destinationIDs: ["910GBROMLYS"])
        var favourite = DepartureFavourite(name: "Work commute", outbound: request)
        favourite.manualOriginID = request.originID
        app.departureBoards.save(favourite)
        await app.departureBoards.refresh(request)
        await app.departureBoards.refresh(.init(originID: request.originID, lineIDs: ["national-rail:SE"]))
        for direction in ["Northbound", "Southbound"] {
            await app.departureBoards.refresh(.init(originID: request.originID, destinationIDs: request.destinationIDs,
                                                    lineIDs: ["national-rail:SE"], direction: direction))
        }
        XCTAssertEqual(app.departureBoards.boards[request]?.arrivals.count, 12)
        let activity = StationBoardActivityController()
        for (name, width, scheme, size) in [("light", 390.0, ColorScheme.light, DynamicTypeSize.large),
                                           ("landscape", 780.0, .dark, .large),
                                           ("accessibility", 390.0, .dark, .accessibility3),
                                           ("offline", 390.0, .light, .large)] {
            app.setNetworkAvailable(name != "offline")
            let view = DepartureBoardCard(initialRequest: request, favouriteID: favourite.id, isVisible: false)
                .environment(app).environment(UserLocationProvider()).environment(activity)
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
                .frame(width: width)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 300)
            let attachment = XCTAttachment(image: image)
            attachment.name = "departure-board-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/tubetrack-departure-board-\(name).png"))

            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let sheet = DepartureBoardCard(initialRequest: request, favouriteID: favourite.id, isVisible: false, presentedAsSheet: true)
                .environment(app).environment(UserLocationProvider()).environment(activity)
                .environment(\.scenePhase, .inactive)
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: sheet)
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: width, height: name == "landscape" ? 390 : 844)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(200))
            host.view.layoutIfNeeded()
            let sheetImage = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let sheetAttachment = XCTAttachment(image: sheetImage)
            sheetAttachment.name = "departure-sheet-\(name)"; sheetAttachment.lifetime = .keepAlways; add(sheetAttachment)
            try sheetImage.pngData()?.write(to: URL(fileURLWithPath: "/tmp/tubetrack-departure-sheet-\(name).png"))
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()

        }
    }
}

private final class DepartureRenderProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let now = Date.now
        let rows: [[String: Any]] = (1...12).map { index in
            ["id": "train-\(index)", "lineId": "national-rail:SE", "operatorName": "Southeastern",
             "destinationName": index.isMultiple(of: 2) ? "Orpington" : "London Victoria",
             "direction": index.isMultiple(of: 2) ? "southbound" : "northbound", "platformName": "Platform 4",
             "expectedArrival": now.addingTimeInterval(Double(index * 180)).ISO8601Format(),
             "status": index == 3 ? "cancelled" : "onTime"]
        }
        let direction = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "direction" }?.value
        let selectedRows = direction.map { direction in rows.filter { ($0["direction"] as? String)?.lowercased() == direction.lowercased() } } ?? rows
        let data = try! JSONSerialization.data(withJSONObject: ["data": [
            "arrivals": selectedRows, "updatedAt": now.ISO8601Format(), "unavailableSources": 0,
            "unverifiedCount": 1, "stale": false
        ]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
