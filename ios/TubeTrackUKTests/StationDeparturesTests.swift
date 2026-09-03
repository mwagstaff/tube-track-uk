import Foundation
import Testing
@testable import TubeTrackUK

struct StationDeparturesTests {
    @Test func selectedLineGroupsProvideThreeRowPreviewsAndKeepExpansionData() throws {
        let arrivals = [
            arrival(
                id: "northern-north-4",
                line: .northern,
                platform: "Northbound - Platform 2",
                seconds: 240
            ),
            arrival(
                id: "victoria-south-1",
                line: .victoria,
                platform: "Southbound - Platform 4",
                seconds: 30
            ),
            arrival(
                id: "northern-south-3",
                line: .northern,
                platform: "Southbound - Platform 3",
                seconds: 180
            ),
            arrival(
                id: "northern-north-1",
                line: .northern,
                platform: "Northbound - Platform 2",
                seconds: 60
            ),
            arrival(
                id: "northern-south-1",
                line: .northern,
                platform: "Southbound - Platform 3",
                seconds: 60
            ),
            arrival(
                id: "northern-north-3",
                line: .northern,
                platform: "Northbound - Platform 2",
                seconds: 180
            ),
            arrival(
                id: "northern-south-4",
                line: .northern,
                platform: "Southbound - Platform 3",
                seconds: 240
            ),
            arrival(
                id: "northern-north-2",
                line: .northern,
                platform: "Northbound - Platform 2",
                seconds: 120
            ),
            arrival(
                id: "northern-south-2",
                line: .northern,
                platform: "Southbound - Platform 3",
                seconds: 120
            ),
        ]

        let groups = StationDepartureGroup.groups(from: arrivals, for: .northern)
        let northbound = try #require(groups.first { $0.direction == "Northbound" })
        let southbound = try #require(groups.first { $0.direction == "Southbound" })

        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.lineID == .northern })
        #expect(northbound.arrivals.count == 4)
        #expect(southbound.arrivals.count == 4)
        #expect(northbound.collapsedArrivals.map(\.id) == [
            "northern-north-1",
            "northern-north-2",
            "northern-north-3",
        ])
        #expect(southbound.collapsedArrivals.map(\.id) == [
            "northern-south-1",
            "northern-south-2",
            "northern-south-3",
        ])
        #expect(northbound.arrivals.last?.id == "northern-north-4")
        #expect(southbound.arrivals.last?.id == "northern-south-4")
    }

    @Test func selectionUsesFirstStationLineWithPredictions() {
        let selected = StationDepartureSelection.resolved(
            current: nil,
            lineIDs: [.northern, .victoria, .bakerloo],
            arrivals: [
                arrival(id: "bakerloo", line: .bakerloo, seconds: 30),
                arrival(id: "victoria", line: .victoria, seconds: 60),
            ]
        )

        #expect(selected == .victoria)
    }

    @Test func selectionFallsBackToFirstStationLineWithoutPredictions() {
        let selected = StationDepartureSelection.resolved(
            current: nil,
            lineIDs: [.northern, .victoria],
            arrivals: [arrival(id: "unrelated", line: .district, seconds: 30)]
        )

        #expect(selected == .northern)
        #expect(
            StationDepartureSelection.resolved(
                current: nil,
                lineIDs: [],
                arrivals: [arrival(id: "unrelated", line: .district, seconds: 30)]
            ) == nil
        )
    }

    @Test func selectionRetainsAValidCurrentLineAcrossPredictionChanges() {
        let retained = StationDepartureSelection.resolved(
            current: .victoria,
            lineIDs: [.northern, .victoria],
            arrivals: [arrival(id: "northern", line: .northern, seconds: 30)]
        )
        let replaced = StationDepartureSelection.resolved(
            current: .district,
            lineIDs: [.northern, .victoria],
            arrivals: [arrival(id: "victoria", line: .victoria, seconds: 30)]
        )

        #expect(retained == .victoria)
        #expect(replaced == .victoria)
    }

    @Test func arrivalsAfterTheFirstTwelveRemainAvailableToLaterLines() {
        let northern = (1...12).map { index in
            arrival(
                id: "northern-\(index)",
                line: .northern,
                platform: "Northbound - Platform 2",
                seconds: index * 10
            )
        }
        let victoria = [
            arrival(
                id: "victoria-north",
                line: .victoria,
                platform: "Northbound - Platform 3",
                seconds: 20
            ),
            arrival(
                id: "victoria-south",
                line: .victoria,
                platform: "Southbound - Platform 4",
                seconds: 40
            ),
        ]
        let arrivals = northern + victoria

        let allGroups = StationDepartureGroup.groups(from: arrivals)
        let victoriaGroups = StationDepartureGroup.groups(from: arrivals, for: .victoria)

        #expect(arrivals.count == 14)
        #expect(allGroups.filter { $0.lineID == .victoria }.count == 2)
        #expect(victoriaGroups.map(\.direction) == ["Northbound", "Southbound"])
        #expect(victoriaGroups.flatMap(\.arrivals).map(\.id).sorted() == [
            "victoria-north",
            "victoria-south",
        ])
    }

    @Test func directionsAreNormalizedAndPresentedInPassengerFacingOrder() {
        let arrivals = [
            arrival(id: "clockwise", line: .district, direction: "  clockwise  ", seconds: 80),
            arrival(id: "none", line: .district, direction: "   ", seconds: 70),
            arrival(id: "outbound", line: .district, direction: "OUTBOUND", seconds: 60),
            arrival(id: "inbound", line: .district, direction: "inbound", seconds: 50),
            arrival(id: "west", line: .district, direction: "westbound", seconds: 40),
            arrival(id: "east", line: .district, direction: "eastbound", seconds: 30),
            arrival(
                id: "south",
                line: .district,
                platform: "SOUTHBOUND - Platform 2",
                direction: "inbound",
                seconds: 20
            ),
            arrival(
                id: "north",
                line: .district,
                platform: "Northbound",
                direction: "outbound",
                seconds: 10
            ),
        ]

        let groups = StationDepartureGroup.groups(from: arrivals, for: .district)

        #expect(groups.map(\.direction) == [
            "Northbound",
            "Southbound",
            "Eastbound",
            "Westbound",
            "Inbound",
            "Outbound",
            "All directions",
            "Clockwise",
        ])
    }

    @Test func elizabethDirectionsUsePassengerFacingCardinalNames() {
        let eastbound = arrival(
            id: "eastbound",
            line: .elizabeth,
            direction: " inbound ",
            seconds: 60
        )
        let westbound = arrival(
            id: "westbound",
            line: .elizabeth,
            direction: "OUTBOUND",
            seconds: 120
        )

        #expect(StationDepartureMetadata.directionLabel(for: eastbound) == "Eastbound")
        #expect(StationDepartureMetadata.directionLabel(for: westbound) == "Westbound")
    }

    @Test func destinationAndPlatformLabelsNormalizeTfLMetadata() {
        let namedDestination = arrival(
            id: "named",
            line: .northern,
            platform: " Northbound - Platform 2 ",
            destinationName: "High Barnet Underground Station",
            towards: "Ignored",
            seconds: 60
        )
        let towardsFallback = arrival(
            id: "towards",
            line: .northern,
            platform: " Northbound ",
            destinationName: nil,
            towards: "Morden",
            seconds: 60
        )
        let elizabethPlatform = arrival(
            id: "elizabeth",
            line: .elizabeth,
            platform: " a ",
            seconds: 60
        )
        let tramDestination = arrival(
            id: "tram",
            line: .tram,
            destinationName: "East Croydon Tram Stop",
            seconds: 60
        )
        let missingMetadata = arrival(
            id: "missing",
            line: .northern,
            platform: "   ",
            destinationName: nil,
            towards: nil,
            seconds: 60
        )
        let selfReferentialDestination = arrival(
            id: "self-referential",
            line: .northern,
            destinationName: "Mill Hill East Underground Station",
            towards: "Mill Hill East via Bank",
            seconds: 60,
            stationName: "Mill Hill East Underground Station",
            stationID: "940GZZLUMHL",
            destinationID: "940GZZLUMHL"
        )
        let selfReferentialNamesWithoutIDs = arrival(
            id: "self-referential-names",
            line: .northern,
            destinationName: "Mill Hill East Underground Station",
            towards: "Mill Hill East via Charing Cross",
            seconds: 60,
            stationName: "Mill Hill East Underground Station",
            stationID: "940GZZLUMHL"
        )

        #expect(StationDepartureMetadata.destinationLabel(for: namedDestination) == "High Barnet")
        #expect(StationDepartureMetadata.platformLabel(for: namedDestination) == "Northbound - Platform 2")
        #expect(StationDepartureMetadata.destinationLabel(for: towardsFallback) == "Morden")
        #expect(StationDepartureMetadata.platformLabel(for: towardsFallback) == nil)
        #expect(StationDepartureMetadata.platformLabel(for: elizabethPlatform) == "Platform A")
        #expect(StationDepartureMetadata.destinationLabel(for: tramDestination) == "East Croydon")
        #expect(StationDepartureMetadata.destinationLabel(for: missingMetadata) == "Check front of train")
        #expect(StationDepartureMetadata.platformLabel(for: missingMetadata) == nil)
        #expect(
            StationDepartureMetadata.destinationLabel(for: selfReferentialDestination)
                == "Check front of train"
        )
        #expect(
            StationDepartureMetadata.destinationLabel(for: selfReferentialNamesWithoutIDs)
                == "Check front of train"
        )
    }

    @Test func departureTimesUseInjectedNowAndDeterministicMinuteFlooring() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dueByExpectedTime = arrival(
            id: "due-expected",
            line: .northern,
            expectedArrival: now.addingTimeInterval(44),
            seconds: 999
        )
        let oneMinute = arrival(
            id: "one-minute",
            line: .northern,
            expectedArrival: now.addingTimeInterval(45),
            seconds: 999
        )
        let twoMinutes = arrival(
            id: "two-minutes",
            line: .northern,
            expectedArrival: now.addingTimeInterval(120),
            seconds: 999
        )
        let dueByPrediction = arrival(id: "due-prediction", line: .northern, seconds: 44)
        let flooredPrediction = arrival(id: "floored", line: .northern, seconds: 179)
        let missingTime = arrival(id: "missing", line: .northern, seconds: nil)

        #expect(StationDepartureMetadata.departureTime(for: dueByExpectedTime, now: now) == "Due")
        #expect(StationDepartureMetadata.departureTime(for: oneMinute, now: now) == "1 min")
        #expect(StationDepartureMetadata.departureTime(for: twoMinutes, now: now) == "2 min")
        #expect(StationDepartureMetadata.departureTime(for: dueByPrediction, now: now) == "Due")
        #expect(StationDepartureMetadata.departureTime(for: flooredPrediction, now: now) == "2 min")
        #expect(StationDepartureMetadata.departureTime(for: missingTime, now: now) == "—")
    }

    private func arrival(
        id: String,
        line: TubeLineID,
        platform: String? = nil,
        direction: String? = nil,
        destinationName: String? = "Destination Underground Station",
        towards: String? = nil,
        expectedArrival: Date? = nil,
        seconds: Int?,
        stationName: String = "Test station",
        stationID: String = "test-station",
        destinationID: String? = nil
    ) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: id,
            vehicleId: id,
            lineId: line.rawValue,
            stationName: stationName,
            naptanId: stationID,
            platformName: platform,
            direction: direction,
            destinationName: destinationName,
            destinationNaptanId: destinationID,
            towards: towards,
            expectedArrival: expectedArrival,
            timeToStation: seconds,
            currentLocation: nil
        )
    }
}
