import CoreGraphics
import Foundation
import MapKit
import Testing
@testable import TubeTrackUK

struct TubeTrackUKTests {
    @Test func selectingMapReturnsFromTheDisruptionsScreen() {
        var navigation = MapTabNavigationState()

        navigation.showDisruptions()
        #expect(navigation.showsDisruptions)

        navigation.handleTabSelection(.nearMe)
        #expect(navigation.showsDisruptions)

        navigation.handleTabSelection(.map)
        #expect(!navigation.showsDisruptions)
    }

    @Test @MainActor func appearanceDefaultsToSystemAndPersistsOverrides() throws {
        let suiteName = "TubeTrackUKTests.Appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialState = TubeAppState(defaults: defaults)
        #expect(initialState.appearanceMode == .system)
        #expect(initialState.preferredColorScheme == nil)

        initialState.appearanceMode = .dark
        let restoredDarkState = TubeAppState(defaults: defaults)
        #expect(restoredDarkState.appearanceMode == .dark)
        #expect(restoredDarkState.preferredColorScheme == .dark)

        restoredDarkState.appearanceMode = .light
        let restoredLightState = TubeAppState(defaults: defaults)
        #expect(restoredLightState.appearanceMode == .light)
        #expect(restoredLightState.preferredColorScheme == .light)
    }

    @Test func allTubeLinesHaveDisplayNames() {
        #expect(TubeLineID.allCases.count == 20)
        #expect(TubeLineID.undergroundCases.count == 11)
        #expect(TubeLineID.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(TubeLineID.dlr.modeName == "dlr")
        #expect(TubeLineID.elizabeth.modeName == "elizabeth-line")
        #expect(TubeLineID.tram.displayName == "London Trams")
        #expect(TubeLineID.tram.modeName == "tram")
        #expect(!TubeLineID.tram.isUnderground)
        #expect(TubeLineID.tram.usesParallelSchematicStroke)
        #expect(TubeLineID.liberty.modeName == "overground")
        #expect(TubeLineID.windrush.modeName == "overground")
        #expect(TubeLineID.dlr.supportsEstimatedTrains)
        #expect(TubeLineID.tram.supportsEstimatedTrains)
        #expect(TubeLineID.elizabeth.supportsEstimatedTrains)
        #expect(TubeLineID.central.liveTrainMarkerAssetName == "TrainMarkerTube")
        #expect(TubeLineID.dlr.liveTrainMarkerAssetName == "TrainMarkerDLR")
        #expect(TubeLineID.lioness.liveTrainMarkerAssetName == "TrainMarkerOverground")
        #expect(TubeLineID.elizabeth.liveTrainMarkerAssetName == "TrainMarkerOverground")
        #expect(TubeLineID.tram.liveTrainMarkerAssetName == "TrainMarkerTram")
    }

    @Test func bundledGraphHasCompleteConnectedData() throws {
        let graph = try TubeGraph.bundled()
        #expect(graph.lines.count == 20)
        #expect(graph.stations.count == 509)
        #expect(graph.segments.count == 618)
        #expect(graph.segments.allSatisfy { $0.geographicPoints.count >= 2 })
        #expect(graph.segments.filter { $0.geographicPoints.count > 2 }.count > 340)
        #expect(graph.source.attribution.contains("OpenStreetMap contributors"))
        #expect(graph.segments.allSatisfy {
            graph.stationsByID[$0.fromStationID] != nil && graph.stationsByID[$0.toStationID] != nil
        })
        #expect(graph.line(.dlr)?.routes.count == 5)
        #expect(graph.line(.elizabeth)?.routes.count == 9)
        #expect(graph.line(.tram)?.routes.count == 6)
        #expect(graph.segments(for: .dlr).count == 46)
        #expect(graph.segments(for: .elizabeth).count == 42)
        #expect(graph.segments(for: .tram).count == 40)
        #expect(graph.segments(for: .liberty).count == 2)
        #expect(graph.segments(for: .lioness).count == 18)
        #expect(graph.segments(for: .mildmay).count == 27)
        #expect(graph.segments(for: .suffragette).count == 12)
        #expect(graph.segments(for: .weaver).count == 25)
        #expect(graph.segments(for: .windrush).count == 28)
        let bankStops = graph.stations.filter { $0.hubID == "HUBBAN" }
        #expect(bankStops.contains { $0.lineIDs.contains(.dlr) })
        #expect(bankStops.contains { $0.lineIDs.contains(.central) })
        #expect(bankStops.allSatisfy { $0.interchange })

        let wimbledonTram = try #require(graph.stationsByID["940GZZCRWMB"])
        #expect(Set(graph.lineIDs(at: wimbledonTram)) == [.district, .tram])
    }

    @Test func realWorldRailLinesUseDetailedTrackGeometry() throws {
        let graph = try TubeGraph.bundled()

        for lineID in [TubeLineID.dlr, .elizabeth, .tram] {
            let segments = graph.segments(for: lineID)
            let detailedSegments = segments.filter { $0.geographicPoints.count > 2 }
            let contouredSegments = detailedSegments.filter {
                maximumTrackDeviation(from: $0.geographicPoints) >= 3
            }

            // A station-to-station fallback has exactly two points and renders as
            // the sharp chords seen in the Real World view. OSM track routing
            // supplies intermediate railway nodes and genuine off-chord contours.
            #expect(!segments.isEmpty)
            #expect(detailedSegments.count * 10 >= segments.count * 9)
            #expect(contouredSegments.count * 4 >= segments.count * 3)
            #expect(segments.reduce(0) { $0 + $1.geographicPoints.count } >= segments.count * 5)
        }

        for lineID in [
            TubeLineID.liberty, .lioness, .mildmay, .suffragette, .weaver, .windrush,
        ] {
            let segments = graph.segments(for: lineID)
            let detailedSegments = segments.filter { $0.geographicPoints.count > 2 }
            let contouredSegments = segments.filter {
                maximumTrackDeviation(from: $0.geographicPoints) >= 3
            }

            #expect(!segments.isEmpty)
            #expect(detailedSegments.count * 5 >= segments.count * 4)
            #expect(contouredSegments.count * 4 >= segments.count * 3)
            #expect(segments.reduce(0) { $0 + $1.geographicPoints.count } >= segments.count * 5)
        }
    }

    @Test func realWorldRailLinesAnchorEverySegmentAtItsStations() throws {
        let graph = try TubeGraph.bundled()
        let stationsByID = graph.stationsByID

        for segment in graph.segments {
            let from = try #require(stationsByID[segment.fromStationID])
            let to = try #require(stationsByID[segment.toStationID])
            let coordinates = RealWorldRouteGeometry.anchoredCoordinates(
                for: segment,
                stationsByID: stationsByID
            )

            #expect(coordinates.first?.latitude == from.latitude)
            #expect(coordinates.first?.longitude == from.longitude)
            #expect(coordinates.last?.latitude == to.latitude)
            #expect(coordinates.last?.longitude == to.longitude)
        }
    }

    @Test func realWorldMapDisplaysEveryPhysicalStationHub() throws {
        let graph = try TubeGraph.bundled()
        let displayed = RealWorldStationDisplay.stations(
            in: graph,
            selectedStationID: nil
        )
        let displayedIDs = Set(displayed.map(\.id))
        let physicalHubIDs = Set(graph.stations.map { $0.hubID ?? $0.id })

        #expect(displayed.count == physicalHubIDs.count)
        #expect(displayedIDs.contains("940GZZLUSWF")) // South Woodford, Central line
        #expect(displayedIDs.contains("910GRDNGSTN")) // Reading, Elizabeth line
        #expect(displayedIDs.contains("940GZZDLABR")) // Abbey Road, DLR
        #expect(displayedIDs.contains("940GZZCRNWA")) // New Addington, London Trams

        let selectedDLRStation = "940GZZDLBNK"
        let withSelection = RealWorldStationDisplay.stations(
            in: graph,
            selectedStationID: selectedDLRStation
        )
        #expect(withSelection.contains { $0.id == selectedDLRStation })

        let selectedTramStation = "940GZZCRWMB"
        let withTramSelection = RealWorldStationDisplay.stations(
            in: graph,
            selectedStationID: selectedTramStation
        )
        #expect(withTramSelection.contains { $0.id == selectedTramStation })
    }

    @Test func disruptionResolverFindsCamdenToEdgwareSection() throws {
        let graph = try TubeGraph.bundled()
        let resolver = DisruptionResolver(repository: TubeNetworkRepository(graph: graph))
        let result = resolver.resolve(status(reason: "No service between Camden Town and Edgware"), lineID: .northern)

        #expect(result.confidence == .inferred)
        #expect(!result.affectedSegmentIDs.isEmpty)
        #expect(result.affectedSegmentIDs.count < graph.segments(for: .northern).count)
        #expect(result.affectedStationIDs.contains(graph.stations.first { $0.name == "Camden Town" }?.id ?? ""))
        #expect(result.affectedStationIDs.contains(graph.stations.first { $0.name == "Edgware" }?.id ?? ""))
    }

    @Test func ambiguousDisruptionFallsBackToWholeLine() throws {
        let graph = try TubeGraph.bundled()
        let resolver = DisruptionResolver(repository: TubeNetworkRepository(graph: graph))
        let result = resolver.resolve(status(reason: "Severe delays due to an earlier signal failure"), lineID: .victoria)

        #expect(result.confidence == .lineOnly)
        #expect(result.affectedSegmentIDs.count == graph.segments(for: .victoria).count)
    }

    @Test func structuredTramDisruptionPreservesTheOrderedCroydonLoopSection() throws {
        let graph = try TubeGraph.bundled()
        let repository = TubeNetworkRepository(graph: graph)
        let resolver = DisruptionResolver(repository: repository)
        let stopIDs = [
            "940GZZCRRVC", // Reeves Corner
            "940GZZCRCTR", // Centrale
            "940GZZCRWCR", // West Croydon
            "940GZZCRWEL", // Wellesley Road
            "940GZZCRECR", // East Croydon
        ]
        let route = TfLDisruptedRoute(
            id: "tram-loop-inbound",
            name: "Wimbledon Tram Stop - Beckenham Junction Tram Stop",
            direction: "inbound",
            originationName: "Wimbledon Tram Stop",
            destinationName: "Beckenham Junction Tram Stop",
            isEntireRouteSection: false,
            routeSectionNaptanEntrySequence: stopIDs.enumerated().map { index, stationID in
                TfLRouteStopEntry(
                    ordinal: index,
                    stopPoint: TfLStopPoint(
                        naptanId: stationID,
                        id: stationID,
                        commonName: nil,
                        lat: nil,
                        lon: nil
                    )
                )
            }
        )
        let status = TfLStatusEntry(
            id: 0,
            statusSeverity: 5,
            statusSeverityDescription: "Part Closure",
            reason: "No service between Reeves Corner and East Croydon",
            validityPeriods: nil,
            disruption: TfLDisruption(
                category: "RealTime",
                categoryDescription: "RealTime",
                description: nil,
                affectedRoutes: [route],
                affectedStops: nil,
                closureText: nil
            )
        )

        let result = resolver.resolve(status, lineID: .tram)
        let expectedSegmentIDs = Set(zip(stopIDs, stopIDs.dropFirst()).compactMap {
            repository.segment(between: $0.0, and: $0.1, on: .tram)?.id
        })

        #expect(result.confidence == .exact)
        #expect(result.affectedStationIDs == Set(stopIDs))
        #expect(expectedSegmentIDs.count == stopIDs.count - 1)
        #expect(result.affectedSegmentIDs == expectedSegmentIDs)
    }

    @Test func inferredTramDisruptionFollowsTheOneWayCroydonLoop() throws {
        let graph = try TubeGraph.bundled()
        let repository = TubeNetworkRepository(graph: graph)
        let resolver = DisruptionResolver(repository: repository)
        let stopIDs = [
            "940GZZCRCHR", // Church Street
            "940GZZCRCTR", // Centrale
            "940GZZCRWCR", // West Croydon
            "940GZZCRWEL", // Wellesley Road
        ]

        let result = resolver.resolve(
            status(reason: "No service between Church Street Tram Stop and Wellesley Road Tram Stop"),
            lineID: .tram
        )
        let expectedSegmentIDs = Set(zip(stopIDs, stopIDs.dropFirst()).compactMap {
            repository.segment(between: $0.0, and: $0.1, on: .tram)?.id
        })

        #expect(result.confidence == .inferred)
        #expect(expectedSegmentIDs.count == stopIDs.count - 1)
        #expect(result.affectedSegmentIDs == expectedSegmentIDs)
    }

    @Test func disruptionRowsHaveStableDistinctIDsWhenTfLReusesStatusID() throws {
        let graph = try TubeGraph.bundled()
        let resolver = DisruptionResolver(repository: TubeNetworkRepository(graph: graph))
        let first = resolver.resolve(status(reason: "Minor delays between White City and Ealing Broadway"), lineID: .central)
        let second = resolver.resolve(status(reason: "Minor delays between Leytonstone and Epping"), lineID: .central)

        #expect(first.id != second.id)
        #expect(first.id == resolver.resolve(status(reason: "Minor delays between White City and Ealing Broadway"), lineID: .central).id)
    }

    @Test func disruptionSeveritiesMapToUserFacingCategories() {
        for severity in [1, 2, 3, 4, 5, 11, 16, 20] {
            #expect(disruption(severity: severity).category == .closures)
        }
        #expect(disruption(severity: 6).category == .severeDelays)
        #expect(disruption(severity: 9).category == .minorDelays)
        #expect(disruption(severity: 7).category == .other)
        #expect(disruption(severity: 19).category == .other)
    }

    @Test @MainActor func defaultMapMutesClosuresAndSevereDelays() {
        let appState = TubeAppState()
        let closure = disruption(id: "closure", severity: 5, segmentID: "closure-segment")
        let severe = disruption(id: "severe", severity: 6, segmentID: "severe-segment")
        let minor = disruption(id: "minor", severity: 9, segmentID: "minor-segment")
        appState.disruptions = [closure, severe, minor]

        #expect(appState.disruptionDisplayMode == .normal)
        #expect(appState.highlightedDisruptionCategories == [.closures, .severeDelays])
        #expect(appState.highlightedDisruptions.map(\.id) == ["closure", "severe"])
        #expect(appState.activeAffectedSegmentIDs == ["closure-segment", "severe-segment"])

        appState.setDisruptionCategory(.minorDelays, highlighted: true)
        #expect(appState.activeAffectedSegmentIDs.contains("minor-segment"))

        appState.select(disruption: minor)
        appState.setDisruptionCategory(.minorDelays, highlighted: false)
        #expect(appState.selectedDisruptionID == nil)
        #expect(appState.selectedLineID == nil)
    }

    @Test @MainActor func stationSelectionPreservesTheTappedLineAtSplitInterchanges() throws {
        let graph = try TubeGraph.bundled()
        let barkingSuffragette = try #require(
            graph.stationsByID["910GBARKING"]
        )
        let westHam = try #require(
            graph.stationsByID["940GZZLUWHM"]
        )
        let westBromptonDistrict = try #require(
            graph.stationsByID["940GZZLUWBN"]
        )
        let westBromptonMildmay = try #require(
            graph.stationsByID["910GWBRMPTN"]
        )
        let victoria = try #require(graph.stationsByID["940GZZLUVIC"])
        let southKensington = try #require(graph.stationsByID["940GZZLUSKS"])
        let appState = TubeAppState()
        appState.graph = graph

        appState.select(station: barkingSuffragette)
        #expect(appState.selectedStationDepartureLineID == .suffragette)

        appState.select(
            station: westHam,
            preferredDepartureLineID: .jubilee
        )
        #expect(appState.selectedStationDepartureLineID == .jubilee)

        appState.select(
            station: westBromptonMildmay,
            preferredDepartureLineID: .mildmay
        )
        #expect(appState.selectedStationDepartureLineID == .mildmay)

        appState.select(
            station: victoria,
            preferredDepartureLineID: .victoria
        )
        #expect(appState.selectedStationDepartureLineID == .victoria)

        appState.select(
            station: southKensington,
            preferredDepartureLineID: .piccadilly
        )
        #expect(appState.selectedStationDepartureLineID == .piccadilly)
        appState.selectDepartureLine(.circle)
        #expect(appState.selectedStationDepartureLineID == .circle)

        appState.select(
            station: westBromptonDistrict,
            preferredDepartureLineID: .central
        )
        #expect(appState.selectedStationDepartureLineID == nil)

        appState.clearStationSelection()
        #expect(appState.selectedStationDepartureLineID == nil)
    }

    @Test func normalDisplayShowsEveryLineAndIssuesEmphasizesAffectedSections() {
        #expect(!DisruptionDisplayMode.normal.mutesSegment(isAffected: true))
        #expect(!DisruptionDisplayMode.normal.mutesSegment(isAffected: false))
        #expect(!DisruptionDisplayMode.issues.mutesSegment(isAffected: true))
        #expect(DisruptionDisplayMode.issues.mutesSegment(isAffected: false))
    }

    @Test @MainActor func selectingADisruptionFocusesOnlyItsRelevantLineSection() throws {
        let graph = try TubeGraph.bundled()
        let centralSegment = try #require(graph.segments(for: .central).first)
        let victoriaSegment = try #require(graph.segments(for: .victoria).first { segment in
            graph.stationsByID[segment.fromStationID]?.lineIDs.contains(.central) == false
                && graph.stationsByID[segment.toStationID]?.lineIDs.contains(.central) == false
        })
        let selected = ResolvedDisruption(
            id: "selected-central-section",
            lineID: .central,
            title: "Part suspension",
            reason: "Affects one Central line section",
            severity: 5,
            affectedStationIDs: [
                centralSegment.fromStationID,
                centralSegment.toStationID,
                victoriaSegment.fromStationID,
                victoriaSegment.toStationID,
            ],
            affectedSegmentIDs: [centralSegment.id, victoriaSegment.id],
            confidence: .exact
        )
        let appState = TubeAppState()
        appState.graph = graph
        appState.disruptions = [selected]

        appState.select(disruption: selected)

        #expect(appState.focusedLineIDs == [.central])
        #expect(appState.focusedSegmentIDs == [centralSegment.id])
        #expect(appState.focusedStationIDs == [
            centralSegment.fromStationID,
            centralSegment.toStationID,
        ])
        #expect(appState.activeAffectedSegmentIDs == [centralSegment.id])
        #expect(appState.activeAffectedStationIDs == appState.focusedStationIDs)
        #expect(appState.disruptionSelectionGeneration == 1)

        appState.select(disruption: selected)
        #expect(appState.disruptionSelectionGeneration == 2)
    }

    @Test @MainActor func resettingTheMapClearsADisruptionAndEveryMapMode() {
        let disruption = disruption(id: "district-closure", severity: 5, segmentID: "district-segment")
        let appState = TubeAppState()
        appState.disruptions = [disruption]

        appState.select(disruption: disruption)
        appState.mobileCoverageMode = .allUsable
        appState.selectedMapNetworkStat = .minorDelays

        #expect(appState.disruptionDisplayMode == .issues)
        #expect(appState.selectedDisruptionID == disruption.id)

        let generation = appState.resetMapState(source: .disruptionCard)

        #expect(appState.selectedDisruptionID == nil)
        #expect(appState.selectedLineID == nil)
        #expect(appState.focusedSegmentIDs.isEmpty)
        #expect(appState.focusedStationIDs.isEmpty)
        #expect(appState.focusedLineIDs.isEmpty)
        #expect(appState.focusedResolutionConfidence == nil)
        #expect(appState.disruptionDisplayMode == .normal)
        #expect(appState.selectedMapNetworkStat == nil)
        #expect(appState.mobileCoverageMode == .off)
        #expect(generation == 1)
        #expect(appState.mapResetGeneration == 1)
        #expect(!MapNetworkRouteStyling.mutesSegment(
            lineID: .district,
            isAffected: true,
            isFeaturedSection: false,
            selectedFilter: appState.selectedMapNetworkStat,
            featuredLineIDs: [],
            sectionLineIDs: [],
            closedLineIDs: [],
            disruptionDisplayMode: appState.disruptionDisplayMode
        ))
    }

    @Test func disruptionWithoutAResolvedSectionFocusesItsRelevantLine() throws {
        let graph = try TubeGraph.bundled()
        let disruption = ResolvedDisruption(
            id: "line-only",
            lineID: .victoria,
            title: "Severe delays",
            reason: "Whole line affected",
            severity: 6,
            affectedStationIDs: [],
            affectedSegmentIDs: [],
            confidence: .lineOnly
        )

        let focus = MapDisruptionFocus(disruption: disruption, graph: graph)

        #expect(focus.lineIDs == [.victoria])
        #expect(focus.segmentIDs == Set(graph.segments(for: .victoria).map(\.id)))
        #expect(!focus.stationIDs.isEmpty)
        #expect(focus.confidence == .lineOnly)
    }

    @Test @MainActor func enablingDisruptionHighlightsPreservesAnExistingCategoryChoice() {
        let appState = TubeAppState()
        appState.disruptionDisplayMode = .normal
        appState.highlightedDisruptionCategories = [.minorDelays]

        appState.enableDisruptionHighlighting()

        #expect(appState.disruptionDisplayMode == .issues)
        #expect(appState.highlightedDisruptionCategories == [.minorDelays])

        appState.disruptionDisplayMode = .normal
        appState.highlightedDisruptionCategories = []

        appState.enableDisruptionHighlighting()

        #expect(appState.disruptionDisplayMode == .issues)
        #expect(appState.highlightedDisruptionCategories == DisruptionCategory.defaultHighlighted)
    }

    @Test @MainActor func highlightingAllDisruptionsSelectsEveryCategoryAndRequestsCameraFocus() {
        let appState = TubeAppState()
        appState.highlightedDisruptionCategories = [.closures]
        appState.selectedMapNetworkStat = .goodService

        appState.highlightAllDisruptionsOnMap()

        #expect(appState.disruptionDisplayMode == .issues)
        #expect(appState.selectedMapNetworkStat == .disrupted)
        #expect(appState.disruptionHighlightScope == .all)
        #expect(appState.highlightedDisruptionCategories == [.closures])
        #expect(appState.disruptionOverviewFocusGeneration == 1)

        appState.highlightAllDisruptionsOnMap()
        #expect(appState.disruptionOverviewFocusGeneration == 2)
    }

    @Test @MainActor func allDisruptionHighlightButtonTogglesBackToEveryLine() {
        let appState = TubeAppState()

        appState.toggleAllDisruptionsOnMap()

        #expect(appState.disruptionHighlightScope == .all)
        #expect(appState.disruptionDisplayMode == .issues)
        #expect(appState.disruptionOverviewFocusGeneration == 1)

        appState.toggleAllDisruptionsOnMap()

        #expect(appState.disruptionHighlightScope == nil)
        #expect(appState.selectedMapNetworkStat == nil)
        #expect(appState.disruptionDisplayMode == .normal)
        #expect(appState.disruptionOverviewFocusGeneration == 1)
    }

    @Test @MainActor func disruptionHighlightToggleCyclesAllMajorMinorAndOff() {
        let appState = TubeAppState()

        appState.toggleDisruptionHighlighting()
        #expect(appState.disruptionHighlightScope == .all)
        #expect(appState.selectedMapNetworkStat == .disrupted)
        #expect(appState.disruptionDisplayMode == .issues)

        appState.toggleDisruptionHighlighting()
        #expect(appState.disruptionHighlightScope == .major)
        #expect(appState.selectedMapNetworkStat == .majorIssues)

        appState.toggleDisruptionHighlighting()
        #expect(appState.disruptionHighlightScope == .minor)
        #expect(appState.selectedMapNetworkStat == .minorDelays)

        appState.toggleDisruptionHighlighting()
        #expect(appState.disruptionHighlightScope == nil)
        #expect(appState.selectedMapNetworkStat == nil)
        #expect(appState.disruptionDisplayMode == .normal)

        appState.toggleDisruptionHighlighting()
        #expect(appState.disruptionHighlightScope == .all)
    }

    @Test @MainActor func disruptedStatsKeepTheWorksControlSelected() {
        let appState = TubeAppState()

        appState.selectedMapNetworkStat = .minorDelays
        #expect(appState.isViewingDisruptedLines)

        appState.selectedMapNetworkStat = .majorIssues
        #expect(appState.isViewingDisruptedLines)

        appState.selectedMapNetworkStat = .goodService
        #expect(!appState.isViewingDisruptedLines)

        appState.disruptionDisplayMode = .issues
        #expect(!appState.isViewingDisruptedLines)
    }

    @Test @MainActor func worksControlContinuesFromAnActiveDisruptionFilter() {
        let appState = TubeAppState()
        appState.selectedMapNetworkStat = .minorDelays

        appState.toggleDisruptionHighlighting()

        #expect(appState.selectedMapNetworkStat == nil)
        #expect(appState.disruptionDisplayMode == .normal)
        #expect(!appState.isViewingDisruptedLines)
    }

    @Test @MainActor func disruptionScopesSelectMatchingAffectedSections() {
        let appState = TubeAppState()
        appState.disruptions = [
            disruption(id: "major", severity: 6, segmentID: "major-segment"),
            disruption(id: "minor", severity: 9, segmentID: "minor-segment"),
        ]

        appState.setDisruptionHighlightScope(.major)
        #expect(appState.activeAffectedSegmentIDs == ["major-segment"])

        appState.setDisruptionHighlightScope(.minor)
        #expect(appState.activeAffectedSegmentIDs == ["minor-segment"])

        appState.setDisruptionHighlightScope(.all)
        #expect(appState.activeAffectedSegmentIDs == ["major-segment", "minor-segment"])
    }

    @Test @MainActor func mapNetworkStatsToggleOffWhenSelectedAgain() {
        let appState = TubeAppState()

        for filter in MapNetworkStatFilter.allCases {
            appState.toggleMapNetworkStat(filter)
            #expect(appState.selectedMapNetworkStat == filter)

            appState.toggleMapNetworkStat(filter)
            #expect(appState.selectedMapNetworkStat == nil)
            #expect(appState.disruptionDisplayMode == .normal)
        }
    }

    @Test func dataFreshnessUsesStableCopyInsteadOfACountdown() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)

        #expect(
            RailDataFreshness.evaluate(
                updatedAt: updatedAt,
                now: updatedAt.addingTimeInterval(119),
                cached: false,
                staleAfter: 120
            ) == .current
        )
        #expect(
            RailDataFreshness.evaluate(
                updatedAt: updatedAt,
                now: updatedAt.addingTimeInterval(120),
                cached: false,
                staleAfter: 120
            ) == .stale
        )
        #expect(
            RailDataFreshness.evaluate(
                updatedAt: updatedAt,
                now: updatedAt,
                cached: true,
                staleAfter: 120
            ) == .stale
        )
    }

    @Test func liveStatusWarningAppearsAfterThirtySecondsOfStaleness() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)

        #expect(
            !LiveStatusStaleness.isStale(
                updatedAt: updatedAt,
                now: updatedAt.addingTimeInterval(29.999)
            )
        )
        #expect(
            LiveStatusStaleness.isStale(
                updatedAt: updatedAt,
                now: updatedAt.addingTimeInterval(30)
            )
        )
        #expect(!LiveStatusStaleness.isStale(updatedAt: nil, now: updatedAt))
    }

    @Test func weekendDateSelectionsUseUpcomingLondonDays() throws {
        let thursday = try #require(londonDate(year: 2026, month: 8, day: 20, hour: 12))
        let friday = try #require(londonDate(year: 2026, month: 8, day: 21))
        let saturday = try #require(londonDate(year: 2026, month: 8, day: 22))
        let sunday = try #require(londonDate(year: 2026, month: 8, day: 23))

        #expect(DisruptionDateSelection.tomorrow.date(relativeTo: thursday) == friday)
        #expect(DisruptionDateSelection.saturday.date(relativeTo: thursday) == saturday)
        #expect(DisruptionDateSelection.sunday.date(relativeTo: thursday) == sunday)
        #expect(
            DisruptionDateSelection.saturday.date(relativeTo: saturday)
                == LondonRailDate.calendar.date(byAdding: .day, value: 7, to: saturday)
        )
        #expect(DisruptionDateSelection.sunday.date(relativeTo: saturday) == sunday)
        #expect(
            DisruptionDateSelection.sunday.date(relativeTo: sunday)
                == LondonRailDate.calendar.date(byAdding: .day, value: 7, to: sunday)
        )
        #expect(
            DisruptionDateSelection.saturday.date(relativeTo: sunday)
                == LondonRailDate.calendar.date(byAdding: .day, value: 6, to: sunday)
        )
    }

    @Test func londonDayIntervalsHandleDSTAndHalfOpenWorkBoundaries() throws {
        let springChange = try #require(londonDate(year: 2026, month: 3, day: 29))
        let autumnChange = try #require(londonDate(year: 2026, month: 10, day: 25))
        #expect(LondonRailDate.dayInterval(for: springChange).duration == 23 * 3_600)
        #expect(LondonRailDate.dayInterval(for: autumnChange).duration == 25 * 3_600)

        let saturday = try #require(londonDate(year: 2026, month: 8, day: 22))
        let sunday = try #require(londonDate(year: 2026, month: 8, day: 23))
        let fridayEvening = try #require(londonDate(year: 2026, month: 8, day: 21, hour: 23))
        let saturdayMorning = try #require(londonDate(year: 2026, month: 8, day: 22, hour: 2))

        let endingAtMidnight = work(
            id: "ending",
            start: fridayEvening.addingTimeInterval(-3_600),
            end: saturday,
            detail: "Ends at midnight"
        )
        let overnight = work(
            id: "overnight",
            start: fridayEvening,
            end: saturdayMorning,
            detail: "Runs overnight"
        )
        let startingNextDay = work(
            id: "next-day",
            start: sunday,
            end: sunday.addingTimeInterval(3_600),
            detail: "Starts next day"
        )

        let matches = LondonRailDate.works(
            [endingAtMidnight, overnight, startingNextDay],
            overlapping: saturday
        )
        #expect(matches.map(\.id) == ["overnight"])
    }

    @Test func disruptionTimeWindowsUseLondonClockBoundariesAcrossDST() throws {
        let springChange = try #require(londonDate(year: 2026, month: 3, day: 29))
        let autumnChange = try #require(londonDate(year: 2026, month: 10, day: 25))

        let springOvernight = DisruptionTimeWindow.overnight.interval(on: springChange)
        let autumnOvernight = DisruptionTimeWindow.overnight.interval(on: autumnChange)
        #expect(springOvernight.duration == 5 * 3_600)
        #expect(autumnOvernight.duration == 7 * 3_600)

        for date in [springChange, autumnChange] {
            let am = DisruptionTimeWindow.am.interval(on: date)
            let pm = DisruptionTimeWindow.pm.interval(on: date)
            #expect(LondonRailDate.calendar.component(.hour, from: am.start) == 6)
            #expect(LondonRailDate.calendar.component(.hour, from: am.end) == 12)
            #expect(am.end == pm.start)
            #expect(pm.end == LondonRailDate.dayInterval(for: date).end)
        }
    }

    @Test func timeWindowFilteringUsesHalfOpenBoundariesAndCombinationUnion() throws {
        let saturday = try #require(londonDate(year: 2026, month: 8, day: 22))
        let works = [
            work(
                id: "overnight",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 1, minute: 45)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 4, minute: 45)),
                detail: "Piccadilly overnight closure"
            ),
            work(
                id: "ends-at-six",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 5)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 6)),
                detail: "Ends at the AM boundary"
            ),
            work(
                id: "am",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 6)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 8)),
                detail: "AM closure"
            ),
            work(
                id: "crosses-noon",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 11)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 13)),
                detail: "Spans AM and PM"
            ),
            work(
                id: "pm",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 15)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 18)),
                detail: "PM closure"
            ),
        ]

        let overnight = LondonRailDate.works(works, overlappingAny: [.overnight], on: saturday)
        let am = LondonRailDate.works(works, overlappingAny: [.am], on: saturday)
        let pm = LondonRailDate.works(works, overlappingAny: [.pm], on: saturday)
        let daytime = LondonRailDate.works(
            works,
            overlappingAny: DisruptionTimeWindow.defaultSelected,
            on: saturday
        )

        #expect(overnight.map(\.id) == ["overnight", "ends-at-six"])
        #expect(am.map(\.id) == ["am", "crosses-noon"])
        #expect(pm.map(\.id) == ["crosses-noon", "pm"])
        #expect(daytime.map(\.id) == ["am", "crosses-noon", "pm"])
    }

    @Test @MainActor func plannedWorkTimeSelectionsDefaultToDaytimeAndUpdateMapGeometry() throws {
        let saturday = try #require(londonDate(year: 2026, month: 8, day: 22))
        let appState = TubeAppState()
        appState.engineeringWorks = [
            work(
                id: "overnight",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 1)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 5)),
                detail: "Overnight only",
                segmentID: "overnight-segment"
            ),
            work(
                id: "am",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 7)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 9)),
                detail: "AM only",
                segmentID: "am-segment"
            ),
            work(
                id: "both",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 11)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 13)),
                detail: "Both daytime windows",
                segmentID: "both-segment"
            ),
            work(
                id: "pm",
                start: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 14)),
                end: try #require(londonDate(year: 2026, month: 8, day: 22, hour: 16)),
                detail: "PM only",
                segmentID: "pm-segment"
            ),
        ]

        appState.setDisruptionDateSelection(.custom(saturday))

        #expect(appState.selectedDisruptionTimeWindows == [.am, .pm])
        #expect(appState.plannedWorkCount(in: .overnight) == 1)
        #expect(appState.plannedWorkCount(in: .am) == 2)
        #expect(appState.plannedWorkCount(in: .pm) == 2)
        #expect(appState.selectedEngineeringWorks.map(\.id) == ["am", "both", "pm"])
        #expect(appState.currentIssueCount == 3)
        #expect(appState.activeAffectedSegmentIDs == ["am-segment", "both-segment", "pm-segment"])

        appState.toggleDisruptionTimeWindow(.am)
        #expect(appState.selectedEngineeringWorks.map(\.id) == ["both", "pm"])

        appState.toggleDisruptionTimeWindow(.pm)
        #expect(appState.selectedEngineeringWorks.isEmpty)
        #expect(appState.activeAffectedSegmentIDs.isEmpty)

        appState.toggleDisruptionTimeWindow(.overnight)
        #expect(appState.selectedEngineeringWorks.map(\.id) == ["overnight"])
        #expect(appState.activeAffectedSegmentIDs == ["overnight-segment"])
    }

    @Test @MainActor func futureDisruptionDateUsesPlannedWorksAndClearsLiveSelection() throws {
        let selectedDate = try #require(londonDate(year: 2026, month: 9, day: 5))
        let graph = try TubeGraph.bundled()
        let centralSegment = try #require(graph.segments(for: .central).first)
        let plannedWork = work(
            id: "weekend-work",
            start: selectedDate.addingTimeInterval(7 * 3_600),
            end: selectedDate.addingTimeInterval(9 * 3_600),
            detail: "No service between A and B",
            segmentID: centralSegment.id
        )
        let appState = TubeAppState()
        appState.graph = graph
        appState.disruptions = [disruption(id: "live", severity: 6, segmentID: "live-segment")]
        appState.engineeringWorks = [plannedWork]
        appState.select(disruption: appState.disruptions[0])
        appState.selectedMapNetworkStat = .majorIssues

        #expect(appState.disruptionDateSelection == .today)
        #expect(appState.visibleDisruptions.map(\.id) == ["live"])

        appState.setDisruptionDateSelection(.custom(selectedDate))

        #expect(appState.selectedDisruptionID == nil)
        #expect(appState.selectedEngineeringWorkID == nil)
        #expect(appState.selectedMapNetworkStat == nil)
        #expect(appState.disruptionDisplayMode == .normal)
        #expect(appState.selectedEngineeringWorks.map(\.id) == ["weekend-work"])
        #expect(appState.visibleDisruptions.count == 1)
        #expect(appState.visibleDisruptions[0].category == .closures)
        #expect(appState.activeAffectedSegmentIDs == plannedWork.affectedSegmentIDs)

        appState.toggleMapNetworkStat(.disrupted)
        #expect(appState.selectedMapNetworkStat == .disrupted)

        appState.setDisruptionDateSelection(.today)

        #expect(appState.isViewingLiveStatus)
        #expect(appState.selectedMapNetworkStat == nil)
        #expect(appState.visibleDisruptions.map(\.id) == ["live"])
    }

    @Test func engineeringWorksBuilderKeepsEveryPlannedValidityPeriodAndUniqueID() throws {
        let graph = try TubeGraph.bundled()
        let firstStart = try #require(londonDate(year: 2026, month: 8, day: 22, hour: 1))
        let firstEnd = try #require(londonDate(year: 2026, month: 8, day: 22, hour: 5))
        let secondStart = try #require(londonDate(year: 2026, month: 8, day: 23, hour: 1))
        let secondEnd = try #require(londonDate(year: 2026, month: 8, day: 23, hour: 5))
        let periods = [
            TfLValidityPeriod(fromDate: firstStart, toDate: firstEnd, isNow: false),
            TfLValidityPeriod(fromDate: secondStart, toDate: secondEnd, isNow: false),
        ]
        let informationClosure = TfLDisruption(
            category: "Information",
            categoryDescription: "Information",
            description: nil,
            affectedRoutes: nil,
            affectedStops: nil,
            closureText: "plannedClosure"
        )
        let entries = [
            TfLStatusEntry(
                id: 0,
                statusSeverity: 5,
                statusSeverityDescription: "Planned Closure",
                reason: "First closure",
                validityPeriods: periods,
                disruption: informationClosure
            ),
            TfLStatusEntry(
                id: 0,
                statusSeverity: 5,
                statusSeverityDescription: "Planned Closure",
                reason: "Different closure with the same TfL ID",
                validityPeriods: periods,
                disruption: informationClosure
            ),
        ]
        let statuses = [TfLLineStatus(id: .district, name: "District", lineStatuses: entries)]

        let works = EngineeringWorksBuilder(
            repository: TubeNetworkRepository(graph: graph)
        ).works(from: statuses, fetchedAt: firstStart)

        #expect(informationClosure.closureText == "plannedClosure")
        #expect(entries.allSatisfy { $0.isPlannedEngineeringWork })
        #expect(works.count == 4)
        #expect(Set(works.map(\.id)).count == 4)
        #expect(Set(works.map(\.startDate)) == [firstStart, secondStart])
    }

    @Test func longRangePlannedWorkKeepsInclusiveDatesWithoutInventingTimes() throws {
        let graph = try TubeGraph.bundled()
        let json = """
        [{"id":"district-october","lineId":"district","title":"Planned closure","description":"Edgware Road and Embankment to Ealing Broadway, Kensington (Olympia), Richmond and Wimbledon","dateRange":{"start":"2026-10-24","end":"2026-10-25"},"validFrom":null,"validTo":null,"timingPrecision":"date","provisional":true,"severity":null,"affectedRoutes":[],"affectedStops":[],"sources":[{"kind":"tfl-planned-track-closures-pdf"}]}]
        """
        let records = try JSONDecoder.tfl.decode([PlannedWorkV2].self, from: Data(json.utf8))

        let work = try #require(EngineeringWorksBuilder(
            repository: TubeNetworkRepository(graph: graph)
        ).works(from: records).first)

        #expect(work.source == .plannedTrackClosuresPDF)
        #expect(work.isDateOnly)
        #expect(LondonRailDate.formatted(work.startDate, dateFormat: "yyyy-MM-dd") == "2026-10-24")
        #expect(LondonRailDate.formatted(work.displayEndDate, dateFormat: "yyyy-MM-dd") == "2026-10-25")
        #expect(LondonRailDate.formatted(work.endDate, dateFormat: "yyyy-MM-dd") == "2026-10-26")
        #expect(work.confidence == .inferred)
    }

    @Test func routineOvernightClosureIsNotAnActionableDisruption() {
        let closure = TfLStatusEntry(
            id: 20, statusSeverity: 20, statusSeverityDescription: "Service Closed",
            reason: "Waterloo and City Line: Service will resume at 06:00.",
            validityPeriods: nil, disruption: nil
        )
        #expect(closure.isOvernightClosure)
        #expect(!closure.isActionableIssue)
    }

    @Test func noIssuesSeverityIsNotAnActionableDisruption() {
        let noIssues = TfLStatusEntry(
            id: 18, statusSeverity: 18, statusSeverityDescription: "No Issues",
            reason: nil, validityPeriods: nil, disruption: nil
        )
        #expect(noIssues.isGoodService)
        #expect(!noIssues.isActionableIssue)
    }

    @Test func tflDecoderHandlesFractionalDatesAndNullableFields() throws {
        let json = """
        [{"id":"central","name":"Central","lineStatuses":[{"id":1,"statusSeverity":6,"statusSeverityDescription":"Severe Delays","reason":null,"validityPeriods":[{"fromDate":"2026-08-18T01:02:03.456Z","toDate":null,"isNow":true}],"disruption":null}]}]
        """
        let decoded = try JSONDecoder.tfl.decode([TfLLineStatus].self, from: Data(json.utf8))
        #expect(decoded.first?.id == .central)
        #expect(decoded.first?.lineStatuses.first?.validityPeriods?.first?.fromDate != nil)
    }

    @Test func tflDecoderRecognizesLondonTramsStatusAndArrivals() throws {
        let statusJSON = """
        [{"id":"tram","name":"Tram","lineStatuses":[{"id":1,"statusSeverity":10,"statusSeverityDescription":"Good Service","reason":null,"validityPeriods":null,"disruption":null}]}]
        """
        let arrivalJSON = """
        [{"id":"tram-prediction","vehicleId":"2533","lineId":"tram","stationName":"Wimbledon Tram Stop","naptanId":"940GZZCRWMB","platformName":null,"direction":"inbound","destinationName":"Wimbledon Tram Stop","destinationNaptanId":"940GZZCRWMB","towards":"Wimbledon","expectedArrival":null,"timeToStation":60,"currentLocation":"Between stops"}]
        """

        let statuses = try JSONDecoder.tfl.decode([TfLLineStatus].self, from: Data(statusJSON.utf8))
        let arrivals = try JSONDecoder.tfl.decode([TfLArrivalPrediction].self, from: Data(arrivalJSON.utf8))

        #expect(statuses.first?.id == .tram)
        #expect(TubeLineID(rawValue: try #require(arrivals.first?.lineId)) == .tram)
    }

    @Test func trainProjectionMovesSmoothlyAndCapsAtStation() {
        let train = LiveTubeTrain(
            id: "victoria:1", vehicleID: "1", lineID: .victoria,
            destination: "Brixton", direction: "southbound",
            previousStationID: "a", nextStationID: "b", segmentID: "segment",
            progress: 0.25, secondsToNextStation: 100, updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(train.projectedProgress(at: Date(timeIntervalSince1970: 1_050)) == 0.625)
        #expect(train.projectedProgress(at: Date(timeIntervalSince1970: 1_100)) == 1)
        #expect(train.projectedProgress(at: Date(timeIntervalSince1970: 1_500)) == 1)
    }

    @Test func trainNextStopETACountsDownAndNeverBecomesNegative() {
        let train = markerTrain(seconds: 125)

        #expect(train.remainingSecondsToNextStation(
            at: Date(timeIntervalSince1970: 1_060)
        ) == 65)
        #expect(train.estimatedNextStopArrival(
            at: Date(timeIntervalSince1970: 1_060)
        ) == Date(timeIntervalSince1970: 1_125))
        #expect(train.remainingSecondsToNextStation(
            at: Date(timeIntervalSince1970: 1_200)
        ) == 0)
    }

    @Test func refreshedTrainNeverMovesBackwardsOnTheSameLeg() throws {
        let previous = markerTrain(seconds: 100)
        let refreshedAt = Date(timeIntervalSince1970: 1_050)
        let incoming = previous.rebased(
            progress: 0.3,
            secondsToNextStation: 150,
            updatedAt: refreshedAt
        )

        let train = try #require(LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [incoming],
            at: refreshedAt,
            segmentsByID: [:]
        ).first)

        #expect(train.progress == 0.625)
        #expect(train.secondsToNextStation == 150)
    }

    @Test func refreshedArrivalLatchesAtTheStationWhenTheETARestarts() throws {
        let previous = markerTrain(seconds: 60)
        let refreshedAt = Date(timeIntervalSince1970: 1_060)
        let incoming = previous.rebased(
            progress: 0.4,
            secondsToNextStation: 60,
            updatedAt: refreshedAt
        )

        let train = try #require(LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [incoming],
            at: refreshedAt,
            segmentsByID: [:]
        ).first)

        #expect(train.progress == 1)
        #expect(train.remainingSecondsToNextStation(at: refreshedAt) == 0)
        #expect(LiveTrainMarkerPolicy.projectedProgress(
            for: train,
            at: refreshedAt.addingTimeInterval(30),
            stationBoard: nil
        ) == 1)
    }

    @Test func refreshedTrainUsesAPhysicallyPlausibleForwardCorrection() throws {
        let previous = markerTrain(seconds: 100)
        let refreshedAt = Date(timeIntervalSince1970: 1_050)
        let incoming = previous.rebased(
            progress: 0.95,
            secondsToNextStation: 1,
            updatedAt: refreshedAt
        )
        let segment = TubeSegment(
            id: previous.segmentID,
            lineID: previous.lineID,
            fromStationID: previous.previousStationID,
            toStationID: previous.nextStationID,
            schematicPoints: [],
            geographicPoints: [
                GeographicPoint(latitude: 51.50, longitude: -0.12),
                GeographicPoint(latitude: 51.51, longitude: -0.12),
            ]
        )

        let train = try #require(LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [incoming],
            at: refreshedAt,
            segmentsByID: [segment.id: segment]
        ).first)

        #expect(train.progress == 0.625)
        #expect(train.secondsToNextStation >= 9)
    }

    @Test func nextLegBeginsAtTheSharedStationRatherThanJumpingDownTrack() throws {
        let previous = markerTrain(seconds: 60)
        let refreshedAt = Date(timeIntervalSince1970: 1_060)
        let incoming = LiveTubeTrain(
            id: previous.id,
            vehicleID: previous.vehicleID,
            lineID: previous.lineID,
            destination: "Cockfosters",
            direction: previous.direction,
            previousStationID: previous.nextStationID,
            nextStationID: "cockfosters",
            segmentID: "tram:arena:cockfosters",
            progress: 0.7,
            secondsToNextStation: 20,
            updatedAt: refreshedAt
        )

        let train = try #require(LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [incoming],
            at: refreshedAt,
            segmentsByID: [:]
        ).first)

        #expect(train.segmentID == incoming.segmentID)
        #expect(train.previousStationID == previous.nextStationID)
        #expect(train.progress == 0)
    }

    @Test func terminusReversalStartsFromThePlatform() throws {
        let previous = LiveTubeTrain(
            id: "piccadilly:123",
            vehicleID: "123",
            lineID: .piccadilly,
            destination: "Cockfosters",
            direction: "northbound",
            previousStationID: "oakwood",
            nextStationID: "cockfosters",
            segmentID: "piccadilly:cockfosters:oakwood",
            progress: 0.25,
            secondsToNextStation: 60,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let refreshedAt = Date(timeIntervalSince1970: 1_060)
        let reversed = LiveTubeTrain(
            id: previous.id,
            vehicleID: previous.vehicleID,
            lineID: previous.lineID,
            destination: "Heathrow Terminal 5",
            direction: "southbound",
            previousStationID: "cockfosters",
            nextStationID: "oakwood",
            segmentID: previous.segmentID,
            progress: 0.65,
            secondsToNextStation: 30,
            updatedAt: refreshedAt
        )

        let train = try #require(LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [reversed],
            at: refreshedAt,
            segmentsByID: [:]
        ).first)

        #expect(train.previousStationID == "cockfosters")
        #expect(train.nextStationID == "oakwood")
        #expect(train.progress == 0)
    }

    @Test func reusedVehicleIDDoesNotTeleportToAnUnrelatedLeg() throws {
        let previous = markerTrain(seconds: 100)
        let refreshedAt = Date(timeIntervalSince1970: 1_050)
        let unrelated = LiveTubeTrain(
            id: previous.id,
            vehicleID: previous.vehicleID,
            lineID: previous.lineID,
            destination: "New Addington",
            direction: previous.direction,
            previousStationID: "coombe-lane",
            nextStationID: "gravel-hill",
            segmentID: "tram:coombe-lane:gravel-hill",
            progress: 0.6,
            secondsToNextStation: 30,
            updatedAt: refreshedAt
        )

        let train = try #require(LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [unrelated],
            at: refreshedAt,
            segmentsByID: [:]
        ).first)

        #expect(!LiveTrainSnapshotReconciler.isContinuousJourney(
            from: previous,
            to: unrelated,
            at: refreshedAt
        ))
        #expect(train.segmentID == previous.segmentID)
        #expect(train.projectedProgress(at: refreshedAt) == 0.625)
    }

    @Test func nextLegWaitsForTheDisplayedTrainToReachTheSharedStation() throws {
        let previous = markerTrain(seconds: 100)
        let refreshedAt = Date(timeIntervalSince1970: 1_050)
        let incoming = LiveTubeTrain(
            id: previous.id,
            vehicleID: previous.vehicleID,
            lineID: previous.lineID,
            destination: "Cockfosters",
            direction: previous.direction,
            previousStationID: previous.nextStationID,
            nextStationID: "cockfosters",
            segmentID: "tram:arena:cockfosters",
            progress: 0.6,
            secondsToNextStation: 20,
            updatedAt: refreshedAt
        )

        let train = try #require(LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [incoming],
            at: refreshedAt,
            segmentsByID: [:]
        ).first)

        #expect(train.segmentID == previous.segmentID)
        #expect(train.progress == 0.625)
        #expect(train.secondsToNextStation > 1)
    }

    @Test func oneMissingTrainSnapshotIsRetainedWithoutFlicker() {
        let previous = markerTrain(seconds: 100)

        let retained = LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [],
            at: Date(timeIntervalSince1970: 1_030),
            segmentsByID: [:]
        )
        let expired = LiveTrainSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [],
            at: Date(timeIntervalSince1970: 1_046),
            segmentsByID: [:]
        )

        #expect(retained.map(\.id) == [previous.id])
        #expect(expired.isEmpty)
    }

    @Test func trainReconciliationRepairsDuplicateSnapshotIDs() throws {
        let older = markerTrain(seconds: 100)
        let newer = older.rebased(
            progress: 0.4,
            secondsToNextStation: 80,
            updatedAt: Date(timeIntervalSince1970: 1_010)
        )

        let trains = LiveTrainSnapshotReconciler.reconcile(
            previous: [older, older],
            incoming: [older, newer],
            at: newer.updatedAt,
            segmentsByID: [:]
        )

        let train = try #require(trains.first)
        #expect(trains.count == 1)
        #expect(train.id == older.id)
        #expect(train.updatedAt == newer.updatedAt)
    }

    @Test func liveTrainLocationTextPlacesOpposingKensalTrainsOnDifferentSides() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let kensalGreenID = "940GZZLUKSL"

        let southboundPrevious = repository.neighboringStation(
            for: kensalGreenID,
            on: .bakerloo,
            direction: nil,
            currentLocation: "Between Willesden Junction and Kensal Green"
        )
        let northboundPrevious = repository.neighboringStation(
            for: kensalGreenID,
            on: .bakerloo,
            direction: "outbound",
            destinationStationID: "940GZZLUSGP",
            currentLocation: "North of Queen's Park"
        )

        #expect(southboundPrevious == "940GZZLUWJN")
        #expect(northboundPrevious == "940GZZLUQPS")
        #expect(southboundPrevious != northboundPrevious)
    }

    @Test func platformDirectionResolvesThePreviousStationWhenLocationIsMissing() throws {
        let repository = TubeNetworkRepository(graph: try TubeGraph.bundled())
        let kensalGreenID = "940GZZLUKSL"

        #expect(repository.neighboringStation(
            for: kensalGreenID,
            on: .bakerloo,
            direction: "Southbound - Platform 1"
        ) == "940GZZLUWJN")
        #expect(repository.neighboringStation(
            for: kensalGreenID,
            on: .bakerloo,
            direction: "Northbound - Platform 2"
        ) == "940GZZLUQPS")
    }

    @Test func liveTrainDirectionPrefersPassengerFacingPlatformDirection() {
        #expect(LiveTrainDirection.resolved(
            direction: "outbound",
            platformName: "Northbound - Platform 2"
        ) == "Northbound")
        #expect(LiveTrainDirection.resolved(
            direction: nil,
            platformName: "Southbound - Platform 1"
        ) == "Southbound")
        #expect(LiveTrainDirection.displayName(for: "Eastbound - Platform 3") == "Eastbound")
        #expect(LiveTrainDirection.displayName(for: "outbound") == "Outbound")
        #expect(LiveTrainDirection.displayName(for: "Platform 4") == nil)
    }

    @Test func liveTrainHitTestingChoosesTheNearestMarkerWithinItsTapTarget() {
        let first = markerTrain(vehicleID: "first", seconds: 60)
        let second = markerTrain(vehicleID: "second", seconds: 60)
        let candidates = [
            (train: first, point: CGPoint(x: 40, y: 40)),
            (train: second, point: CGPoint(x: 58, y: 40)),
        ]

        #expect(LiveTrainHitTesting.nearest(
            to: CGPoint(x: 55, y: 42),
            candidates: candidates
        )?.id == second.id)
        #expect(LiveTrainHitTesting.nearest(
            to: CGPoint(x: 120, y: 120),
            candidates: candidates
        ) == nil)
    }

    @Test func trainCalloutLayoutStaysOnScreenAndPointsBackToTheMarker() {
        let layout = TrainMapCalloutLayout.resolve(
            markerPoint: CGPoint(x: 10, y: 500),
            calloutSize: CGSize(width: 300, height: 140),
            viewportSize: CGSize(width: 390, height: 844)
        )

        #expect(layout.placement == .above)
        #expect(layout.calloutCenter.x == 162)
        #expect(layout.calloutCenter.y == 418)
        #expect(layout.arrowOffset == -120)
    }

    @Test func trainMapFocusZoomsInWithoutZoomingBackOut() {
        let coordinate = CLLocationCoordinate2D(latitude: 51.6517, longitude: -0.1496)
        let overview = TrainMapFocusPolicy.geographicRegion(
            centeredAt: coordinate,
            currentSpan: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.15)
        )
        let alreadyClose = TrainMapFocusPolicy.geographicRegion(
            centeredAt: coordinate,
            currentSpan: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.015)
        )

        #expect(overview.center.latitude == coordinate.latitude)
        #expect(overview.center.longitude == coordinate.longitude)
        #expect(overview.span.latitudeDelta == 0.025)
        #expect(overview.span.longitudeDelta == 0.04)
        #expect(alreadyClose.span.latitudeDelta == 0.01)
        #expect(alreadyClose.span.longitudeDelta == 0.015)
        #expect(TrainMapFocusPolicy.schematicScale(
            currentScale: 0.4,
            minimumScale: 0.2,
            maximumScale: 3.8
        ) == 1.65)
        #expect(TrainMapFocusPolicy.schematicScale(
            currentScale: 2.1,
            minimumScale: 0.2,
            maximumScale: 3.8
        ) == 2.1)
    }

    @Test @MainActor func repeatedTrainTapsEachRequestCameraFocus() {
        let appState = TubeAppState()
        let train = markerTrain(seconds: 60)

        appState.select(train: train)
        let firstGeneration = appState.trainSelectionGeneration
        appState.select(train: train)

        #expect(firstGeneration == 1)
        #expect(appState.trainSelectionGeneration == 2)
        #expect(appState.selectedTrainID == train.id)
    }

    @Test func markerPolicyRemovesAProjectionAfterItsArrivalWindow() {
        let train = markerTrain(seconds: 100)

        #expect(LiveTrainMarkerPolicy.projectedProgress(
            for: train,
            at: Date(timeIntervalSince1970: 1_109),
            stationBoard: nil
        ) == 1)
        #expect(LiveTrainMarkerPolicy.projectedProgress(
            for: train,
            at: Date(timeIntervalSince1970: 1_111),
            stationBoard: nil
        ) == nil)
    }

    @Test func selectedStationBoardSuppressesMarkersItDoesNotReport() {
        let train = markerTrain(vehicleID: "old-tram", seconds: 60)
        let board = LiveTrainStationBoardSnapshot(
            stationID: "arena",
            arrivals: [markerBoardArrival(vehicleID: "next-tram", seconds: 720)],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(LiveTrainMarkerPolicy.projectedProgress(
            for: train,
            at: Date(timeIntervalSince1970: 1_000),
            stationBoard: board
        ) == nil)
    }

    @Test func selectedStationBoardRejectsAnImplausibleETAConflict() {
        let train = markerTrain(vehicleID: "2562", seconds: 30)
        let board = LiveTrainStationBoardSnapshot(
            stationID: "arena",
            arrivals: [markerBoardArrival(vehicleID: " 2562 ", seconds: 720)],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(LiveTrainMarkerPolicy.projectedProgress(
            for: train,
            at: Date(timeIntervalSince1970: 1_000),
            stationBoard: board
        ) == nil)
    }

    @Test func selectedStationBoardKeepsAConsistentMatchingMarker() {
        let train = markerTrain(vehicleID: "2562", seconds: 60)
        let board = LiveTrainStationBoardSnapshot(
            stationID: "arena",
            arrivals: [markerBoardArrival(vehicleID: "2562", seconds: 75)],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(LiveTrainMarkerPolicy.projectedProgress(
            for: train,
            at: Date(timeIntervalSince1970: 1_000),
            stationBoard: board
        ) == train.progress)
    }

    @Test func activeTrainCountsKeepAllLineTotalsWhenAFilteredLineRefreshes() {
        func train(_ id: String, lineID: TubeLineID) -> LiveTubeTrain {
            LiveTubeTrain(
                id: id,
                vehicleID: id,
                lineID: lineID,
                destination: "Destination",
                direction: "outbound",
                previousStationID: "a",
                nextStationID: "b",
                segmentID: "segment",
                progress: 0.5,
                secondsToNextStation: 60,
                updatedAt: .now
            )
        }

        var counts = ActiveTrainCounts()
        counts.update(
            with: [
                train("dlr-1", lineID: .dlr),
                train("dlr-2", lineID: .dlr),
                train("tram-1", lineID: .tram),
            ],
            requestedLineIDs: []
        )

        #expect(counts.count(for: .dlr) == 2)
        #expect(counts.count(for: .tram) == 1)
        #expect(counts.total == 3)

        counts.update(
            with: [train("dlr-3", lineID: .dlr)],
            requestedLineIDs: [.dlr]
        )

        #expect(counts.count(for: .dlr) == 1)
        #expect(counts.count(for: .tram) == 1)
        #expect(counts.count(for: .victoria) == 0)
        #expect(counts.total == 2)
        #expect(counts.activeLineCount() == 2)
        #expect(counts.activeLineCount(excluding: [.dlr]) == 1)
    }

    @Test @MainActor func memoryWarningDropsSupplementalLiveData() {
        let appState = TubeAppState()
        appState.showLiveTrains = true
        appState.liveTrains = [LiveTubeTrain(
            id: "victoria:1", vehicleID: "1", lineID: .victoria,
            destination: "Brixton", direction: "southbound",
            previousStationID: "a", nextStationID: "b", segmentID: "segment",
            progress: 0.25, secondsToNextStation: 100, updatedAt: .now
        )]
        appState.stationArrivals = [TfLArrivalPrediction(
            id: "arrival", vehicleId: "1", lineId: TubeLineID.victoria.rawValue,
            stationName: "Victoria", naptanId: "station", platformName: nil,
            direction: nil, destinationName: nil, destinationNaptanId: nil,
            towards: nil, expectedArrival: nil, timeToStation: 30,
            currentLocation: nil
        )]

        appState.handleMemoryWarning()

        #expect(!appState.showLiveTrains)
        #expect(!appState.isLoadingLiveTrains)
        #expect(appState.liveTrains.isEmpty)
        #expect(appState.activeTrainCounts.total == 0)
        #expect(appState.stationArrivals.isEmpty)
    }

    @Test @MainActor func enablingLiveTrainsPublishesAnInitialLoadingState() {
        let appState = TubeAppState()

        appState.setLiveTrains(true)

        #expect(appState.showLiveTrains)
        #expect(appState.isLoadingLiveTrains)

        appState.setLiveTrains(false)

        #expect(!appState.showLiveTrains)
        #expect(!appState.isLoadingLiveTrains)
    }

    @Test @MainActor func rateLimitedLiveTrainsKeepLoadingAndRetryAutomatically() async throws {
        let trainService = RateLimitedThenSuccessfulTrainFetcher()
        let appState = TubeAppState(trainService: trainService)

        appState.setLiveTrains(true)

        #expect(appState.showLiveTrains)
        #expect(appState.isLoadingLiveTrains)

        for _ in 0 ..< 20 {
            if await trainService.attemptCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await trainService.attemptCount == 2)
        #expect(appState.liveTrains.count == 1)
        #expect(!appState.isLoadingLiveTrains)

        appState.setLiveTrains(false)
    }

    @Test func mapDockControlsUseFullWidthLayoutMetrics() {
        #expect(MapDockMetrics.controlSize == 44)
        #expect(MapDockMetrics.horizontalPadding == 12)
    }

    @Test func beckMapTrainPathRespectsTravelAndAuthoredDirections() throws {
        let edges = [
            BeckMapCollisionEdge(start: CGPoint(x: 0, y: 4), end: CGPoint(x: 10, y: 4)),
            BeckMapCollisionEdge(start: CGPoint(x: 10, y: 4), end: CGPoint(x: 30, y: 4)),
        ]
        let forward = BeckMapTrainPath(
            fromStationID: "a", toStationID: "b", pathDirection: .forward, edges: edges
        )
        let reverse = BeckMapTrainPath(
            fromStationID: "a", toStationID: "b", pathDirection: .reverse, edges: edges
        )

        let forwardPoint = try #require(forward.point(
            progress: 0.5, previousStationID: "a", nextStationID: "b"
        ))
        #expect(forwardPoint == CGPoint(x: 15, y: 4))

        let oppositeTravelPoint = try #require(forward.point(
            progress: 0.25, previousStationID: "b", nextStationID: "a"
        ))
        #expect(oppositeTravelPoint == CGPoint(x: 22.5, y: 4))

        let reverseAuthoredPoint = try #require(reverse.point(
            progress: 0.25, previousStationID: "a", nextStationID: "b"
        ))
        #expect(reverseAuthoredPoint == CGPoint(x: 22.5, y: 4))

        #expect(reverse.point(
            progress: 0.5, previousStationID: "missing", nextStationID: "b"
        ) == nil)
    }

    @Test func realWorldLineHitTestingMeasuresPolylineDistanceAndReservesStations() {
        let route = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]

        #expect(RealWorldLineHitTesting.distance(
            from: CGPoint(x: 5, y: 3),
            toPolyline: route
        ) == 3)
        #expect(RealWorldLineHitTesting.distance(
            from: CGPoint(x: 14, y: 0),
            toPolyline: route
        ) == 4)
        #expect(RealWorldLineHitTesting.distance(
            from: .zero,
            toPolyline: []
        ) == nil)
        #expect(RealWorldLineHitTesting.isNearStation(
            CGPoint(x: 20, y: 20),
            stationPoints: [CGPoint(x: 24, y: 23)],
            radius: 5
        ))
        #expect(!RealWorldLineHitTesting.isNearStation(
            CGPoint(x: 20, y: 20),
            stationPoints: [CGPoint(x: 26, y: 20)],
            radius: 5
        ))
    }

    @Test func hiddenRealWorldMapCannotOverwriteABeckMapStationSelection() {
        #expect(RealWorldMapSelectionPolicy.stationIDToSelect(
            mapSelection: "940GZZLUSKS",
            selectedStationID: "940GZZLUSKS",
            presentationMode: .beck
        ) == nil)
        #expect(RealWorldMapSelectionPolicy.stationIDToSelect(
            mapSelection: "940GZZLUSKS",
            selectedStationID: "940GZZLUSKS",
            presentationMode: .realWorld
        ) == nil)
        #expect(RealWorldMapSelectionPolicy.stationIDToSelect(
            mapSelection: "940GZZLUVIC",
            selectedStationID: "940GZZLUSKS",
            presentationMode: .realWorld
        ) == "940GZZLUVIC")
    }

    @Test func beckMapLineHitTestingChoosesNearestDisruptedSegmentWithinTolerance() {
        let horizontal = BeckMapLineHitTarget(
            segmentID: "horizontal",
            edges: [BeckMapCollisionEdge(
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 20, y: 0)
            )]
        )
        let vertical = BeckMapLineHitTarget(
            segmentID: "vertical",
            edges: [BeckMapCollisionEdge(
                start: CGPoint(x: 30, y: 0),
                end: CGPoint(x: 30, y: 20)
            )]
        )

        #expect(BeckMapLineHitTester.nearestSegmentID(
            to: CGPoint(x: 12, y: 3),
            among: [horizontal, vertical],
            maximumDistance: 4
        ) == "horizontal")
        #expect(BeckMapLineHitTester.nearestSegmentID(
            to: CGPoint(x: 28, y: 12),
            among: [horizontal, vertical],
            maximumDistance: 4
        ) == "vertical")
        #expect(BeckMapLineHitTester.nearestSegmentID(
            to: CGPoint(x: 12, y: 8),
            among: [horizontal, vertical],
            maximumDistance: 4
        ) == nil)
    }

    @Test func beckMapStationLineResolutionUsesRenderedPathsAtRoundels() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let renderCache = BeckMapCanvas.RenderCache(document: document)

        func resolvedLine(stationID: String, point: CGPoint) throws -> TubeLineID? {
            let marker = try #require(document.stationMarkers.first {
                $0.stationID == stationID
            })
            let station = try #require(graph.stationsByID[stationID])
            return BeckMapStationLineResolver.preferredLineID(
                for: marker,
                tappedAt: point,
                colocatedStationIDs: Set(graph.stations(inSamePlaceAs: station).map(\.id)),
                segments: renderCache.renderedSegments
            )
        }

        let expectedLines: [(String, CGPoint, TubeLineID)] = [
            ("940GZZLUECT", CGPoint(x: 1_376.141, y: 1_843.188), .piccadilly),
            ("940GZZLUHSD", CGPoint(x: 1_171.929, y: 1_843.188), .piccadilly),
            ("940GZZLUTNG", CGPoint(x: 919.842, y: 1_843.188), .piccadilly),
            ("940GZZLUACT", CGPoint(x: 707.996, y: 1_843.219), .piccadilly),
            ("940GZZLUECM", CGPoint(x: 667.578, y: 1_773.965), .piccadilly),
            ("940GZZLUEBY", CGPoint(x: 600.003, y: 1_707.781), .district),
            ("940GZZLUSKS", CGPoint(x: 1_524.013, y: 1_843.164), .piccadilly),
            ("940GZZLUBND", CGPoint(x: 1_682, y: 1_620), .jubilee),
            ("940GZZLUWSM", CGPoint(x: 1_885.992, y: 1_855.985), .jubilee),
            ("940GZZLUVIC", CGPoint(x: 1_729.02, y: 1_844.839), .victoria),
        ]

        for (stationID, point, expectedLineID) in expectedLines {
            #expect(try resolvedLine(stationID: stationID, point: point) == expectedLineID)
        }
    }

    @Test func beckMapStationMarkerHitTestingCoversEveryAuthoredRoundel() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)

        #expect(BeckMapStationMarkerHitTester.nearestMarker(
            to: CGPoint(x: 1_524.013, y: 1_843.164),
            among: document.stationMarkers,
            minimumHitRadius: 12
        )?.stationID == "940GZZLUSKS")
        #expect(BeckMapStationMarkerHitTester.nearestMarker(
            to: CGPoint(x: 1_682, y: 1_620),
            among: document.stationMarkers,
            minimumHitRadius: 12
        )?.stationID == "940GZZLUBND")
        #expect(BeckMapStationMarkerHitTester.nearestMarker(
            to: CGPoint(x: 1_767.999, y: 1_561.797),
            among: document.stationMarkers,
            minimumHitRadius: 12
        )?.stationID == "910GBONDST")
    }

    @Test @MainActor func beckMapScreenTapSelectsTheMatchingDepartureLine() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let renderCache = BeckMapCanvas.RenderCache(document: document)
        let appState = TubeAppState()
        appState.graph = graph

        let cameraScale: CGFloat = 1.73
        let cameraOffset = CGSize(width: -821.5, height: 367.25)
        let screenTapOffset = CGVector(dx: 9, dy: -7)
        let expectedSelections: [(String, CGPoint, TubeLineID)] = [
            ("910GBARKING", CGPoint(x: 3_587.523, y: 1_525.187), .suffragette),
            ("940GZZLUWHM", CGPoint(x: 3_229.053, y: 1_518.282), .jubilee),
            ("910GWBRMPTN", CGPoint(x: 1_306.969, y: 1_948.626), .mildmay),
            ("940GZZLUECT", CGPoint(x: 1_376.141, y: 1_843.188), .piccadilly),
            ("940GZZLUHSD", CGPoint(x: 1_171.929, y: 1_843.188), .piccadilly),
            ("940GZZLUTNG", CGPoint(x: 919.842, y: 1_843.188), .piccadilly),
            ("940GZZLUACT", CGPoint(x: 707.996, y: 1_843.219), .piccadilly),
            ("940GZZLUECM", CGPoint(x: 667.578, y: 1_773.965), .piccadilly),
            ("940GZZLUEBY", CGPoint(x: 600.003, y: 1_707.781), .district),
            ("940GZZLUSKS", CGPoint(x: 1_524.013, y: 1_843.164), .piccadilly),
            ("940GZZLUBND", CGPoint(x: 1_682, y: 1_620), .jubilee),
            ("940GZZLUWSM", CGPoint(x: 1_885.992, y: 1_855.985), .jubilee),
            ("940GZZLUVIC", CGPoint(x: 1_729.02, y: 1_844.839), .victoria),
        ]

        for (stationID, artworkPoint, expectedLineID) in expectedSelections {
            let screenPoint = CGPoint(
                x: artworkPoint.x * cameraScale + cameraOffset.width + screenTapOffset.dx,
                y: artworkPoint.y * cameraScale + cameraOffset.height + screenTapOffset.dy
            )
            let selection = try #require(BeckMapStationTapResolver.resolve(
                screenPoint: screenPoint,
                cameraScale: cameraScale,
                cameraOffset: cameraOffset,
                document: document,
                renderedSegments: renderCache.renderedSegments,
                graph: graph
            ))
            #expect(selection.stationID == stationID)
            #expect(selection.preferredLineID == expectedLineID)

            let station = try #require(graph.stationsByID[selection.stationID])
            appState.select(
                station: station,
                preferredDepartureLineID: selection.preferredLineID
            )
            #expect(RealWorldMapSelectionPolicy.stationIDToSelect(
                mapSelection: appState.selectedStationID,
                selectedStationID: appState.selectedStationID,
                presentationMode: appState.mapPresentationMode
            ) == nil)
            #expect(appState.selectedStationID == stationID)
            #expect(appState.selectedStationDepartureLineID == expectedLineID)
            #expect(StationDepartureSelection.resolved(
                controlled: appState.selectedStationDepartureLineID,
                requested: .circle,
                usesControlledSelection: true,
                preferred: appState.selectedStationDepartureLineID,
                lineIDs: graph.lineIDs(at: station),
                arrivals: []
            ) == expectedLineID)
        }
    }

    @Test func engineeringWorksPreferStructuredSourceAndSortChronologically() {
        let later = Date(timeIntervalSince1970: 200_000)
        let earlier = Date(timeIntervalSince1970: 100_000)
        let cached = work(id: "cached", start: earlier, source: .cached, confidence: .lineOnly)
        let structured = work(id: "structured", start: earlier, source: .unifiedAPI, confidence: .exact)
        let future = work(id: "future", start: later, source: .unifiedAPI, confidence: .exact, detail: "Different work")

        let result = EngineeringWorksNormalizer().deduplicatedAndSorted([future, cached, structured])
        #expect(result.map(\.id) == ["structured", "future"])
    }

    private func status(reason: String) -> TfLStatusEntry {
        TfLStatusEntry(
            id: 1, statusSeverity: 6, statusSeverityDescription: "Severe Delays",
            reason: reason, validityPeriods: nil, disruption: nil
        )
    }

    private func markerTrain(
        vehicleID: String = "2562",
        seconds: Int
    ) -> LiveTubeTrain {
        LiveTubeTrain(
            id: "tram:\(vehicleID)",
            vehicleID: vehicleID,
            lineID: .tram,
            destination: "George Street Crossover",
            direction: "outbound",
            previousStationID: "harrington-road",
            nextStationID: "arena",
            segmentID: "tram:harrington-road:arena",
            progress: 0.25,
            secondsToNextStation: seconds,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func markerBoardArrival(
        vehicleID: String?,
        seconds: Int
    ) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: "board:\(vehicleID ?? "unknown")",
            vehicleId: vehicleID,
            lineId: TubeLineID.tram.rawValue,
            stationName: "Arena",
            naptanId: "arena",
            platformName: "Westbound Platform",
            direction: "outbound",
            destinationName: "George Street Crossover",
            destinationNaptanId: nil,
            towards: "George Street Crossover",
            expectedArrival: Date(timeIntervalSince1970: 1_000 + Double(seconds)),
            timeToStation: seconds,
            currentLocation: nil
        )
    }

    private func disruption(
        id: String = "issue",
        severity: Int,
        segmentID: String = "segment"
    ) -> ResolvedDisruption {
        ResolvedDisruption(
            id: id,
            lineID: .central,
            title: "Issue",
            reason: "Testing",
            severity: severity,
            affectedStationIDs: ["station"],
            affectedSegmentIDs: [segmentID],
            confidence: .exact
        )
    }

    private func work(
        id: String,
        start: Date,
        source: EngineeringWorkSource,
        confidence: ResolutionConfidence,
        detail: String = "No service between A and B"
    ) -> EngineeringWork {
        EngineeringWork(
            id: id, title: "Planned Closure", detail: detail, lineIDs: [.central],
            affectedStationIDs: [], affectedSegmentIDs: [], startDate: start,
            endDate: start.addingTimeInterval(3_600), source: source,
            fetchedAt: start, confidence: confidence
        )
    }

    private func work(
        id: String,
        start: Date,
        end: Date,
        detail: String,
        segmentID: String = "segment"
    ) -> EngineeringWork {
        EngineeringWork(
            id: id,
            title: "Planned Closure",
            detail: detail,
            lineIDs: [.central],
            affectedStationIDs: ["station"],
            affectedSegmentIDs: [segmentID],
            startDate: start,
            endDate: end,
            source: .unifiedAPI,
            fetchedAt: start,
            confidence: .exact
        )
    }

    private func londonDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date? {
        LondonRailDate.calendar.date(
            from: DateComponents(
                timeZone: LondonRailDate.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )
    }

    private func maximumTrackDeviation(from points: [GeographicPoint]) -> Double {
        guard points.count > 2, let first = points.first, let last = points.last else { return 0 }
        let meanLatitude = points.reduce(0) { $0 + $1.latitude } / Double(points.count)
        let longitudeScale = 111_320 * cos(meanLatitude * .pi / 180)
        let latitudeScale = 110_574.0
        let start = (x: first.longitude * longitudeScale, y: first.latitude * latitudeScale)
        let end = (x: last.longitude * longitudeScale, y: last.latitude * latitudeScale)
        let chord = (x: end.x - start.x, y: end.y - start.y)
        let squaredLength = chord.x * chord.x + chord.y * chord.y
        guard squaredLength > 0 else { return 0 }

        return points.dropFirst().dropLast().reduce(0) { maximum, point in
            let offset = (
                x: point.longitude * longitudeScale - start.x,
                y: point.latitude * latitudeScale - start.y
            )
            let fraction = min(1, max(0, (offset.x * chord.x + offset.y * chord.y) / squaredLength))
            let deviation = hypot(
                offset.x - fraction * chord.x,
                offset.y - fraction * chord.y
            )
            return max(maximum, deviation)
        }
    }

}

private actor RateLimitedThenSuccessfulTrainFetcher: LiveTrainFetching {
    private(set) var attemptCount = 0

    func fetch(lineIDs: Set<TubeLineID>) async throws -> [LiveTubeTrain] {
        attemptCount += 1
        if attemptCount == 1 {
            // The production retry adds a short boundary grace period. A
            // nearly elapsed window keeps this regression test fast.
            throw TubeTrackAPIClientError.rateLimited(
                retryAfter: Date.now.addingTimeInterval(-0.49)
            )
        }
        return [LiveTubeTrain(
            id: "victoria:test",
            vehicleID: "test",
            lineID: .victoria,
            destination: "Brixton",
            direction: "southbound",
            previousStationID: "a",
            nextStationID: "b",
            segmentID: "segment",
            progress: 0.25,
            secondsToNextStation: 90,
            updatedAt: .now
        )]
    }
}
