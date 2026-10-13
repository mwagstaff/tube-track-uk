import SwiftUI
import TubeTrackCore
import XCTest
@testable import TubeTrackUK

@MainActor final class CombinedJourneyRenderingTests: XCTestCase {
    func testScheduleEditorAndJourneysAtStandardAndAccessibilitySizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousWindow?.makeKey() }
        let suite = "schedule-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        let hub = try XCTUnwrap(StationIndex.bundled.hub(containing: "940GZZLUOXC"))
        var filteredBoard = ScheduledBoard(hub: hub, line: .central, direction: .eastbound)
        filteredBoard.destinationIDs = ["HUBBAN", "HUBTCR"]
        let draft = ScheduledJourney.suggested(outbound: filteredBoard)
        var saved = draft
        saved.id = "existing-journey"
        saved.name = "Existing commute"
        let cache: [String: Any] = ["journeys": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))],
                                  "revision": 1, "maximumJourneys": 3]
        defaults.set(try JSONSerialization.data(withJSONObject: cache), forKey: "scheduledJourneys.cache.\(AppInstall.identifier)")
        let store = ScheduledJourneyStore(defaults: defaults,
            baseURL: URL(string: "http://127.0.0.1:1")!, observesTokens: false)
        XCTAssertEqual(store.journeys, [saved])
        XCTAssertEqual(draft.conflictingJourneys(in: store.journeys), [saved])
        let railStation = try XCTUnwrap(ScheduledBoard.railStation(id: "nr:KTH"))
        let railDraft = ScheduledJourney.suggested(outbound: ScheduledBoard(station: railStation,
            operatorID: "national-rail:SE", operatorName: "Southeastern", direction: .northbound))
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                     ("dark", .dark, .large), ("accessibility", .dark, .accessibility3)] {
            for variant in ["journeys", "editor", "rail"] {
                let content = Group {
                    if variant != "journeys" {
                        NavigationStack { ScheduledJourneyEditor(journey: variant == "rail" ? railDraft : draft) }
                    } else { JourneysScreen() }
                }.environment(app).environment(store)
                    .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
                let host = UIHostingController(rootView: content)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = host
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(300))
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                XCTAssertGreaterThan(image.size.height, 800)
                let attachment = XCTAttachment(image: image)
                attachment.name = "schedule-\(variant)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(attachment.name).png"))
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }

    func testMixedJourneyDetailAtStandardAndAccessibilitySizes() async throws {
        let journey = try JSONDecoder.tfl.decode(PlannedJourney.self, from: Data(Self.fixture.utf8))
        let suite = "combined-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                     ("dark", .dark, .large), ("accessibility", .dark, .accessibility3)] {
            let view = NavigationStack {
                JourneyDetailScreen(journey: journey, expiresAt: .distantPast)
            }.environment(app).environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(image.size.height, 800)
            let attachment = XCTAttachment(image: image)
            attachment.name = "combined-journey-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/tubetrack-combined-journey-\(name).png"))
            window.isHidden = true; window.rootViewController = nil
        }
        previousWindow?.makeKey()
    }

    private static let fixture = #"""
    {"id": "ad4121c6891f7bc91329", "departureTime": "2026-09-16T14:22:00.000Z", "arrivalTime": "2026-09-16T15:00:00.000Z", "durationMinutes": 38, "changes": 1, "walkingMinutes": 0, "disruptionScore": 0, "warnings": [], "legs": [{"id": "0", "mode": "national-rail", "instruction": "Take Southeastern to London Victoria", "from": {"id": "nr:KTH", "name": "Kent House", "platform": "2"}, "to": {"id": "HUBVIC", "name": "London Victoria"}, "lines": [{"id": "southeastern", "name": "Southeastern", "direction": "London Victoria", "colour": "#1D2452", "operatorCode": "SE"}], "departureTime": "2026-09-16T14:22:00.000Z", "arrivalTime": "2026-09-16T14:45:00.000Z", "scheduledDepartureTime": "2026-09-16T14:22:00.000Z", "scheduledArrivalTime": "2026-09-16T14:45:00.000Z", "timing": "scheduled", "durationMinutes": 23, "warnings": [], "stops": []}, {"id": "1", "mode": "tube", "instruction": "Take the Victoria line to Oxford Circus", "from": {"id": "HUBVIC", "name": "Victoria"}, "to": {"id": "940GZZLUOXC", "name": "Oxford Circus"}, "lines": [{"id": "victoria", "name": "Victoria", "direction": "Walthamstow Central"}], "departureTime": "2026-09-16T14:52:00.000Z", "arrivalTime": "2026-09-16T15:00:00.000Z", "scheduledDepartureTime": null, "scheduledArrivalTime": null, "timing": "estimated", "durationMinutes": 8, "warnings": [], "stops": []}], "labels": ["earliestArrival"], "waitingMinutes": 6}
    """#
}
