import SwiftUI
import XCTest
@testable import TubeTrackUK

@MainActor
final class NationalRailDepartureRenderingTests: XCTestCase {
    func testOperatorBoardsInLightDarkAndAccessibilityText() throws {
        let now = Date.now
        let arrivals = [
            departure("1", destination: "London Victoria", minutes: 4, status: .onTime, now: now),
            departure("2", destination: "Orpington", minutes: 12, status: .cancelled, now: now),
            departure("3", destination: "Bromley South", minutes: 18, status: .delayed, now: now),
            departure("4", destination: "Sevenoaks", minutes: 22, status: .unknown, now: now)
        ]
        let group = try XCTUnwrap(NationalRailDepartureGroup.groups(from: arrivals).first)
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                     ("dark", .dark, .large), ("accessibility", .dark, .accessibility3)] {
            let view = VStack(alignment: .leading, spacing: 16) {
                Text("Beckenham Junction").font(.appHeadline())
                NationalRailOperatorPill(name: group.name, id: group.id, selected: true) {}
                Divider()
                Text("Thameslink").font(.appHeadline())
                ForEach(arrivals, id: \.id) { arrival in
                    StationDepartureRow(arrival: TfLArrivalPrediction(
                        id: "thameslink-" + arrival.id, vehicleId: nil, lineId: "thameslink",
                        stationName: nil, naptanId: "ZFD", platformName: "Platform 2",
                        direction: "southbound", destinationName: arrival.destinationName,
                        destinationNaptanId: nil, towards: nil, expectedArrival: arrival.expectedArrival,
                        timeToStation: arrival.timeToStation, currentLocation: nil,
                        scheduledDeparture: arrival.scheduledDeparture, serviceStatus: arrival.serviceStatus), now: now)
                }
                Divider()
                ForEach(group.directionGroups) { directionGroup in
                    NationalRailDepartureGroupView(group: directionGroup, now: now,
                        tracking: .init(hubID: "HUBBEK", stationName: "Beckenham Junction", updatedAt: now))
                }
            }
            .padding(20)
            .frame(width: 390)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, size)
            .environment(StationBoardActivityController())
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 200)
            let attachment = XCTAttachment(image: image)
            attachment.name = "national-rail-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testUnflaggedDeparturesArePresentedAsOnTime() {
        XCTAssertEqual(RailServiceStatus.unknown.departureAccessibilityLabel, "On time")
        XCTAssertEqual(RailServiceStatus.onTime.departureAccessibilityLabel, "On time")
        XCTAssertEqual(RailServiceStatus.delayed.departureAccessibilityLabel, "Delayed")
        XCTAssertEqual(RailServiceStatus.cancelled.departureAccessibilityLabel, "Cancelled")
    }

    func testLiveActivityPreservesUnknownStatusAndReadsLegacyNormalTrains() throws {
        typealias Departure = DepartureActivityAttributes.ContentState.Departure
        for status in [RailServiceStatus.onTime, .delayed, .cancelled, .unknown] {
            let departure = Departure(id: "train", destination: "London", platform: nil,
                expectedAt: .now, status: status)
            let decoded = try JSONDecoder().decode(Departure.self, from: JSONEncoder().encode(departure))
            XCTAssertEqual(decoded.railServiceStatus, status)
        }
        let legacy = Departure(id: "legacy", destination: "London", platform: nil, expectedAt: .now)
        XCTAssertEqual(legacy.railServiceStatus, .onTime)
        let unconfirmed = Departure(id: "unknown", destination: "London", platform: nil,
            expectedAt: .now, hasExpectedTime: false)
        XCTAssertEqual(unconfirmed.railServiceStatus, .unknown)
    }

    private func departure(_ id: String, destination: String, minutes: Int,
                           status: RailServiceStatus, now: Date) -> TfLArrivalPrediction {
        TfLArrivalPrediction(id: id, vehicleId: nil, lineId: "national-rail:SE", stationName: nil,
            naptanId: "BKJ", platformName: "Platform 2", direction: destination == "London Victoria" ? "northbound" : "southbound",
            destinationName: destination, destinationNaptanId: nil, towards: nil,
            expectedArrival: now.addingTimeInterval(Double(minutes * 60)), timeToStation: minutes * 60,
            currentLocation: nil, scheduledDeparture: now.addingTimeInterval(Double((minutes - (status == .delayed ? 2 : 0)) * 60)),
            serviceStatus: status, operatorName: "Southeastern")
    }
}
