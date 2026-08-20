import CoreGraphics
import Foundation
import Testing
@testable import TubeTrackUK

struct TubeTrackUKTests {
    @Test func allTubeLinesHaveDisplayNames() {
        #expect(TubeLineID.allCases.count == 13)
        #expect(TubeLineID.undergroundCases.count == 11)
        #expect(TubeLineID.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(TubeLineID.dlr.modeName == "dlr")
        #expect(TubeLineID.elizabeth.modeName == "elizabeth-line")
        #expect(!TubeLineID.dlr.supportsEstimatedTrains)
        #expect(TubeLineID.elizabeth.supportsEstimatedTrains)
    }

    @Test func bundledGraphHasCompleteConnectedData() throws {
        let graph = try TubeGraph.bundled()
        #expect(graph.lines.count == 13)
        #expect(graph.stations.count > 250)
        #expect(graph.segments.count > 350)
        #expect(graph.segments.allSatisfy { $0.geographicPoints.count >= 2 })
        #expect(graph.segments.filter { $0.geographicPoints.count > 2 }.count > 340)
        #expect(graph.source.attribution.contains("OpenStreetMap contributors"))
        #expect(graph.segments.allSatisfy {
            graph.stationsByID[$0.fromStationID] != nil && graph.stationsByID[$0.toStationID] != nil
        })
        #expect(graph.line(.dlr)?.routes.count == 5)
        #expect(graph.line(.elizabeth)?.routes.count == 9)
        #expect(graph.segments(for: .dlr).count == 46)
        #expect(graph.segments(for: .elizabeth).count == 42)
        let bankStops = graph.stations.filter { $0.hubID == "HUBBAN" }
        #expect(bankStops.contains { $0.lineIDs.contains(.dlr) })
        #expect(bankStops.contains { $0.lineIDs.contains(.central) })
        #expect(bankStops.allSatisfy { $0.interchange })
    }

    @Test func realWorldRailLinesUseDetailedTrackGeometry() throws {
        let graph = try TubeGraph.bundled()

        for lineID in [TubeLineID.dlr, .elizabeth] {
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

        let selectedDLRStation = "940GZZDLBNK"
        let withSelection = RealWorldStationDisplay.stations(
            in: graph,
            selectedStationID: selectedDLRStation
        )
        #expect(withSelection.contains { $0.id == selectedDLRStation })
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

    @Test @MainActor func defaultDisruptionHighlightsPrioritizeClosuresAndSevereDelays() {
        let appState = TubeAppState()
        let closure = disruption(id: "closure", severity: 5, segmentID: "closure-segment")
        let severe = disruption(id: "severe", severity: 6, segmentID: "severe-segment")
        let minor = disruption(id: "minor", severity: 9, segmentID: "minor-segment")
        appState.disruptions = [closure, severe, minor]

        #expect(appState.disruptionDisplayMode == .issues)
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
