import Foundation
import Testing
@testable import TubeTrackUK

struct CompactStationDeparturePolicyTests {
    @Test func twoDirectionsShowTwoDeparturesEachWithinSixInformationLines() {
        let arrivals = [
            arrival(id: "in-1", direction: "inbound", seconds: 60),
            arrival(id: "in-2", direction: "inbound", seconds: 120),
            arrival(id: "in-3", direction: "inbound", seconds: 180),
            arrival(id: "out-1", direction: "outbound", seconds: 90),
            arrival(id: "out-2", direction: "outbound", seconds: 150),
            arrival(id: "out-3", direction: "outbound", seconds: 210),
        ]

        let groups = CompactStationDeparturePolicy.groups(
            from: arrivals,
            for: .windrush
        )

        #expect(groups.map(\.direction) == ["Inbound", "Outbound"])
        #expect(groups.map(\.arrivals.count) == [2, 2])
        #expect(informationLineCount(groups) == 6)
    }

    @Test func threeDirectionsShareTheSixLineBudget() {
        let arrivals = [
            arrival(id: "north-1", direction: "northbound", seconds: 60),
            arrival(id: "north-2", direction: "northbound", seconds: 120),
            arrival(id: "south-1", direction: "southbound", seconds: 90),
            arrival(id: "south-2", direction: "southbound", seconds: 150),
            arrival(id: "all-1", direction: nil, seconds: 180),
            arrival(id: "all-2", direction: nil, seconds: 240),
        ]

        let groups = CompactStationDeparturePolicy.groups(
            from: arrivals,
            for: .windrush
        )

        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.arrivals.count == 1 })
        #expect(informationLineCount(groups) == 6)
    }

    @Test func selectedLineExcludesDeparturesFromOtherLines() {
        let groups = CompactStationDeparturePolicy.groups(
            from: [
                arrival(id: "windrush", lineID: .windrush, direction: "inbound", seconds: 60),
                arrival(id: "mildmay", lineID: .mildmay, direction: "inbound", seconds: 90),
            ],
            for: .windrush
        )

        #expect(groups.count == 1)
        #expect(groups.first?.lineID == .windrush)
        #expect(groups.first?.arrivals.map(\.id) == ["windrush"])
    }

    private func informationLineCount(_ groups: [StationDepartureGroup]) -> Int {
        groups.reduce(0) { $0 + 1 + $1.arrivals.count }
    }

    private func arrival(
        id: String,
        lineID: TubeLineID = .windrush,
        direction: String?,
        seconds: Int
    ) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: id,
            vehicleId: id,
            lineId: lineID.rawValue,
            stationName: "Sydenham",
            naptanId: "sydenham",
            platformName: nil,
            direction: direction,
            destinationName: direction == "outbound" ? "West Croydon" : "Dalston Junction",
            destinationNaptanId: nil,
            towards: nil,
            expectedArrival: Date(timeIntervalSince1970: 1_000 + Double(seconds)),
            timeToStation: seconds,
            currentLocation: nil
        )
    }
}
