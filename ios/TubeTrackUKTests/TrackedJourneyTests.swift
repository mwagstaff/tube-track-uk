import CoreLocation
import SwiftUI
import Testing
import TubeTrackCore
import XCTest
@testable import TubeTrackUK

@MainActor struct TrackedJourneyTests {
    @Test func viaRequestPreservesOrderAndAccessibility() {
        let request = JourneyRequest(from: "nr:CLK", to: "HUBSRA", timeMode: .now, time: .now,
            accessibility: .platform, via: ["HUBLEW", "HUBCAW"])
        let query = Dictionary(uniqueKeysWithValues: request.queryItems.map { ($0.name, $0.value ?? "") })
        #expect(query["via"] == "HUBLEW,HUBCAW")
        #expect(query["accessibility"] == "platform")
    }
    @Test func poorOrStaleLocationsNeverMoveJourneyProgress() {
        let now = Date.now
        let coordinate = CLLocationCoordinate2D(latitude: 51.464665, longitude: -0.012874)
        let stale = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: now.addingTimeInterval(-120))
        let coarse = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 1000, verticalAccuracy: 10, timestamp: now)
        #expect(!JourneyProgressEvidence.usable(stale, now: now))
        #expect(!JourneyProgressEvidence.usable(coarse, now: now))
    }
    @Test func departureNeedsSustainedMovementTowardsNextStop() {
        let from = CLLocation(latitude: 51.464665, longitude: -0.012874)
        let to = CLLocation(latitude: 51.506203, longitude: -0.018834)
        let start = CLLocation(coordinate: from.coordinate, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, course: 0, speed: 0, timestamp: .now.addingTimeInterval(-60))
        let moving = CLLocation(coordinate: .init(latitude: 51.468, longitude: -0.013), altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, course: 0, speed: 8, timestamp: .now)
        #expect(JourneyProgressEvidence.departed(start: start, current: moving, origin: from, destination: to))
        let opposite = CLLocation(coordinate: .init(latitude: 51.46, longitude: -0.013), altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, course: 180, speed: 8, timestamp: .now)
        #expect(!JourneyProgressEvidence.departed(start: start, current: opposite, origin: from, destination: to))
    }
    @Test func selectedRouteSurvivesPersistenceWithServiceIdentity() throws {
        let plan = TrackedJourneyFixture.plan
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(plan)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(PlannedJourney.self, from: data)
        #expect(restored.legs[0].serviceID == "rail-service")
        #expect(restored.legs[0].trackingBoard?.lineIDs == ["national-rail:SE"])
        #expect(restored.legs[1].trackingBoard?.destinationIDs == ["HUBCAW"])
    }
}

@MainActor enum TrackedJourneyFixture {
    static var plan: PlannedJourney {
        let endpoints = [("nr:CLK", "Clock House"), ("HUBLEW", "Lewisham"), ("HUBCAW", "Canary Wharf"), ("HUBSRA", "Stratford")]
        var legs: [JourneyLeg] = []
        for i in 0..<3 {
            let from = JourneyPoint(id: endpoints[i].0, name: endpoints[i].1, platform: nil)
            let to = JourneyPoint(id: endpoints[i + 1].0, name: endpoints[i + 1].1, platform: nil)
            let line = JourneyLine(id: i == 0 ? "southeastern" : "dlr", name: i == 0 ? "Southeastern" : "DLR", direction: to.name, operatorCode: i == 0 ? "SE" : nil)
            let departure = Date.now.addingTimeInterval(Double(i) * 1200)
            let leg = JourneyLeg(id: String(i), mode: i == 0 ? "national-rail" : "dlr", instruction: "Travel to " + to.name,
                from: from, to: to, lines: [line], departureTime: departure, arrivalTime: departure.addingTimeInterval(900),
                scheduledDepartureTime: nil, scheduledArrivalTime: nil, timing: "estimated", durationMinutes: 15,
                warnings: [], stops: [], serviceID: i == 0 ? "rail-service" : nil)
            legs.append(leg)
        }
        return .init(id: "route", departureTime: .now, arrivalTime: .now.addingTimeInterval(3600), durationMinutes: 60,
            changes: 2, walkingMinutes: 0, waitingMinutes: 0, warnings: [], legs: legs, labels: [])
    }
    static func store(_ defaults: UserDefaults) throws -> TrackedJourneyStore {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let now = Int(Date.now.timeIntervalSince1970)
        let state: [String: Any] = ["phase": "onboard", "legIndex": 1, "headline": "Towards Canary Wharf", "nextStop": "Canary Wharf",
            "destination": "Stratford", "nextArrivalEpoch": now + 420, "finalArrivalEpoch": now + 1500,
            "boardTitle": "Canary Wharf → Stratford", "departures": [], "updatedAtEpoch": now, "staleAtEpoch": now + 90,
            "message": "Arrival times are estimates; confirm your progress if location is unavailable.", "sequence": 1]
        let board: [String: Any] = ["arrivals": [["id": "dlr-train", "lineId": "dlr", "destinationName": "Stratford", "platformName": "Platform 3", "expectedArrival": Date.now.addingTimeInterval(600).ISO8601Format()]], "updatedAt": Date.now.ISO8601Format(), "unavailableSources": 0, "unverifiedCount": 0, "stale": false]
        let active: [String: Any] = ["id": UUID().uuidString, "plan": try JSONSerialization.jsonObject(with: encoder.encode(plan)),
            "legIndex": 1, "phase": "onboard", "revision": 1, "startedAt": Date.now.ISO8601Format(),
            "endsAt": Date.now.addingTimeInterval(3600).ISO8601Format(), "state": state, "boards": ["2": board]]
        let response: [String: Any] = ["active": active, "schedules": [], "revision": 1]
        defaults.set(try JSONSerialization.data(withJSONObject: response), forKey: "trackedRoutes.v1.\(AppInstall.identifier)")
        return TrackedJourneyStore(defaults: defaults, baseURL: URL(string: "http://127.0.0.1:1")!)
    }
}

@MainActor final class TrackedJourneyRenderingTests: XCTestCase {
    func testJourneyAtLightDarkAndAccessibilitySizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousWindow?.makeKey() }
        let suite = "tracked-render-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try TrackedJourneyFixture.store(defaults)
        XCTAssertEqual(store.active?.boardIndex, 2)
        let app = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large), ("dark", .dark, .large), ("accessibility", .dark, .accessibility3)] {
            let view = JourneyTrackingScreen().environment(store).environment(app).environment(UserLocationProvider())
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene); window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844); window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "tracked-journey-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/tracked-journey-\(name).png"))
            window.isHidden = true; window.rootViewController = nil
        }
    }
}
