import CoreLocation
import Testing
@testable import TubeTrackUK

struct DepartureFavouriteTests {
    private var journey: DepartureFavourite {
        .init(outbound: .init(originID: "lewisham", destinationIDs: ["bank", "tower"], lineIDs: ["dlr"]))
    }
    @Test func nearestEndpointChoosesReturnAndHysteresisPreventsJitter() {
        var favourite = journey
        #expect(favourite.resolvedOrigin(distances: ["lewisham": 50, "bank": 8000]) == "lewisham")
        #expect(favourite.resolvedOrigin(distances: ["lewisham": 8000, "bank": 50]) == "bank")
        favourite.lastOriginID = "bank"
        #expect(favourite.resolvedOrigin(distances: ["lewisham": 4000, "bank": 4050]) == "bank")
        #expect(favourite.resolvedOrigin(distances: [:]) == "bank")
        #expect(favourite.resolvedOrigin(distances: ["lewisham": 90000, "bank": 50000]) == "bank")
    }
    @Test func eachDestinationReturnsToOriginWithInheritedServices() {
        let favourite = journey
        #expect(favourite.request(from: "bank") == .init(originID: "bank", destinationIDs: ["lewisham"], lineIDs: ["dlr"]))
        #expect(favourite.request(from: "tower").destinationIDs == ["lewisham"])
        #expect(favourite.request(from: "invalid") == favourite.outbound)
    }
    @Test func manualOverrideSurvivesSerializationAndIgnoresLocation() throws {
        var favourite = journey
        favourite.reverse(distances: ["lewisham": 20, "bank": 9000, "tower": 7000])
        #expect(favourite.manualOriginID == "tower")
        let restored = try JSONDecoder().decode(DepartureFavourite.self, from: JSONEncoder().encode(favourite))
        #expect(restored.resolvedOrigin(distances: ["lewisham": 1, "tower": 9999]) == "tower")
        favourite.reverse(distances: [:])
        #expect(favourite.manualOriginID == "lewisham")
        favourite.manualOriginID = nil
        #expect(favourite.resolvedOrigin(distances: ["lewisham": 9000, "bank": 10]) == "bank")
    }
    @Test func oldActivitiesDecodeAndCustomActivitiesFreezeTheirSelection() throws {
        let legacy = try JSONDecoder().decode(DepartureActivityAttributes.self, from: Data("{}".utf8))
        #expect(legacy.boardRequest == nil)
        let request = journey.request(from: "bank")
        let attributes = DepartureActivityAttributes(activityID: "test", stationHubID: "bank", stationName: "Bank",
            lineIDRaw: "custom-board", direction: "Calling at Lewisham", directionFilter: .any,
            startedAt: .now, hardEndsAt: .now.addingTimeInterval(3600), boardRequest: request)
        #expect(DeepLink(url: attributes.deepLink.url) == .board(request))
        #expect(try JSONDecoder().decode(DepartureActivityAttributes.self, from: JSONEncoder().encode(attributes)).boardRequest == request)
    }
    @MainActor @Test func localFavouritesAndLastTabPersistWithoutSavingDraftEdits() throws {
        let suite = "departures-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DepartureBoardStore(defaults: defaults)
        store.save(journey); store.tab = "favourites"
        var draft = try #require(store.favourites.first)
        draft.name = "Unsaved"
        let reopened = DepartureBoardStore(defaults: defaults)
        #expect(reopened.favourites.first?.name == "")
        #expect(reopened.tab == "favourites")
        store.save(draft)
        #expect(DepartureBoardStore(defaults: defaults).favourites.first?.name == "Unsaved")
        store.remove(draft.id)
        #expect(DepartureBoardStore(defaults: defaults).favourites.isEmpty)
    }
    @Test func directionFiltersPersistIndependentlyAndLegacyFavouritesStillDecode() throws {
        var favourite = journey
        let north = DepartureBoardRequest(originID: "lewisham", destinationIDs: ["bank"], lineIDs: ["dlr"], direction: "Northbound")
        let south = DepartureBoardRequest(originID: "lewisham", destinationIDs: [], lineIDs: ["dlr"], direction: "Southbound")
        favourite.setDirectionFilter(north)
        favourite.setDirectionFilter(south)
        let restored = try JSONDecoder().decode(DepartureFavourite.self, from: JSONEncoder().encode(favourite))
        #expect(restored.request(from: "lewisham", serviceID: "dlr", direction: "Northbound") == north)
        #expect(restored.request(from: "lewisham", serviceID: "dlr", direction: "Southbound") == south)
        #expect(restored.request(from: "bank", serviceID: "dlr", direction: "Southbound").destinationIDs == ["lewisham"])
        #expect(restored.request(from: "lewisham", serviceID: "national-rail:SE", direction: "Northbound").destinationIDs == ["bank", "tower"])
        var cleared = north
        cleared.destinationIDs = []
        favourite.setDirectionFilter(cleared)
        #expect(favourite.directionFilters?.count == 2)
        #expect(favourite.request(from: "lewisham", serviceID: "dlr", direction: "Northbound").destinationIDs.isEmpty == true)
        #expect(favourite.request(from: "lewisham", serviceID: "dlr", direction: "Southbound") == south)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(favourite)) as? [String: Any])
        legacy.removeValue(forKey: "directionFilters")
        let decoded = try JSONDecoder().decode(DepartureFavourite.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.directionFilters == nil)
        #expect(decoded.request(from: "lewisham", serviceID: "dlr", direction: "Northbound").destinationIDs == ["bank", "tower"])
    }

    @MainActor @Test func departureJourneyHandoffPreservesOtherEndpointAndDoesNotSearch() throws {
        let state = TubeAppState(monitorsConnectivity: false)
        state.graph = try TubeGraph.bundled()
        let stations = try #require(state.graph?.stations.filter { !NationalRailMap.isExclusiveStation($0.id) })
        let first = try #require(stations.first)
        let second = try #require(stations.first { ($0.hubID ?? $0.id) != (first.hubID ?? first.id) })
        let stop = DepartureStop(id: first.hubID ?? first.id, name: first.name,
            latitude: first.latitude, longitude: first.longitude, stopIDs: [first.id], lineIDs: first.lineIDs.map(\.rawValue))
        state.journeyPlanner.to = second
        #expect(state.prepareJourney(at: stop, asOrigin: true))
        #expect((state.journeyPlanner.from?.hubID ?? state.journeyPlanner.from?.id) == (first.hubID ?? first.id))
        #expect(state.journeyPlanner.to == second)
        #expect(state.journeyPlanner.searchID == nil)
        #expect(state.prepareJourney(at: stop, asOrigin: false))
        #expect(state.journeyPlanner.to != nil)
        #expect(state.journeyPlanner.from == nil)
        #expect(state.journeyPlanner.searchID == nil)
    }

    @Test func catalogueIncludesRailOnlyStationsAndAliases() {
        #expect(DepartureStop.bundled.first { $0.id == "nr:KTH" }?.railCodes == ["KTH"])
        #expect(DepartureStop.bundled.first { $0.id == "HUBBAN" }?.stopIDs.contains("940GZZDLBNK") == true)
    }
}


struct DepartureBoardDirectionGroupTests {
    private func arrival(_ id: String, line: String = "national-rail:SE", direction: String? = nil,
                         destination: String = "London Charing Cross", destinationID: String? = nil,
                         platform: String? = nil, seconds: Double = 60) -> TfLArrivalPrediction {
        .init(id: id, vehicleId: nil, lineId: line, stationName: nil, naptanId: nil,
              platformName: platform, direction: direction, destinationName: destination,
              destinationNaptanId: destinationID, towards: nil,
              expectedArrival: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
              timeToStation: nil, currentLocation: nil)
    }

    @Test func directionsCombineOperatorsAndKeepFivePerDirectionInTimeOrder() {
        let rows = (1...12).reversed().map { number in
            arrival("train-\(number)", line: number % 3 == 0 ? "national-rail:SN" : "national-rail:SE",
                    direction: number.isMultiple(of: 2) ? "southbound" : "northbound", seconds: Double(number * 60))
        }
        let groups = DepartureBoardDirectionGroup.groups(from: rows, origin: nil)
        #expect(groups.map(\.title) == ["Northbound", "Southbound"])
        #expect(groups.map { $0.arrivals.count } == [6, 6])
        #expect(groups[0].arrivals.prefix(5).map(\.id) == ["train-1", "train-3", "train-5", "train-7", "train-9"])
        #expect(groups[1].arrivals.prefix(5).map(\.id) == ["train-2", "train-4", "train-6", "train-8", "train-10"])
    }

    @Test func islandGardensSeparatesBankAndLewishamUsingKnownDestinations() throws {
        let origin = try #require(DepartureStop.bundled.first { $0.name == "Island Gardens" })
        let rows = [arrival("lewisham", line: "dlr", direction: "outbound", destination: "Lewisham DLR Station", platform: "1"),
                    arrival("bank", line: "dlr", direction: "inbound", destination: "Bank", destinationID: "940GZZDLBNK", platform: "2")]
        let groups = DepartureBoardDirectionGroup.groups(from: rows, origin: origin)
        #expect(groups.map(\.title) == ["Northbound", "Southbound"])
        #expect(groups.map { $0.arrivals.map(\.id) } == [["bank"], ["lewisham"]])
    }

    @Test func reportedDirectionWinsAndUnknownDirectionsRemainVisible() {
        let rows = [arrival("tube", line: "northern", direction: "inbound", platform: "Southbound - Platform 1"),
                    arrival("river", line: "rb1", direction: "eastbound"),
                    arrival("platform", platform: "Platform 2"), arrival("unknown")]
        let groups = DepartureBoardDirectionGroup.groups(from: rows, origin: nil)
        #expect(groups.map(\.title) == ["Southbound", "Eastbound", "Other departures", "Platform 2"])
        #expect(groups.flatMap(\.arrivals).count == rows.count)
    }
}


struct DepartureDistanceTests {
    @Test func distancesUseMilesIncludingShortDistances() {
        #expect(NearbyDistanceFormatter.string(from: 0) == "<0.1 mi")
        #expect(NearbyDistanceFormatter.string(from: 100) == "<0.1 mi")
        #expect(NearbyDistanceFormatter.string(from: 804.672) == "0.5 mi")
        #expect(NearbyDistanceFormatter.string(from: 1_609.344) == "1.0 mi")
        #expect(NearbyDistanceFormatter.string(from: 10_700) == "6.6 mi")
        #expect(NearbyDistanceFormatter.string(from: .nan) == "Distance unavailable")
    }

    @Test func directionsTargetTheStationThroughTheSystemNavigationScheme() throws {
        let url = try #require(DepartureDirections.url(latitude: 51.497, longitude: -0.049))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "geo-navigation")
        #expect(components.path == "/directions")
        #expect(components.queryItems == [URLQueryItem(name: "destination", value: "51.497,-0.049")])
        #expect(DepartureDirections.url(latitude: .nan, longitude: 0) == nil)
        #expect(DepartureDirections.url(latitude: 91, longitude: 0) == nil)
    }
}


struct DepartureServiceSelectionTests {
    private let options = [DepartureServiceOption(id: "dlr", name: "DLR"),
                           DepartureServiceOption(id: "national-rail:SE", name: "Southeastern")]
    @MainActor @Test func lewishamHubIncludesTheRailwayOperatorWhenOpenedFromDLR() throws {
        let stop = try #require(DepartureStop.bundled.first { $0.id == "HUBLEW" })
        let operators = DepartureServiceOption.mappedRailwayServices(for: stop)
        #expect(operators.contains { $0.id == "national-rail:SE" && $0.name == "Southeastern" })
    }
    @Test func tappedRoundelSelectsItsServiceAndManualSelectionWins() {
        #expect(DepartureServiceOption.selectedID(options: options, selected: nil, preferred: "dlr") == "dlr")
        #expect(DepartureServiceOption.selectedID(options: options, selected: nil, preferred: "southeastern") == "national-rail:SE")
        #expect(DepartureServiceOption.selectedID(options: options, selected: "dlr", preferred: "southeastern") == "dlr")
    }
    @Test func trackingIdentityIncludesLineDirectionAndDestinationFilter() throws {
        let north = DepartureBoardRequest(originID: "HUBLEW", destinationIDs: ["HUBBAN"], lineIDs: ["dlr"], direction: "Northbound")
        let south = DepartureBoardRequest(originID: "HUBLEW", destinationIDs: ["HUBBAN"], lineIDs: ["dlr"], direction: "Southbound")
        #expect(north != south && north.id != south.id)
        #expect(DeepLink(url: DeepLink.board(north).url) == .board(north))
        #expect(try JSONDecoder().decode(DepartureBoardRequest.self, from: JSONEncoder().encode(north)) == north)
        let legacy = try JSONDecoder().decode(DepartureBoardRequest.self, from: Data(#"{"originID":"HUBLEW","destinationIDs":[],"lineIDs":[]}"#.utf8))
        #expect(legacy.direction == nil)
    }
}
