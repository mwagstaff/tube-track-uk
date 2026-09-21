import Foundation
import Testing
@testable import TubeTrackCore

struct DepartureTimelineTests {
    private let producedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func arrival(_ id: String, expected: TimeInterval?, seconds: Int?) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: id, vehicleId: nil, lineId: "central", stationName: nil, naptanId: nil,
            platformName: "Eastbound - Platform 2", direction: nil, destinationName: "Epping",
            destinationNaptanId: nil, towards: nil,
            expectedArrival: expected.map { producedAt.addingTimeInterval($0) },
            timeToStation: seconds, currentLocation: nil
        )
    }

    @Test func anchoringPinsCountdownOnlyPredictionsToTheServerClock() {
        let anchored = DepartureTimeline.anchored(
            [arrival("a", expected: nil, seconds: 120), arrival("b", expected: 300, seconds: 300), arrival("c", expected: nil, seconds: nil)],
            producedAt: producedAt
        )
        #expect(anchored[0].expectedArrival == producedAt.addingTimeInterval(120))
        #expect(anchored[1].expectedArrival == producedAt.addingTimeInterval(300))
        #expect(anchored[2].expectedArrival == nil)
    }

    @Test func departedTrainsDropOffAfterTheGracePeriod() {
        let arrivals = DepartureTimeline.anchored(
            [arrival("a", expected: nil, seconds: 60), arrival("b", expected: nil, seconds: 180), arrival("c", expected: nil, seconds: nil)],
            producedAt: producedAt
        )
        let atStart = DepartureTimeline.stillAhead(arrivals, at: producedAt)
        #expect(atStart.map(\.id) == ["a", "b", "c"])

        let twoMinutesOn = DepartureTimeline.stillAhead(arrivals, at: producedAt.addingTimeInterval(120))
        #expect(twoMinutesOn.map(\.id) == ["b", "c"], "a departed 60 s ago, past the 30 s grace")

        let justDeparted = DepartureTimeline.stillAhead(arrivals, at: producedAt.addingTimeInterval(80))
        #expect(justDeparted.map(\.id) == ["a", "b", "c"], "a is 20 s past due and still shows as Due")
    }

    @Test func staleServerDataYieldsNoDeparturesLater() {
        let arrivals = DepartureTimeline.anchored([arrival("a", expected: nil, seconds: 0)], producedAt: producedAt)
        #expect(DepartureTimeline.stillAhead(arrivals, at: producedAt.addingTimeInterval(6 * 3600)).isEmpty)
    }

    @Test func labelsTickAgainstEachEntryDate() {
        let arrivals = DepartureTimeline.anchored([arrival("a", expected: nil, seconds: 200)], producedAt: producedAt)
        #expect(StationDepartureMetadata.departureTime(for: arrivals[0], now: producedAt) == "3 min")
        #expect(StationDepartureMetadata.departureTime(for: arrivals[0], now: producedAt.addingTimeInterval(120)) == "1 min")
        #expect(StationDepartureMetadata.departureTime(for: arrivals[0], now: producedAt.addingTimeInterval(170)) == "Due")
    }
}
