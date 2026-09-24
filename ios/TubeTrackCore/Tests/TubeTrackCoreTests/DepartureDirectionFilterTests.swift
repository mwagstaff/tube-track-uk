import Foundation
import Testing
@testable import TubeTrackCore

struct DepartureDirectionFilterTests {
    /// Shared with the server's board projection test. Any change here must be
    /// mirrored in the API's push board fixtures, or the server will push a
    /// board the client filters differently.
    static let platformFixtures: [(line: TubeLineID, platform: String?, direction: String?, expected: String)] = [
        (.victoria, "Northbound - Platform 3", nil, "Northbound"),
        (.victoria, "Southbound - Platform 4", nil, "Southbound"),
        (.central, "Eastbound - Platform 2", nil, "Eastbound"),
        (.central, "Westbound - Platform 1", nil, "Westbound"),
        (.elizabeth, nil, "inbound", "Eastbound"),
        (.elizabeth, nil, "outbound", "Westbound"),
        (.circle, nil, "inbound", "Inbound"),
        (.dlr, nil, nil, "All directions"),
    ]

    private func arrival(line: TubeLineID, platform: String?, direction: String?) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: UUID().uuidString, vehicleId: nil, lineId: line.rawValue, stationName: nil,
            naptanId: nil, platformName: platform, direction: direction,
            destinationName: "Somewhere", destinationNaptanId: nil, towards: nil,
            expectedArrival: Date(timeIntervalSince1970: 1_800_000_120), timeToStation: 120, currentLocation: nil
        )
    }

    @Test func directionLabelsMatchTheFiltersTheyWereDerivedFrom() {
        for fixture in Self.platformFixtures {
            let prediction = arrival(line: fixture.line, platform: fixture.platform, direction: fixture.direction)
            let label = StationDepartureMetadata.directionLabel(for: prediction)
            #expect(label == fixture.expected, "\(fixture.platform ?? fixture.direction ?? "nil")")

            let filter = DepartureDirectionFilter.allCases.first { $0 != .any && $0.matches(label) }
            if fixture.expected == "All directions" {
                #expect(filter == nil, "unlabelled platforms belong to no specific direction")
            } else {
                #expect(filter?.displayName == fixture.expected)
            }
        }
    }

    @Test func anyMatchesEverything() {
        for fixture in Self.platformFixtures {
            #expect(DepartureDirectionFilter.any.matches(fixture.expected))
        }
    }

    @Test func matchingNarrowsAboardToOneDirection() {
        let arrivals = [
            arrival(line: .victoria, platform: "Northbound - Platform 3", direction: nil),
            arrival(line: .victoria, platform: "Southbound - Platform 4", direction: nil),
        ]
        let groups = StationDepartureGroup.groups(from: arrivals, for: .victoria)
        #expect(groups.count == 2)
        #expect(groups.matching(.northbound).map(\.direction) == ["Northbound"])
        #expect(groups.matching(.any).count == 2)
        #expect(groups.matching(nil).count == 2)
    }

    @Test func anUnmatchedDirectionFiltersToNothingSoCallersCanDecide() {
        // Strictness is the point: the widget needs to tell "no northbound
        // trains" from "this station has no northbound platform" so it can fall
        // back to the full board rather than showing an empty one.
        let arrivals = [arrival(line: .central, platform: "Eastbound - Platform 2", direction: nil)]
        let groups = StationDepartureGroup.groups(from: arrivals, for: .central)
        #expect(groups.matching(.northbound).isEmpty)
    }

    @Test func availableDirectionsAreDerivedFromLivePredictions() {
        let arrivals = [
            arrival(line: .central, platform: "Eastbound - Platform 2", direction: nil),
            arrival(line: .central, platform: "Westbound - Platform 1", direction: nil),
        ]
        #expect(DepartureDirectionFilter.available(in: arrivals) == [.any, .eastbound, .westbound])
    }

    @Test("A platform label resolves to the filter that produced it")
    func labelsResolveBackToTheirFilter() {
        for filter in DepartureDirectionFilter.allCases where filter != .any {
            #expect(DepartureDirectionFilter.resolve(label: filter.displayName) == filter)
        }
        #expect(DepartureDirectionFilter.resolve(label: "northbound") == .northbound)
    }

    @Test("A label we have no case for resolves to any rather than guessing")
    func unknownLabelsResolveToAny() {
        #expect(DepartureDirectionFilter.resolve(label: "Platform 3") == .any)
        #expect(DepartureDirectionFilter.resolve(label: "") == .any)
    }
}
