import CoreLocation
import Testing
@testable import TubeTrackUK

struct NearMeTests {
    @Test func nearestStationsAreDeduplicatedAndSortedByDistance() {
        let origin = CLLocation(latitude: 51.5000, longitude: -0.1000)
        let stations = [
            station(id: "far", name: "Far", latitude: 51.5400, hubID: nil),
            station(id: "near-central", name: "Near", latitude: 51.5010, hubID: "near-hub"),
            station(id: "near-district", name: "Near", latitude: 51.5011, hubID: "near-hub"),
            station(id: "middle", name: "Middle", latitude: 51.5100, hubID: nil),
            station(id: "third", name: "Third", latitude: 51.5200, hubID: nil),
        ]

        let nearest = NearbyStationFinder.nearestStations(to: origin, in: stations)
        let allByDistance = NearbyStationFinder.stationsByDistance(to: origin, in: stations)

        #expect(nearest.map(\.station.id) == ["near-central", "middle", "third"])
        #expect(nearest.count == 3)
        #expect(allByDistance.map(\.station.id) == ["near-central", "middle", "third", "far"])
        #expect(nearest[0].distance < nearest[1].distance)
        #expect(nearest[1].distance < nearest[2].distance)
    }

    @Test func statusConditionsDistinguishMinorAndMajorDisruptions() {
        #expect(LineServiceCondition.condition(for: lineStatus(severity: 10, description: "Good Service")) == .good("Good Service"))
        #expect(LineServiceCondition.condition(for: lineStatus(severity: 9, description: "Minor Delays")) == .minorDisruption("Minor Delays"))
        #expect(LineServiceCondition.condition(for: lineStatus(severity: 6, description: "Severe Delays")) == .majorDisruption("Severe Delays"))
        #expect(LineServiceCondition.condition(for: lineStatus(severity: 5, description: "Part Closure")) == .majorDisruption("Part Closure"))
        #expect(LineServiceCondition.condition(for: nil) == .updating)
    }

    @Test func departuresGroupByLineAndDirectionAndSortSoonestFirst() throws {
        let arrivals = [
            arrival(id: "later", line: .district, platform: "Eastbound - Platform 2", seconds: 300),
            arrival(id: "soon", line: .district, platform: "Eastbound - Platform 2", seconds: 60),
            arrival(id: "west", line: .district, platform: "Westbound - Platform 1", seconds: 120),
            arrival(id: "piccadilly", line: .piccadilly, platform: nil, direction: "inbound", seconds: 90),
        ]

        let groups = NearbyDepartureGroup.groups(from: arrivals)
        let eastbound = try #require(groups.first {
            $0.lineID == .district && $0.direction == "Eastbound"
        })

        #expect(groups.count == 3)
        #expect(eastbound.arrivals.map(\.id) == ["soon", "later"])
        #expect(groups.contains { $0.lineID == .district && $0.direction == "Westbound" })
        #expect(groups.contains { $0.lineID == .piccadilly && $0.direction == "Inbound" })
    }

    private func station(
        id: String,
        name: String,
        latitude: Double,
        hubID: String?
    ) -> TubeStation {
        TubeStation(
            id: id,
            name: name,
            latitude: latitude,
            longitude: -0.1000,
            schematicX: 0,
            schematicY: 0,
            lineIDs: [.district],
            interchange: hubID != nil,
            searchAliases: [],
            hubID: hubID
        )
    }

    private func lineStatus(severity: Int, description: String) -> TfLLineStatus {
        TfLLineStatus(
            id: .district,
            name: "District",
            lineStatuses: [TfLStatusEntry(
                id: severity,
                statusSeverity: severity,
                statusSeverityDescription: description,
                reason: nil,
                validityPeriods: nil,
                disruption: nil
            )]
        )
    }

    private func arrival(
        id: String,
        line: TubeLineID,
        platform: String?,
        direction: String? = nil,
        seconds: Int
    ) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: id,
            vehicleId: id,
            lineId: line.rawValue,
            stationName: "Test",
            naptanId: "test",
            platformName: platform,
            direction: direction,
            destinationName: "Destination",
            destinationNaptanId: nil,
            towards: nil,
            expectedArrival: nil,
            timeToStation: seconds,
            currentLocation: nil
        )
    }
}
