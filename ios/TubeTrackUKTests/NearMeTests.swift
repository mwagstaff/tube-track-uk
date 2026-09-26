import CoreLocation
import Testing
@testable import TubeTrackUK

struct NearMeTests {
    @Test func mapLocationFocusKeepsLocationsInsideTheNetworkBoundary() throws {
        let graph = try TubeGraph.bundled()
        let location = CLLocation(latitude: 51.5033, longitude: -0.1147)

        let request = try #require(MapLocationFocusPolicy.request(
            for: location,
            in: graph,
            id: 7
        ))

        #expect(request.id == 7)
        #expect(request.snappedStationID == nil)
        #expect(request.latitude == location.coordinate.latitude)
        #expect(request.longitude == location.coordinate.longitude)
    }

    @Test func distantLocationDoesNotAutomaticallyMoveTheMap() throws {
        let graph = try TubeGraph.bundled()
        let location = CLLocation(latitude: 55.9533, longitude: -3.1883)
        #expect(MapLocationFocusPolicy.request(for: location, in: graph, id: 1, automatic: true) == nil)

        let explicit = try #require(MapLocationFocusPolicy.request(for: location, in: graph, id: 2))
        #expect(explicit.latitude == location.coordinate.latitude)
        #expect(explicit.longitude == location.coordinate.longitude)
        #expect(explicit.snappedStationID == nil)
    }

    @Test func firstMapOpeningCentersNearElmersEnd() throws {
        let graph = try TubeGraph.bundled()
        let location = CLLocation(latitude: 51.3985, longitude: -0.0495)
        let request = try #require(MapLocationFocusPolicy.request(
            for: location, in: graph, id: 3, automatic: true
        ))
        #expect(request.latitude == location.coordinate.latitude)
        #expect(request.longitude == location.coordinate.longitude)
    }

    @Test func nearbyLocationsBeyondTheMapBoundaryAreEligibleButDistantOnesAreNot() throws {
        let graph = try TubeGraph.bundled()
        let northernmost = try #require(graph.stations.max { $0.latitude < $1.latitude })
        let nearby = CLLocation(latitude: northernmost.latitude + 0.02, longitude: northernmost.longitude)
        let distant = CLLocation(latitude: northernmost.latitude + 0.10, longitude: northernmost.longitude)
        #expect(MapLocationFocusPolicy.request(for: nearby, in: graph, id: 4, automatic: true) != nil)
        #expect(MapLocationFocusPolicy.request(for: distant, in: graph, id: 5, automatic: true) == nil)
    }

    @Test func staleOrInaccurateFixDoesNotMoveTheMap() throws {
        let graph = try TubeGraph.bundled()
        for (accuracy, age) in [(10.0, -300.0), (2_000.0, 0.0), (-1.0, 0.0)] {
            let location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 51.3985, longitude: -0.0495),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                timestamp: Date.now.addingTimeInterval(age)
            )
            #expect(MapLocationFocusPolicy.request(for: location, in: graph, id: 1) == nil)
        }
    }

    @Test func departureWaitingCopyMatchesTheAutomaticRetryState() {
        #expect(LiveDepartureWaitingCopy.title == "Waiting for live data")
        #expect(
            LiveDepartureWaitingCopy.message
                == "Waiting for live departures. They should arrive shortly."
        )
    }

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

    @Test func arrivalRefreshPolicyPollsOnlyStationsInTheViewport() {
        let nearby = [
            NearbyStation(
                station: station(id: "one", name: "One", latitude: 51.501, hubID: nil),
                distance: 100
            ),
            NearbyStation(
                station: station(id: "two", name: "Two", latitude: 51.502, hubID: nil),
                distance: 200
            ),
            NearbyStation(
                station: station(id: "three", name: "Three", latitude: 51.503, hubID: nil),
                distance: 300
            ),
            NearbyStation(
                station: station(id: "four", name: "Four", latitude: 51.504, hubID: nil),
                distance: 400
            ),
        ]

        let visible = NearMeArrivalRefreshPolicy.visibleStations(
            from: nearby,
            visibleStationIDs: ["two", "three"]
        )
        let manualFallback = NearMeArrivalRefreshPolicy.stationsForManualRefresh(
            from: nearby,
            visibleStationIDs: [],
            fallbackCount: 3
        )

        #expect(visible.map(\.id) == ["two", "three"])
        #expect(manualFallback.map(\.id) == ["one", "two", "three"])
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
            arrival(id: "tram", line: .tram, platform: nil, direction: "outbound", seconds: 45),
        ]

        let groups = StationDepartureGroup.groups(from: arrivals)
        let eastbound = try #require(groups.first {
            $0.lineID == .district && $0.direction == "Eastbound"
        })

        #expect(groups.count == 4)
        #expect(eastbound.arrivals.map(\.id) == ["soon", "later"])
        #expect(groups.contains { $0.lineID == .district && $0.direction == "Westbound" })
        #expect(groups.contains { $0.lineID == .piccadilly && $0.direction == "Inbound" })
        #expect(groups.contains { $0.lineID == .tram && $0.direction == "Outbound" })
    }

    @Test func elizabethLineUsesPassengerFacingDirectionsAndPlatformLabels() throws {
        let eastbound = arrival(
            id: "eastbound",
            line: .elizabeth,
            platform: " A ",
            direction: "inbound",
            seconds: 60
        )
        let westbound = arrival(
            id: "westbound",
            line: .elizabeth,
            platform: "B",
            direction: "outbound",
            seconds: 120
        )

        let groups = StationDepartureGroup.groups(from: [eastbound, westbound])

        #expect(groups.contains { $0.direction == "Eastbound" })
        #expect(groups.contains { $0.direction == "Westbound" })
        #expect(StationDepartureMetadata.platformLabel(for: eastbound) == "Platform A")
        #expect(StationDepartureMetadata.platformLabel(for: westbound) == "Platform B")
    }

    @Test func plannedDisruptionsGroupByEachLineServingANearbyStation() throws {
        let start = try #require(
            LondonRailDate.calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 29, hour: 8)
            )
        )
        let districtWork = engineeringWork(
            id: "district-later",
            lineIDs: [.district],
            startDate: start.addingTimeInterval(3_600)
        )
        let sharedWork = engineeringWork(
            id: "shared-earlier",
            lineIDs: [.district, .piccadilly],
            startDate: start
        )

        let groups = NearbyLineDisruptionGroup.groups(
            lineIDs: [.district, .piccadilly, .jubilee],
            works: [districtWork, sharedWork]
        )

        #expect(groups.map(\.lineID) == [.district, .piccadilly, .jubilee])
        #expect(groups[0].works.map(\.id) == ["shared-earlier", "district-later"])
        #expect(groups[1].works.map(\.id) == ["shared-earlier"])
        #expect(groups[2].works.isEmpty)
    }

    @Test @MainActor func plannedDisruptionMapFocusPreservesMapStyleAndEnablesHighlighting() throws {
        let start = try #require(
            LondonRailDate.calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 29, hour: 8)
            )
        )
        let plannedWork = engineeringWork(
            id: "district-work",
            lineIDs: [.district],
            startDate: start
        )
        let appState = TubeAppState()
        appState.engineeringWorks = [plannedWork]
        appState.selectedTab = .nearMe
        appState.mapPresentationMode = .realWorld
        appState.disruptionDisplayMode = .normal
        appState.setDisruptionDateSelection(.custom(start))

        appState.focus(on: plannedWork, in: .map)

        #expect(appState.selectedTab == .map)
        #expect(appState.mapPresentationMode == .realWorld)
        #expect(appState.disruptionDisplayMode == .issues)
        #expect(appState.selectedEngineeringWorkID == plannedWork.id)
        #expect(appState.focusedLineIDs == [.district])
        #expect(appState.focusedSegmentIDs == ["district-work-segment"])
    }

    @Test @MainActor func closestStationRouteOpensNearMeWithAConsumableFocus() {
        let appState = TubeAppState()
        let closestStation = station(
            id: "closest",
            name: "Closest",
            latitude: 51.501,
            hubID: nil
        )

        appState.showNearMe(focusedOn: closestStation)

        let generation = appState.nearMeFocusGeneration
        #expect(appState.selectedTab == .nearMe)
        #expect(appState.nearMeFocusedStationID == closestStation.id)

        appState.consumeNearMeFocus(generation: generation)

        #expect(appState.nearMeFocusedStationID == nil)
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

    private func engineeringWork(
        id: String,
        lineIDs: [TubeLineID],
        startDate: Date
    ) -> EngineeringWork {
        EngineeringWork(
            id: id,
            title: "Part closure",
            detail: "A full planned-disruption message.",
            lineIDs: lineIDs,
            affectedStationIDs: [],
            affectedSegmentIDs: ["\(id)-segment"],
            startDate: startDate,
            endDate: startDate.addingTimeInterval(7_200),
            source: .unifiedAPI,
            fetchedAt: startDate,
            confidence: .lineOnly
        )
    }
}
