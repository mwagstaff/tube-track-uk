import CoreGraphics
import Foundation
import Testing
@testable import TubeTrackUK

struct TubeTrackUKTests {
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
        #expect(!TubeLineID.dlr.supportsEstimatedTrains)
        #expect(TubeLineID.tram.supportsEstimatedTrains)
        #expect(TubeLineID.elizabeth.supportsEstimatedTrains)
    }

    @Test func bundledGraphHasCompleteConnectedData() throws {
        let graph = try TubeGraph.bundled()
        #expect(graph.lines.count == 20)
        #expect(graph.stations.count == 509)
        #expect(graph.segments.count == 617)
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
        #expect(graph.segments(for: .weaver).count == 24)
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

    @Test func disruptionDisplayModesReverseSectionEmphasis() {
        #expect(DisruptionDisplayMode.normal.mutesSegment(isAffected: true))
        #expect(!DisruptionDisplayMode.normal.mutesSegment(isAffected: false))
        #expect(!DisruptionDisplayMode.issues.mutesSegment(isAffected: true))
        #expect(DisruptionDisplayMode.issues.mutesSegment(isAffected: false))
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

    @Test func weekendDateSelectionsUseUpcomingLondonDays() throws {
        let thursday = try #require(londonDate(year: 2026, month: 8, day: 20, hour: 12))
        let saturday = try #require(londonDate(year: 2026, month: 8, day: 22))
        let sunday = try #require(londonDate(year: 2026, month: 8, day: 23))

        #expect(DisruptionDateSelection.thisSaturday.date(relativeTo: thursday) == saturday)
        #expect(DisruptionDateSelection.thisSunday.date(relativeTo: thursday) == sunday)
        #expect(DisruptionDateSelection.thisSaturday.date(relativeTo: saturday) == saturday)
        #expect(DisruptionDateSelection.thisSunday.date(relativeTo: saturday) == sunday)
        #expect(DisruptionDateSelection.thisSunday.date(relativeTo: sunday) == sunday)
        #expect(
            DisruptionDateSelection.thisSaturday.date(relativeTo: sunday)
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

        #expect(appState.disruptionDateSelection == .today)
        #expect(appState.visibleDisruptions.map(\.id) == ["live"])

        appState.setDisruptionDateSelection(.custom(selectedDate))

        #expect(appState.selectedDisruptionID == nil)
        #expect(appState.selectedEngineeringWorkID == nil)
        #expect(appState.selectedEngineeringWorks.map(\.id) == ["weekend-work"])
        #expect(appState.visibleDisruptions.count == 1)
        #expect(appState.visibleDisruptions[0].category == .closures)
        #expect(appState.activeAffectedSegmentIDs == plannedWork.affectedSegmentIDs)
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
        #expect(appState.liveTrains.isEmpty)
        #expect(appState.stationArrivals.isEmpty)
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
