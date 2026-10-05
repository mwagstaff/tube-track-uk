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
            departure("3", destination: "Bromley South", minutes: 18, status: .delayed, now: now)
        ]
        let group = try XCTUnwrap(NationalRailDepartureGroup.groups(from: arrivals).first)
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                     ("dark", .dark, .large), ("accessibility", .dark, .accessibility3)] {
            let view = VStack(alignment: .leading, spacing: 16) {
                Text("Beckenham Junction").font(.appHeadline())
                NationalRailOperatorPill(name: group.name, id: group.id, selected: true) {}
                Divider()
                NationalRailDepartureGroupView(group: group, now: now)
            }
            .padding(20)
            .frame(width: 390)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, size)
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

    private func departure(_ id: String, destination: String, minutes: Int,
                           status: RailServiceStatus, now: Date) -> TfLArrivalPrediction {
        TfLArrivalPrediction(id: id, vehicleId: nil, lineId: "national-rail:SE", stationName: nil,
            naptanId: "BKJ", platformName: "Platform 2", direction: nil,
            destinationName: destination, destinationNaptanId: nil, towards: nil,
            expectedArrival: now.addingTimeInterval(Double(minutes * 60)), timeToStation: minutes * 60,
            currentLocation: nil, scheduledDeparture: now.addingTimeInterval(Double((minutes - (status == .delayed ? 2 : 0)) * 60)),
            serviceStatus: status, operatorName: "Southeastern")
    }
}
