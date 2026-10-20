import Foundation
import SwiftUI
import XCTest
@testable import TubeTrackCore
@testable import TubeTrackUK

private let callingPointsJSON = #"{"locationName":"London Blackfriars","crs":"BFR","std":"23:58","etd":"On time","subsequentCallingPoints":[{"callingPoint":[{"locationName":"London Bridge","crs":"LBG","st":"00:04","et":"00:07"},{"locationName":"East Croydon","crs":"ECR","st":"00:22","at":"00:24"},{"locationName":"Gatwick Airport","crs":"GTW","st":"00:38","isCancelled":true}],"serviceChangeRequired":false},{"callingPoint":[{"locationName":"Brighton","crs":"BTN","st":"01:05"}],"serviceChangeRequired":true,"assocIsCancelled":true}]}"#

private final class CallingPointsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let valid = url.absoluteString.contains("/api/v2/service_details/train%2F1:2?fromCRS=BFR")
        let body = "[{\"train/1:2\":\(callingPointsJSON)}]"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: valid ? 200 : 400,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class RailCallingPointsTests: XCTestCase {
    private func arrival(id: String = "national-rail:BFR:train/1:2", line: String = "thameslink") -> TfLArrivalPrediction {
        .init(id: id, vehicleId: nil, lineId: line, stationName: "Blackfriars", naptanId: "BFR",
              platformName: "Platform 1", direction: "southbound", destinationName: "Brighton",
              destinationNaptanId: "BTN", towards: nil, expectedArrival: nil, timeToStation: nil, currentLocation: nil)
    }

    func testFetchUsesExactServiceAndEncodesOpaqueID() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CallingPointsProtocol.self]
        let client = TubeTrackAPIClient(configuration: .init(baseURL: URL(string: "https://example.com/train-track")!),
                                       session: URLSession(configuration: config), installationID: "calling-points-test")
        let details = try await RailCallingPointsService(client: client).fetch(for: arrival())
        XCTAssertEqual(details.crs, "BFR")
        XCTAssertEqual(details.subsequentCallingPoints?.first?.callingPoint.count, 3)
    }

    func testEligibilityAndStableSelection() {
        XCTAssertTrue(arrival().supportsCallingPoints)
        XCTAssertTrue(arrival(line: "national-rail:SE").supportsCallingPoints)
        XCTAssertFalse(arrival(line: "northern").supportsCallingPoints)
        XCTAssertEqual(arrival().railServiceReference?.serviceID, "train/1:2")
        XCTAssertNil(arrival(id: "national-rail:BFR:").railServiceReference)
    }

    func testTimesAndDividingServiceRemainDistinct() throws {
        let details = try JSONDecoder().decode(RailCallingPoints.self, from: Data(callingPointsJSON.utf8))
        XCTAssertEqual(details.boardingPoint.timing, "23:58 · On time")
        let points = try XCTUnwrap(details.subsequentCallingPoints?.first?.callingPoint)
        XCTAssertEqual(points[0].timing, "00:04 · Expected 00:07")
        XCTAssertEqual(points[1].timing, "00:22 · Actual 00:24")
        XCTAssertEqual(points[2].timing, "00:38 · Cancelled")
        XCTAssertEqual(details.subsequentCallingPoints?.last?.serviceChangeRequired, true)
        XCTAssertEqual(details.subsequentCallingPoints?.last?.callingPoint.first?.timing, "01:05 · Live time unavailable")
    }

    func testThameslinkMatchRequiresOperatorTimeAndDestination() throws {
        let row = try JSONDecoder().decode(NationalRailDeparture.self, from: Data(#"{"serviceID":"exact","operatorCode":"TL","departure_time":{"scheduled":"23:58"},"destination":{"crs":"BTN","locationName":"Brighton"}}"#.utf8))
        let date = ISO8601DateFormatter().date(from: "2026-10-17T22:58:00Z")!
        XCTAssertTrue(RailCallingPointsService.matches(row, arrival: arrival(), scheduled: date, reference: date))
        XCTAssertFalse(RailCallingPointsService.matches(row, arrival: arrival(), scheduled: date.addingTimeInterval(60), reference: date))
    }

    func testCallingPointsLayoutLightDarkAndLargeText() async throws {
        let details = try JSONDecoder().decode(RailCallingPoints.self, from: Data(callingPointsJSON.utf8))
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                     ("dark", .dark, .large), ("large-text", .dark, .accessibility3)] {
            let controller = UIHostingController(rootView: RailCallingPointsList(arrival: arrival(), details: details)
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(250))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "calling-points-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }
}
