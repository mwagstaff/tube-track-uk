import Foundation
import Testing
@testable import TubeTrackUK

struct BeckMapAffectedSegmentProjectorTests {
    @Test func graphApproximationProjectsToTheAuthoredHeathrowLoopLeg() throws {
        let (document, graph, projector) = try fixture()

        let projected = projector.projectedSegmentIDs(
            for: [
                "piccadilly:940GZZLUHNX:940GZZLUHRC",
                "piccadilly:940GZZLUHR4:940GZZLUHRC",
            ],
            on: .piccadilly,
            confidence: .inferred
        )

        #expect(projected == [BeckMapRepository.supplementalHeathrowSegmentID])
        #expect(document.segments.contains { projected.contains($0.id) })
        #expect(graph.segmentsByID[BeckMapRepository.supplementalHeathrowSegmentID] == nil)
    }

    @Test func ambiguousAuthoredBranchesFallBackToExactSharedIDs() throws {
        let (_, _, projector) = try fixture()
        let directSegmentID = "piccadilly:940GZZLUHNX:940GZZLUHRC"

        let projected = projector.projectedSegmentIDs(
            for: [directSegmentID],
            on: .piccadilly,
            confidence: .exact
        )

        #expect(projected == [directSegmentID])
        #expect(!projected.contains(BeckMapRepository.supplementalHeathrowSegmentID))
    }

    @Test func wholeLineStateIncludesEveryAuthoredSegmentOnThatLine() throws {
        let (document, graph, projector) = try fixture()
        let authoredPiccadillyIDs = Set(
            document.segments.filter { $0.lineID == .piccadilly }.map(\.id)
        )

        let projected = projector.projectedSegmentIDs(
            for: Set(graph.segments(for: .piccadilly).map(\.id)),
            on: .piccadilly,
            confidence: .lineOnly
        )

        #expect(projected == authoredPiccadillyIDs)
        #expect(projected.contains(BeckMapRepository.supplementalHeathrowSegmentID))
    }

    @Test func disconnectedGraphSectionsDoNotCauseAnAuthoredRouteGuess() throws {
        let (_, _, projector) = try fixture()
        let exactAuthoredID = "piccadilly:940GZZLUHNX:940GZZLUHWT"

        let projected = projector.projectedSegmentIDs(
            for: [
                exactAuthoredID,
                "piccadilly:940GZZLUACT:940GZZLUECM",
            ],
            on: .piccadilly,
            confidence: .inferred
        )

        #expect(projected == [exactAuthoredID])
    }

    @Test func linesOutsideTheAuthoredSliceProjectToNoArtwork() throws {
        let (_, graph, projector) = try fixture()

        let projected = projector.projectedSegmentIDs(
            for: Set(graph.segments(for: .central).map(\.id)),
            on: .central,
            confidence: .lineOnly
        )

        #expect(projected.isEmpty)
    }

    private func fixture() throws -> (
        document: BeckMapDocument,
        graph: TubeGraph,
        projector: BeckMapAffectedSegmentProjector
    ) {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(graph: graph)
        return (
            document,
            graph,
            BeckMapAffectedSegmentProjector(document: document, graph: graph)
        )
    }
}
