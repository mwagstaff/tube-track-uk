import Foundation
import Testing
@testable import TubeTrackUK

struct TubeTrackUKTests {
    @Test func allTubeLinesHaveDisplayNames() {
        #expect(TubeLineID.allCases.count == 11)
        #expect(TubeLineID.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test func bundledGraphHasCompleteConnectedData() throws {
        let graph = try TubeGraph.bundled()
        #expect(graph.lines.count == 11)
        #expect(graph.stations.count > 250)
        #expect(graph.segments.count > 350)
        #expect(graph.segments.allSatisfy { $0.schematicPoints.count >= 2 })
        #expect(graph.segments.allSatisfy { $0.geographicPoints.count >= 2 })
        #expect(graph.segments.filter { $0.geographicPoints.count > 2 }.count > 340)
        #expect(graph.source.attribution.contains("OpenStreetMap contributors"))
        #expect(graph.segments.allSatisfy {
            graph.stationsByID[$0.fromStationID] != nil && graph.stationsByID[$0.toStationID] != nil
        })
    }

    @Test func schematicSegmentsUseOnlyBeckStyleAngles() throws {
        let graph = try TubeGraph.bundled()
        var bendCount = 0
        for segment in graph.segments {
            bendCount += max(0, segment.schematicPoints.count - 2)
            for (start, end) in zip(segment.schematicPoints, segment.schematicPoints.dropFirst()) {
                let dx = abs(end.x - start.x)
                let dy = abs(end.y - start.y)
                #expect(dx < 0.01 || dy < 0.01 || abs(dx - dy) < 0.01)
            }
        }
        #expect(bendCount < 68)
    }

    @Test func schematicCornerIsReplacedByATangentCubic() throws {
        let corner = SchematicPoint(x: 100, y: 0)
        let path = try #require(RoundedSchematicPath(
            points: [SchematicPoint(x: 0, y: 0), corner, SchematicPoint(x: 100, y: 100)],
            preferredCornerRadius: 20
        ))

        #expect(path.elements.count == 3)
        guard case let .line(entry) = path.elements[0],
              case let .curve(exit, control1, control2) = path.elements[1] else {
            Issue.record("A direction change must be a line followed by a cubic fillet")
            return
        }

        #expect(approximatelyEqual(entry, SchematicPoint(x: 80, y: 0)))
        #expect(approximatelyEqual(exit, SchematicPoint(x: 100, y: 20)))
        #expect(abs(control1.y - entry.y) < 0.000_001)
        #expect(abs(control2.x - exit.x) < 0.000_001)
        #expect(!path.sampledPoints.contains(corner))
    }

    @Test func schematicFilletRadiusIsClampedToShortLegs() throws {
        let fillet = try #require(SchematicFillet(
            incomingPoint: SchematicPoint(x: 0, y: 0),
            corner: SchematicPoint(x: 10, y: 0),
            outgoingPoint: SchematicPoint(x: 10, y: 10),
            preferredRadius: 100
        ))

        #expect(abs(fillet.tangentDistance - 4.5) < 0.000_001)
        #expect(abs(fillet.effectiveRadius - 4.5) < 0.000_001)
        #expect(approximatelyEqual(fillet.entry, SchematicPoint(x: 5.5, y: 0)))
        #expect(approximatelyEqual(fillet.exit, SchematicPoint(x: 10, y: 4.5)))
    }

    @Test func neighbouringSchematicFilletsCannotOverlap() throws {
        let path = try #require(RoundedSchematicPath(
            points: [
                SchematicPoint(x: 0, y: 0),
                SchematicPoint(x: 10, y: 0),
                SchematicPoint(x: 10, y: 10),
                SchematicPoint(x: 20, y: 10),
            ],
            preferredCornerRadius: 100
        ))

        let curves = path.elements.compactMap { element -> (SchematicPoint, SchematicPoint)? in
            guard case let .curve(to, _, control2) = element else { return nil }
            return (to, control2)
        }
        #expect(curves.count == 2)
        #expect(curves[0].0.y <= 4.5 + 0.000_001)
        guard case let .line(secondEntry) = path.elements[2] else {
            Issue.record("The second fillet must retain a straight run after the first")
            return
        }
        #expect(secondEntry.y >= 5.5 - 0.000_001)
    }

    @Test func straightSchematicRunsRemainStraight() throws {
        let path = try #require(RoundedSchematicPath(
            points: [
                SchematicPoint(x: 0, y: 0),
                SchematicPoint(x: 50, y: 0),
                SchematicPoint(x: 100, y: 0),
            ],
            preferredCornerRadius: 28
        ))
        #expect(path.elements.allSatisfy { element in
            if case .line = element { return true }
            return false
        })
    }

    @Test func bundledSchematicAddsCurvesThroughStations() throws {
        let graph = try TubeGraph.bundled()
        let geometry = SchematicNetworkGeometry(
            graph: graph,
            laneOffsets: [:],
            preferredCornerRadius: 28
        )

        #expect(geometry.segmentPaths.count == graph.segments.count)
        #expect(geometry.connectors.count > 100)
        let holbornID = try #require(graph.stations.first { $0.name == "Holborn" }?.id)
        let holbornSegments = Set(graph.segments.filter {
            $0.lineID == .piccadilly && ($0.fromStationID == holbornID || $0.toStationID == holbornID)
        }.map(\.id))
        let holbornConnector = geometry.connectors.first {
            $0.lineID == .piccadilly
                && holbornSegments.contains($0.incomingSegmentID)
                && holbornSegments.contains($0.outgoingSegmentID)
        }
        #expect(holbornConnector != nil)
        #expect(holbornConnector?.path.elements.contains { element in
            if case .curve = element { return true }
            return false
        } == true)
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

    @Test func routineOvernightClosureIsNotAnActionableDisruption() {
        let closure = TfLStatusEntry(
            id: 20, statusSeverity: 20, statusSeverityDescription: "Service Closed",
            reason: "Waterloo and City Line: Service will resume at 06:00.",
            validityPeriods: nil, disruption: nil
        )
        #expect(closure.isOvernightClosure)
        #expect(!closure.isActionableIssue)
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
        #expect(train.projectedProgress(at: Date(timeIntervalSince1970: 1_050)) == 0.75)
        #expect(train.projectedProgress(at: Date(timeIntervalSince1970: 1_500)) == 1)
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

    private func approximatelyEqual(
        _ left: SchematicPoint,
        _ right: SchematicPoint,
        tolerance: Double = 0.000_001
    ) -> Bool {
        abs(left.x - right.x) <= tolerance && abs(left.y - right.y) <= tolerance
    }
}
