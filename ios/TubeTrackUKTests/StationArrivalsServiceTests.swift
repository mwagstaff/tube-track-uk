import Foundation
import Testing
@testable import TubeTrackUK

@Suite(.serialized)
struct StationArrivalsServiceTests {
    @Test func freshArrivalsAreReusedWithoutAnotherNetworkRequest() async throws {
        let path = "/api/v1/arrivals/940GZZLUVIC"
        let service = makeService(responses: [
            path: fixture([
                prediction(
                    id: "victoria",
                    line: .victoria,
                    stationID: "940GZZLUVIC",
                    platform: "Southbound - Platform 4",
                    direction: "outbound",
                    destination: "Brixton",
                    seconds: 120
                ),
            ]),
        ])

        _ = try await service.fetch(stationIDs: ["940GZZLUVIC"])
        _ = try await service.fetch(stationIDs: ["940GZZLUVIC"])

        #expect(StationArrivalsURLProtocol.requestCount(for: path) == 1)
    }

    @Test func failedRefreshReturnsThePreviousDepartureSnapshot() async throws {
        let path = "/api/v1/arrivals/940GZZLUVIC"
        let service = makeService(responses: [
            path: fixture([
                prediction(
                    id: "cached-victoria",
                    line: .victoria,
                    stationID: "940GZZLUVIC",
                    platform: "Southbound - Platform 4",
                    direction: "outbound",
                    destination: "Brixton",
                    seconds: 120
                ),
            ]),
        ])
        let first = try await service.fetchSnapshot(stationIDs: ["940GZZLUVIC"])
        StationArrivalsURLProtocol.prepare(responses: [:])

        let fallback = try await service.fetchSnapshot(
            stationIDs: ["940GZZLUVIC"],
            forceRefresh: true
        )

        #expect(first.arrivals.map(\.id) == ["cached-victoria"])
        #expect(fallback.arrivals.map(\.id) == ["cached-victoria"])
        #expect(fallback.isStale)
        #expect(fallback.fetchedAt == first.fetchedAt && fallback.serverUpdatedAt == first.serverUpdatedAt)
        #expect(StationArrivalsURLProtocol.requestCount(for: path) == 1)
    }

    @Test func beckenhamJunctionResolvesItsDestinationFromTheTimetable() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZCRBEK": fixture([
                prediction(
                    id: "beckenham-1",
                    line: .tram,
                    stationID: "940GZZCRBEK",
                    platform: "Eastbound - Platform 2",
                    direction: "inbound",
                    destination: "Beckenham Junction",
                    seconds: 60,
                    stationName: "Beckenham Junction",
                    destinationID: "940GZZCRBEK"
                ),
                prediction(
                    id: "beckenham-2",
                    line: .tram,
                    stationID: "940GZZCRBEK",
                    platform: "Eastbound - Platform 2",
                    direction: "inbound",
                    destination: "Beckenham Junction",
                    seconds: 1_080,
                    stationName: "Beckenham Junction",
                    destinationID: "940GZZCRBEK"
                ),
            ]),
            "/api/v1/timetables/tram/940GZZCRBEK": timetableFixture(destinations: [
                (id: "940GZZCRECR", name: "East Croydon Tram Stop"),
            ]),
        ])

        let firstFetch = try await service.fetch(stationIDs: ["940GZZCRBEK"])
        let secondFetch = try await service.fetch(stationIDs: ["940GZZCRBEK"])

        #expect(firstFetch.map(\.id) == ["beckenham-1", "beckenham-2"])
        #expect(firstFetch.allSatisfy { $0.destinationName == "East Croydon" })
        #expect(firstFetch.allSatisfy { $0.destinationNaptanId == "940GZZCRECR" })
        #expect(firstFetch.allSatisfy { $0.towards == "East Croydon" })
        #expect(firstFetch.allSatisfy { $0.platformName == "Eastbound - Platform 2" })
        #expect(firstFetch.allSatisfy { $0.direction == "inbound" })
        #expect(firstFetch.map(\.timeToStation) == [60, 1_080])
        #expect(secondFetch.map(\.destinationName) == ["East Croydon", "East Croydon"])
        #expect(
            StationArrivalsURLProtocol.requestCount(
                for: "/api/v1/timetables/tram/940GZZCRBEK"
            ) == 1
        )
        #expect(
            StationArrivalsURLProtocol.queryValues(
                named: "direction",
                for: "/api/v1/timetables/tram/940GZZCRBEK"
            ) == []
        )
    }

    @Test func beckenhamJunctionDestinationIsDynamicRatherThanHardcoded() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZCRBEK": fixture([
                prediction(
                    id: "beckenham",
                    line: .tram,
                    stationID: "940GZZCRBEK",
                    platform: "Eastbound - Platform 2",
                    direction: "inbound",
                    destination: "Beckenham Junction Tram Stop",
                    seconds: 60,
                    stationName: "Beckenham Junction",
                    destinationID: "940GZZCRBEK"
                ),
            ]),
            "/api/v1/timetables/tram/940GZZCRBEK": timetableFixture(destinations: [
                (id: "940GZZCRWMB", name: "Wimbledon Tram Stop"),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZCRBEK"])

        #expect(arrivals.count == 1)
        #expect(arrivals[0].destinationName == "Wimbledon")
        #expect(arrivals[0].destinationNaptanId == "940GZZCRWMB")
        #expect(arrivals[0].towards == "Wimbledon")
    }

    @Test func beckenhamJunctionNeverFallsBackToItsOwnNameWhenTimetableFails() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZCRBEK": fixture([
                prediction(
                    id: "beckenham",
                    line: .tram,
                    stationID: "940GZZCRBEK",
                    platform: "Eastbound - Platform 2",
                    direction: "inbound",
                    destination: "Beckenham Junction",
                    seconds: 60,
                    stationName: "Beckenham Junction",
                    destinationID: "940GZZCRBEK"
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZCRBEK"])
        _ = try await service.fetch(stationIDs: ["940GZZCRBEK"])

        let arrival = try #require(arrivals.first)
        #expect(arrival.destinationName == nil)
        #expect(arrival.destinationNaptanId == nil)
        #expect(arrival.towards == nil)
        #expect(StationDepartureMetadata.destinationLabel(for: arrival) == "Check front of train")
        #expect(
            StationArrivalsURLProtocol.requestCount(
                for: "/api/v1/timetables/tram/940GZZCRBEK"
            ) == 1
        )
    }

    @Test func beckenhamJunctionDoesNotInventADestinationFromAmbiguousPatterns() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZCRBEK": fixture([
                prediction(
                    id: "beckenham",
                    line: .tram,
                    stationID: "940GZZCRBEK",
                    platform: "Eastbound - Platform 2",
                    direction: "inbound",
                    destination: "Beckenham Junction",
                    seconds: 60,
                    stationName: "Beckenham Junction",
                    destinationID: "940GZZCRBEK"
                ),
            ]),
            "/api/v1/timetables/tram/940GZZCRBEK": timetableFixture(patterns: [
                [(id: "940GZZCRECR", name: "East Croydon Tram Stop")],
                [
                    (id: "940GZZCRBRD", name: "Beckenham Road Tram Stop"),
                    (id: "940GZZCRWMB", name: "Wimbledon Tram Stop"),
                ],
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZCRBEK"])

        #expect(arrivals.first?.destinationName == nil)
        #expect(arrivals.first?.destinationNaptanId == nil)
        #expect(arrivals.first?.towards == nil)
    }

    @Test func validBeckenhamJunctionDestinationDoesNotRequestATimetable() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZCRBEK": fixture([
                prediction(
                    id: "valid",
                    line: .tram,
                    stationID: "940GZZCRBEK",
                    platform: "Westbound - Platform 2",
                    direction: "outbound",
                    destination: "East Croydon",
                    seconds: 60,
                    stationName: "Beckenham Junction",
                    destinationID: "940GZZCRECR"
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZCRBEK"])

        #expect(arrivals.first?.destinationName == "East Croydon")
        #expect(
            StationArrivalsURLProtocol.requestCount(
                for: "/api/v1/timetables/tram/940GZZCRBEK"
            ) == 0
        )
    }

    @Test func millHillEastKeepsUnknownTrainsAlongsideKnownOutboundTrains() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZLUMHL": fixture([
                prediction(
                    id: "terminating-bank",
                    line: .northern,
                    stationID: "940GZZLUMHL",
                    platform: "Southbound - Platform 1",
                    direction: "inbound",
                    destination: "Mill Hill East Underground Station",
                    seconds: 240,
                    stationName: "Mill Hill East Underground Station",
                    destinationID: "940GZZLUMHL",
                    towards: "Mill Hill East via Bank"
                ),
                prediction(
                    id: "terminating-charing-cross",
                    line: .northern,
                    stationID: "940GZZLUMHL",
                    platform: "Southbound - Platform 1",
                    direction: "inbound",
                    destination: "Mill Hill East Underground Station",
                    seconds: 1_140,
                    stationName: "Mill Hill East Underground Station",
                    destinationID: "940GZZLUMHL",
                    towards: "Mill Hill East via Charing Cross"
                ),
                prediction(
                    id: "outbound",
                    line: .northern,
                    stationID: "940GZZLUMHL",
                    platform: "Southbound - Platform 1",
                    direction: "outbound",
                    destination: "Battersea Power Station Underground Station",
                    seconds: 60,
                    stationName: "Mill Hill East Underground Station",
                    destinationID: "940GZZLUBPS",
                    towards: "Battersea Power Station via Charing Cross"
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZLUMHL"])

        #expect(arrivals.map(\.id) == [
            "outbound",
            "terminating-bank",
            "terminating-charing-cross",
        ])
        #expect(arrivals.first?.destinationNaptanId == "940GZZLUBPS")
        #expect(arrivals.dropFirst().allSatisfy { $0.destinationName == nil })
        #expect(arrivals.dropFirst().allSatisfy { $0.destinationNaptanId == nil })
        #expect(arrivals.dropFirst().allSatisfy { $0.towards == nil })
        #expect(
            StationArrivalsURLProtocol.requestCount(
                for: "/api/v1/timetables/northern/940GZZLUMHL"
            ) == 0
        )
    }

    @Test func allSelfReferentialTubePredictionsDoNotUseAnAmbiguousTimetable() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZLUMHL": fixture([
                prediction(
                    id: "mill-hill-east",
                    line: .northern,
                    stationID: "940GZZLUMHL",
                    platform: "Southbound - Platform 1",
                    direction: "inbound",
                    destination: "Mill Hill East Underground Station",
                    seconds: 240,
                    stationName: "Mill Hill East Underground Station",
                    destinationID: "940GZZLUMHL",
                    towards: "Mill Hill East via Bank"
                ),
            ]),
            "/api/v1/timetables/northern/940GZZLUMHL": timetableFixture(patterns: [
                [(id: "940GZZLUBPS", name: "Battersea Power Station Underground Station")],
                [
                    (id: "940GZZLUEUS", name: "Euston Underground Station"),
                    (id: "940GZZLUMDN", name: "Morden Underground Station"),
                ],
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZLUMHL"])

        #expect(arrivals.first?.destinationName == nil)
        #expect(arrivals.first?.destinationNaptanId == nil)
        #expect(arrivals.first?.towards == nil)
        #expect(
            StationArrivalsURLProtocol.queryValues(
                named: "direction",
                for: "/api/v1/timetables/northern/940GZZLUMHL"
            ).isEmpty
        )
    }

    @Test func bankDLRKeepsOneUnknownTrainAlongsideKnownOutboundTrains() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLBNK": fixture([
                prediction(
                    id: "terminating",
                    line: .dlr,
                    stationID: "940GZZDLBNK",
                    platform: "Platform 9",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 60,
                    stationName: "Bank DLR Station",
                    destinationID: "940GZZDLBNK"
                ),
                prediction(
                    id: "lewisham",
                    line: .dlr,
                    stationID: "940GZZDLBNK",
                    platform: "Platform 10",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 180,
                    stationName: "Bank DLR Station",
                    destinationID: "940GZZDLLCA"
                ),
                prediction(
                    id: "woolwich",
                    line: .dlr,
                    stationID: "940GZZDLBNK",
                    platform: "Platform 10",
                    direction: "outbound",
                    destination: "Woolwich Arsenal DLR Station",
                    seconds: 360,
                    stationName: "Bank DLR Station",
                    destinationID: "940GZZDLWLA"
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZDLBNK"])

        #expect(arrivals.map(\.id) == ["terminating", "lewisham", "woolwich"])
        #expect(arrivals.allSatisfy { $0.destinationNaptanId != "940GZZDLBNK" })
        #expect(arrivals.first?.destinationName == nil)
        #expect(
            StationArrivalsURLProtocol.requestCount(
                for: "/api/v1/timetables/dlr/940GZZDLBNK"
            ) == 0
        )
    }

    @Test func highBarnetCollapsesPlatformAlternativesWithoutInventingMorden() async throws {
        let baseTime = Date(timeIntervalSince1970: 2_000_000_000)
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZLUHBT": fixture([
                prediction(
                    id: "known-morden",
                    vehicleID: "072",
                    line: .northern,
                    stationID: "940GZZLUHBT",
                    platform: "Southbound - Platform 3",
                    direction: "inbound",
                    destination: "Morden Underground Station",
                    seconds: 36,
                    expectedArrival: baseTime,
                    stationName: "High Barnet Underground Station",
                    destinationID: "940GZZLUMDN",
                    towards: "Morden via Bank"
                ),
                prediction(
                    id: "incoming-034",
                    vehicleID: "034",
                    line: .northern,
                    stationID: "940GZZLUHBT",
                    platform: "Southbound - Platform 1",
                    direction: "",
                    destination: "High Barnet Underground Station",
                    seconds: 53,
                    expectedArrival: baseTime.addingTimeInterval(17),
                    stationName: "High Barnet Underground Station",
                    destinationID: "940GZZLUHBT",
                    towards: "High Barnet via CX"
                ),
                prediction(
                    id: "incoming-034",
                    vehicleID: "034",
                    line: .northern,
                    stationID: "940GZZLUHBT",
                    platform: "Southbound - Platform 2",
                    direction: "",
                    destination: "High Barnet Underground Station",
                    seconds: 53,
                    expectedArrival: baseTime.addingTimeInterval(17),
                    stationName: "High Barnet Underground Station",
                    destinationID: "940GZZLUHBT",
                    towards: "High Barnet via CX"
                ),
                prediction(
                    id: "incoming-034",
                    vehicleID: "034",
                    line: .northern,
                    stationID: "940GZZLUHBT",
                    platform: "Southbound - Platform 3",
                    direction: "",
                    destination: "High Barnet Underground Station",
                    seconds: 54,
                    expectedArrival: baseTime.addingTimeInterval(18),
                    stationName: "High Barnet Underground Station",
                    destinationID: "940GZZLUHBT",
                    towards: "High Barnet via CX"
                ),
                prediction(
                    id: "incoming-055",
                    vehicleID: "055",
                    line: .northern,
                    stationID: "940GZZLUHBT",
                    platform: "Southbound - Platform 1",
                    direction: "",
                    destination: "High Barnet Underground Station",
                    seconds: 143,
                    expectedArrival: baseTime.addingTimeInterval(107),
                    stationName: "High Barnet Underground Station",
                    destinationID: "940GZZLUHBT",
                    towards: "High Barnet via Bank"
                ),
                prediction(
                    id: "incoming-055",
                    vehicleID: "055",
                    line: .northern,
                    stationID: "940GZZLUHBT",
                    platform: "Southbound - Platform 2",
                    direction: "",
                    destination: "High Barnet Underground Station",
                    seconds: 143,
                    expectedArrival: baseTime.addingTimeInterval(107),
                    stationName: "High Barnet Underground Station",
                    destinationID: "940GZZLUHBT",
                    towards: "High Barnet via Bank"
                ),
                prediction(
                    id: "incoming-055",
                    vehicleID: "055",
                    line: .northern,
                    stationID: "940GZZLUHBT",
                    platform: "Southbound - Platform 3",
                    direction: "",
                    destination: "High Barnet Underground Station",
                    seconds: 144,
                    expectedArrival: baseTime.addingTimeInterval(108),
                    stationName: "High Barnet Underground Station",
                    destinationID: "940GZZLUHBT",
                    towards: "High Barnet via Bank"
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZLUHBT"])

        #expect(arrivals.map(\.id) == ["known-morden", "incoming-034", "incoming-055"])
        #expect(arrivals.map(\.destinationName) == ["Morden Underground Station", nil, nil])
        #expect(arrivals.map(\.platformName) == [
            "Southbound - Platform 3",
            "Southbound",
            "Southbound",
        ])
        #expect(arrivals.dropFirst().allSatisfy {
            StationDepartureMetadata.destinationLabel(for: $0) == "Check front of train"
        })
        #expect(
            StationArrivalsURLProtocol.requestCount(
                for: "/api/v1/timetables/northern/940GZZLUHBT"
            ) == 0
        )
    }

    @Test func overgroundTerminusUsesActualDepartureRecords() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/910GBARKRIV": fixture([
                prediction(
                    id: "incoming",
                    line: .suffragette,
                    stationID: "910GBARKRIV",
                    platform: "Platform 1",
                    direction: "inbound",
                    destination: "Barking Riverside Rail Station",
                    seconds: 60,
                    stationName: "Barking Riverside Rail Station",
                    destinationID: "910GBARKRIV"
                ),
            ]),
            "/api/v1/arrival-departures/910GBARKRIV": fixture([
                [
                    "naptanId": "910GBARKRIV",
                    "stationName": "Barking Riverside Rail Station",
                    "platformName": "Platform 1",
                    "destinationNaptanId": "910GBARKRIV",
                    "destinationName": "Barking Riverside Rail Station",
                    "estimatedTimeOfArrival": "2033-05-18T03:34:00Z",
                ],
                [
                    "naptanId": "910GBARKRIV",
                    "stationName": "Barking Riverside Rail Station",
                    "platformName": "Platform 1",
                    "destinationNaptanId": "910GGOSPLOK",
                    "destinationName": "Gospel Oak Rail Station",
                    "estimatedTimeOfDeparture": "2033-05-18T03:40:00Z",
                    "minutesAndSecondsToDeparture": "5:30",
                ],
                [
                    "naptanId": "910GBARKRIV",
                    "stationName": "Barking Riverside Rail Station",
                    "platformName": "Platform 1",
                    "destinationNaptanId": "910GGOSPLOK",
                    "destinationName": "Gospel Oak Rail Station",
                    "scheduledTimeOfDeparture": "2033-05-18T03:55:00Z",
                    "minutesAndSecondsToDeparture": "20:00",
                ],
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["910GBARKRIV"])

        #expect(arrivals.count == 2)
        #expect(arrivals.map(\.destinationNaptanId) == ["910GGOSPLOK", "910GGOSPLOK"])
        #expect(arrivals.map(\.timeToStation) == [330, 1_200])
        #expect(arrivals.allSatisfy {
            StationDepartureMetadata.destinationLabel(for: $0) == "Gospel Oak"
        })
        #expect(
            StationArrivalsURLProtocol.queryValues(
                named: "lineId",
                for: "/api/v1/arrival-departures/910GBARKRIV"
            ) == ["suffragette"]
        )
        #expect(
            StationArrivalsURLProtocol.requestCount(
                for: "/api/v1/timetables/suffragette/910GBARKRIV"
            ) == 0
        )
    }

    @Test func canaryWharfPreservesDLRDestinationsAndBothJubileeDirections() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLCAN": fixture([
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 60
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 4",
                    direction: "inbound",
                    destination: "Stratford DLR Station",
                    seconds: 180
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 360
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 1",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 120
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 1",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 420
                ),
            ]),
            "/api/v1/arrivals/940GZZLUCYF": fixture([
                prediction(
                    id: "jubilee-east-1",
                    line: .jubilee,
                    stationID: "940GZZLUCYF",
                    platform: "Eastbound - Platform 2",
                    direction: "outbound",
                    destination: "Stratford Underground Station",
                    seconds: 90
                ),
                prediction(
                    id: "jubilee-west-1",
                    line: .jubilee,
                    stationID: "940GZZLUCYF",
                    platform: "Westbound - Platform 1",
                    direction: "inbound",
                    destination: "Stanmore Underground Station",
                    seconds: 150
                ),
                prediction(
                    id: "jubilee-east-2",
                    line: .jubilee,
                    stationID: "940GZZLUCYF",
                    platform: "Eastbound - Platform 2",
                    direction: "outbound",
                    destination: "North Greenwich Underground Station",
                    seconds: 210
                ),
                prediction(
                    id: "jubilee-west-2",
                    line: .jubilee,
                    stationID: "940GZZLUCYF",
                    platform: "Westbound - Platform 1",
                    direction: "inbound",
                    destination: "Wembley Park Underground Station",
                    seconds: 270
                ),
            ]),
            "/api/v1/arrivals/910GCANWHRF": fixture([]),
        ])

        let arrivals = try await service.fetch(stationIDs: [
            "940GZZDLCAN",
            "940GZZLUCYF",
            "910GCANWHRF",
        ])

        let dlrGroups = StationDepartureGroup.groups(from: arrivals, for: .dlr)
        let jubileeGroups = StationDepartureGroup.groups(from: arrivals, for: .jubilee)

        #expect(arrivals.filter { $0.lineId == TubeLineID.dlr.rawValue }.count == 5)
        #expect(Set(dlrGroups.map(\.direction)) == ["Inbound", "Outbound"])
        #expect(Set(dlrGroups.flatMap(\.arrivals).compactMap(\.destinationName)) == [
            "Bank DLR Station",
            "Lewisham DLR Station",
            "Stratford DLR Station",
        ])
        #expect(jubileeGroups.map(\.direction) == ["Eastbound", "Westbound"])
        #expect(jubileeGroups.allSatisfy { $0.arrivals.count == 2 })
    }

    @Test func mudchutePreservesMultiplePredictionsWithTheSameTfLID() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLMUD": fixture([
                prediction(
                    id: "shared-mudchute-id",
                    line: .dlr,
                    stationID: "940GZZDLMUD",
                    platform: "Platform 1",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 60
                ),
                prediction(
                    id: "shared-mudchute-id",
                    line: .dlr,
                    stationID: "940GZZDLMUD",
                    platform: "Platform 1",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 360
                ),
                prediction(
                    id: "shared-mudchute-id",
                    line: .dlr,
                    stationID: "940GZZDLMUD",
                    platform: "Platform 1",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 660
                ),
                prediction(
                    id: "shared-mudchute-id",
                    line: .dlr,
                    stationID: "940GZZDLMUD",
                    platform: "Platform 2",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 120
                ),
                prediction(
                    id: "shared-mudchute-id",
                    line: .dlr,
                    stationID: "940GZZDLMUD",
                    platform: "Platform 2",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 420
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZDLMUD"])
        let groups = StationDepartureGroup.groups(from: arrivals, for: .dlr)
        let inbound = try #require(groups.first { $0.direction == "Inbound" })
        let outbound = try #require(groups.first { $0.direction == "Outbound" })

        #expect(arrivals.count == 5)
        #expect(Set(arrivals.map(\.departureIdentity)).count == arrivals.count)
        #expect(inbound.arrivals.map(\.timeToStation) == [120, 420])
        #expect(outbound.arrivals.map(\.timeToStation) == [60, 360, 660])
        #expect(outbound.collapsedArrivals.count == 3)
    }

    @Test func canaryWharfCoalescesMirroredDLRPlatformFaces() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLCAN": fixture([
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 60
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 6",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 61
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 3",
                    direction: "inbound",
                    destination: "Stratford DLR Station",
                    seconds: 180
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 4",
                    direction: "inbound",
                    destination: "Stratford DLR Station",
                    seconds: 180
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 1",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 120
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 2",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 121
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 360
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 6",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 361
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZDLCAN"])

        #expect(arrivals.count == 4)
        #expect(arrivals.map(\.timeToStation) == [60, 120, 180, 360])
        #expect(arrivals.map(\.platformName) == [
            "Platforms 5 & 6",
            "Platforms 1 & 2",
            "Platforms 3 & 4",
            "Platforms 5 & 6",
        ])
        #expect(Set(arrivals.map(\.departureIdentity)).count == arrivals.count)
    }

    @Test func canaryWharfMirrorToleranceUsesExpectedArrivalAndKeepsDistinctTrains() async throws {
        let firstArrival = Date(timeIntervalSince1970: 2_000_000_000)
        let secondArrival = firstArrival.addingTimeInterval(300)
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLCAN": fixture([
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 60,
                    expectedArrival: firstArrival
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 6",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 70,
                    expectedArrival: firstArrival.addingTimeInterval(2)
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 360,
                    expectedArrival: secondArrival
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 6",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 361,
                    expectedArrival: secondArrival.addingTimeInterval(3)
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZDLCAN"])

        #expect(arrivals.count == 3)
        #expect(arrivals.map(\.timeToStation) == [60, 360, 361])
        #expect(arrivals.map(\.platformName) == [
            "Platforms 5 & 6",
            "Platform 5",
            "Platform 6",
        ])
        #expect(arrivals.map(\.expectedArrival) == [
            firstArrival,
            secondArrival,
            secondArrival.addingTimeInterval(3),
        ])
    }

    @Test func mirroredPlatformNumbersAreNotCoalescedOutsideCanaryWharf() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLMUD": fixture([
                prediction(
                    id: "shared-mudchute-id",
                    line: .dlr,
                    stationID: "940GZZDLMUD",
                    platform: "Platform 1",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 60
                ),
                prediction(
                    id: "shared-mudchute-id",
                    line: .dlr,
                    stationID: "940GZZDLMUD",
                    platform: "Platform 2",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 61
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZDLMUD"])

        #expect(arrivals.count == 2)
        #expect(arrivals.map(\.platformName) == ["Platform 1", "Platform 2"])
        #expect(arrivals.map(\.timeToStation) == [60, 61])
    }

    @Test func canaryWharfKeepsMirroredFacesWithDifferentSourceIDsSeparate() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLCAN": fixture([
                prediction(
                    id: "bank-platform-5",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 60
                ),
                prediction(
                    id: "bank-platform-6",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 6",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 60
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZDLCAN"])

        #expect(arrivals.count == 2)
        #expect(arrivals.map(\.platformName) == ["Platform 5", "Platform 6"])
    }

    @Test func canaryWharfKeepsSameFaceAndDifferentDestinationPredictionsSeparate() async throws {
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLCAN": fixture([
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 60
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 5",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 61
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 3",
                    direction: "inbound",
                    destination: "Stratford DLR Station",
                    seconds: 180
                ),
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLCAN",
                    platform: "Platform 4",
                    direction: "inbound",
                    destination: "Bank DLR Station",
                    seconds: 180
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: ["940GZZDLCAN"])

        #expect(arrivals.count == 4)
        #expect(arrivals.map(\.platformName) == [
            "Platform 5",
            "Platform 5",
            "Platform 4",
            "Platform 3",
        ])
    }

    @Test func removesOnlyExactDuplicatePredictions() async throws {
        let repeated = prediction(
            id: "shared-dlr-id",
            line: .dlr,
            stationID: "940GZZDLMUD",
            platform: "Platform 1",
            direction: "outbound",
            destination: "Lewisham DLR Station",
            seconds: 60
        )
        let service = makeService(responses: [
            "/api/v1/arrivals/940GZZDLMUD": fixture([
                repeated,
                repeated,
                prediction(
                    id: "shared-dlr-id",
                    line: .dlr,
                    stationID: "940GZZDLMUD",
                    platform: "Platform 1",
                    direction: "outbound",
                    destination: "Lewisham DLR Station",
                    seconds: 360
                ),
            ]),
        ])

        let arrivals = try await service.fetch(stationIDs: [
            "940GZZDLMUD",
            "940GZZDLMUD",
        ])

        #expect(arrivals.count == 2)
        #expect(arrivals.map(\.timeToStation) == [60, 360])
        #expect(Set(arrivals.map(\.departureIdentity)).count == 2)
    }

    @Test func departureIdentityStaysStableAsAKnownArrivalCountsDown() {
        let expectedArrival = Date(timeIntervalSince1970: 2_000_000_000)
        let initial = modelPrediction(
            expectedArrival: expectedArrival,
            seconds: 600
        )
        let refreshed = modelPrediction(
            expectedArrival: expectedArrival,
            seconds: 570
        )
        let followingTrain = modelPrediction(
            expectedArrival: expectedArrival.addingTimeInterval(300),
            seconds: 870
        )

        #expect(initial.departureIdentity == refreshed.departureIdentity)
        #expect(initial.departureIdentity != followingTrain.departureIdentity)
        #expect(initial.departureIdentity.fallbackTimeToStation == nil)
    }

    @Test func departureIdentityDistinguishesRepeatedTfLIDsByDepartureMetadata() {
        let baseline = modelPrediction(seconds: 60)
        let normalizedDuplicate = modelPrediction(
            vehicleID: "   ",
            stationID: " 940GZZDLMUD ",
            platform: " Platform 1 ",
            direction: " outbound ",
            destinationID: " 940GZZDLLCA ",
            destination: " Lewisham DLR Station ",
            towards: " Lewisham ",
            seconds: 60
        )
        let laterDeparture = modelPrediction(seconds: 360)
        let otherDirection = modelPrediction(direction: "inbound", seconds: 60)
        let otherPlatform = modelPrediction(platform: "Platform 2", seconds: 60)
        let otherDestination = modelPrediction(
            destinationID: "940GZZDLBNK",
            destination: "Bank DLR Station",
            towards: "Bank",
            seconds: 60
        )
        let otherStop = modelPrediction(stationID: "940GZZDLCAN", seconds: 60)

        #expect(baseline.departureIdentity == normalizedDuplicate.departureIdentity)
        #expect(Set([
            baseline.departureIdentity,
            laterDeparture.departureIdentity,
            otherDirection.departureIdentity,
            otherPlatform.departureIdentity,
            otherDestination.departureIdentity,
            otherStop.departureIdentity,
        ]).count == 6)
        #expect(baseline.departureIdentity.fallbackTimeToStation == 60)
        #expect(laterDeparture.departureIdentity.fallbackTimeToStation == 360)
    }

    private func makeService(responses: [String: Data]) -> StationArrivalsService {
        StationArrivalsURLProtocol.prepare(responses: responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StationArrivalsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = TubeTrackAPIClient(
            configuration: TubeTrackAPIConfiguration(
                baseURL: URL(string: "https://arrivals.test")!
            ),
            session: session
        )
        return StationArrivalsService(client: client)
    }

    private func fixture(_ predictions: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: predictions)
    }

    private func prediction(
        id: String,
        vehicleID: String = "",
        line: TubeLineID,
        stationID: String,
        platform: String,
        direction: String,
        destination: String,
        seconds: Int,
        expectedArrival: Date? = nil,
        stationName: String = "Test station",
        destinationID: String? = nil,
        towards: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "vehicleId": vehicleID,
            "lineId": line.rawValue,
            "stationName": stationName,
            "naptanId": stationID,
            "platformName": platform,
            "direction": direction,
            "destinationName": destination,
            "towards": towards ?? destination,
            "timeToStation": seconds,
            "currentLocation": "",
        ]
        if let destinationID {
            value["destinationNaptanId"] = destinationID
        }
        if let expectedArrival {
            value["expectedArrival"] = ISO8601DateFormatter.tfl.string(from: expectedArrival)
        }
        return value
    }

    private func timetableFixture(
        destinations: [(id: String, name: String)]
    ) -> Data {
        timetableFixture(patterns: destinations.map { [$0] })
    }

    private func timetableFixture(
        patterns: [[(id: String, name: String)]]
    ) -> Data {
        let stopsByID = patterns.flatMap { $0 }.reduce(
            into: [String: String]()
        ) { result, stop in
            result[stop.id] = stop.name
        }
        let value: [String: Any] = [
            "stops": stopsByID.map { id, name in
                [
                    "id": id,
                    "stationId": id,
                    "name": name,
                ]
            },
            "timetable": [
                "routes": [[
                    "stationIntervals": patterns.enumerated().map { index, pattern in
                        [
                            "id": String(index),
                            "intervals": pattern.map { ["stopId": $0.id] },
                        ]
                    },
                ]],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: value)
    }

    private func modelPrediction(
        id: String = "shared-dlr-id",
        vehicleID: String? = nil,
        line: TubeLineID = .dlr,
        stationID: String? = "940GZZDLMUD",
        platform: String? = "Platform 1",
        direction: String? = "outbound",
        destinationID: String? = "940GZZDLLCA",
        destination: String? = "Lewisham DLR Station",
        towards: String? = "Lewisham",
        expectedArrival: Date? = nil,
        seconds: Int?
    ) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: id,
            vehicleId: vehicleID,
            lineId: line.rawValue,
            stationName: "Test station",
            naptanId: stationID,
            platformName: platform,
            direction: direction,
            destinationName: destination,
            destinationNaptanId: destinationID,
            towards: towards,
            expectedArrival: expectedArrival,
            timeToStation: seconds,
            currentLocation: nil
        )
    }
}

private final class StationArrivalsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var queryValuesByPath: [String: [String: [String]]] = [:]
    private static let lock = NSLock()

    static func prepare(responses: [String: Data]) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses
        requestCounts = [:]
        queryValuesByPath = [:]
    }

    static func requestCount(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[path, default: 0]
    }

    static func queryValues(named name: String, for path: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return queryValuesByPath[path]?[name] ?? []
    }

    private static func response(for url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let path = url.path
        requestCounts[path, default: 0] += 1
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            guard let value = item.value else { continue }
            queryValuesByPath[path, default: [:]][item.name, default: []].append(value)
        }
        return responses[path]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let data = Self.response(for: url),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
