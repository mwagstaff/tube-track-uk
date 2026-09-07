import Foundation
import Testing
@testable import TubeTrackUK

struct MobileCoverageTests {
    @Test func bundledSnapshotMatchesTheCurrentGraphAndSource() throws {
        let graph = try TubeGraph.bundled()
        let coverage = try MobileCoverageRepository().load(graph: graph)

        #expect(coverage.identifier == "tfl-mobile-coverage-2026-08")
        #expect(coverage.publishedAt == "2026-08-18")
        #expect(coverage.sourceURL.hasSuffix("tube-map-below-ground-4g-and-5g-coverage.pdf"))
        #expect(!coverage.coveredTunnelSegmentIDs.isEmpty)
        #expect(!coverage.coveredStationIDs.isEmpty)
        #expect(!coverage.stationOnlyCoverageStationIDs.isEmpty)
        #expect(coverage.coveredTunnelSegmentIDs.isSubset(of: coverage.belowGroundSegmentIDs))
        #expect(coverage.stationOnlyCoverageStationIDs.isSubset(of: coverage.coveredStationIDs))
    }

    @Test func modesSeparateUsableSurfaceCoverageFromVerifiedTunnels() throws {
        let graph = try TubeGraph.bundled()
        let coverage = try MobileCoverageRepository().load(graph: graph)
        let covered = try #require(graph.segments.first {
            coverage.coveredTunnelSegmentIDs.contains($0.id)
        })
        let unavailable = try #require(graph.segments.first {
            coverage.belowGroundSegmentIDs.contains($0.id)
                && !coverage.coveredTunnelSegmentIDs.contains($0.id)
                && coverage.verifiedLineIDs.contains($0.lineID)
        })
        let unknown = try #require(graph.segments.first {
            coverage.belowGroundSegmentIDs.contains($0.id)
                && !coverage.verifiedLineIDs.contains($0.lineID)
        })
        let surface = try #require(graph.segments.first {
            !coverage.belowGroundSegmentIDs.contains($0.id)
        })

        #expect(coverage.availability(for: covered, mode: .allUsable) == .available)
        #expect(coverage.availability(for: unavailable, mode: .allUsable) == .unavailable)
        #expect(coverage.availability(for: unknown, mode: .allUsable) == .unknown)
        #expect(coverage.availability(for: surface, mode: .allUsable) == .available)
        #expect(coverage.availability(for: surface, mode: .undergroundOnly) == .outOfScope)
    }

    @Test @MainActor func coverageControlCyclesAndReplacesDisruptionHighlighting() {
        let appState = TubeAppState()

        appState.cycleMobileCoverageMode()
        #expect(appState.mobileCoverageMode == .allUsable)

        appState.cycleMobileCoverageMode()
        #expect(appState.mobileCoverageMode == .undergroundOnly)

        appState.setDisruptionHighlightScope(.all)
        #expect(appState.mobileCoverageMode == .off)
        #expect(appState.selectedMapNetworkStat == .disrupted)

        appState.setMobileCoverageMode(.allUsable)
        #expect(appState.selectedMapNetworkStat == nil)
        #expect(appState.disruptionDisplayMode == .normal)

        appState.cycleMobileCoverageMode()
        appState.cycleMobileCoverageMode()
        #expect(appState.mobileCoverageMode == .off)
    }
}
