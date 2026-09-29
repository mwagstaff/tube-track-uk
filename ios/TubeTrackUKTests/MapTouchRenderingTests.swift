import MapKit
import SwiftUI
import Testing
@testable import TubeTrackUK

@MainActor
struct MapTouchRenderingTests {
    @Test func repeatedCameraUpdatesRetainGeographicOverlayObjects() throws {
        let graph = try TubeGraph.bundled()
        let data = RealWorldMapRenderData(graph: graph)
        let affected = Set(graph.segments.prefix(80).map(\.id))
        let unaffected = Set(graph.segments.map(\.id)).subtracting(affected)
        let initial = data.polylines(covering: unaffected)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<120 {
            _ = data.polylines(covering: affected)
            _ = data.polylines(covering: unaffected)
            _ = data.polylines(covering: [])
        }
        print("120 map geometry updates: \(start.duration(to: clock.now))")
        let updated = data.polylines(covering: unaffected)
        #expect(!initial.isEmpty)
        #expect(initial.map(\.id) == updated.map(\.id))
        #expect(zip(initial, updated).allSatisfy { $0.overlay === $1.overlay })
    }

    @Test func changingDisruptionScopeProducesTheCorrectOverlaySegments() throws {
        let graph = try TubeGraph.bundled()
        let data = RealWorldMapRenderData(graph: graph)
        let firstScope = Set(graph.segments.prefix(80).map(\.id))
        let secondScope = Set(graph.segments.suffix(80).map(\.id))
        let first = data.polylines(covering: firstScope)
        let second = data.polylines(covering: secondScope)
        #expect(Set(first.flatMap(\.segmentIDs)) == firstScope)
        #expect(Set(second.flatMap(\.segmentIDs)) == secondScope)
        #expect(data.polylines(covering: []).isEmpty)
        let restored = data.polylines(covering: firstScope)
        #expect(zip(first, restored).allSatisfy { $0.overlay === $1.overlay })
    }

    @Test func fullNetworkUsesTheOriginalOverlaysAndNewGraphsHaveIndependentCaches() throws {
        let graph = try TubeGraph.bundled()
        let data = RealWorldMapRenderData(graph: graph)
        let all = data.polylines(covering: Set(graph.segments.map(\.id)))
        #expect(all.count == data.polylines.count)
        #expect(zip(all, data.polylines).allSatisfy { $0.overlay === $1.overlay })

        let scope = Set(graph.segments.prefix(20).map(\.id))
        let old = data.polylines(covering: scope)
        let replacement = RealWorldMapRenderData(graph: graph).polylines(covering: scope)
        #expect(zip(old, replacement).allSatisfy { $0.overlay !== $1.overlay })
    }

    @Test func labelLayoutSurvivesTouchUpdatesButInvalidatesForVisualChanges() {
        let cache = BeckMapLabelLayoutCache()
        var builds = 0
        func layout(_ key: BeckMapLabelCacheKey) -> [StationLabelPlacement] {
            cache.placements(for: key) {
                builds += 1
                return [StationLabelPlacement(
                    labelID: "layout-\(builds)", position: .zero, alignment: .leading,
                    rotation: .identity, backgroundBounds: .zero, collisionFrame: .zero
                )]
            }
        }

        let original = layout(labelKey())
        for _ in 0..<120 {
            #expect(layout(labelKey()).first?.labelID == original.first?.labelID)
        }
        #expect(builds == 1)

        // These alter actual label pixels or placement. Each must invalidate,
        // including accessibility text sizing and a new graph/document.
        let changedKeys = [
            labelKey(scale: 0.8), labelKey(offset: CGSize(width: 30, height: 40)),
            labelKey(size: CGSize(width: 932, height: 430)),
            labelKey(typeScale: 1.6), labelKey(colorScheme: .dark),
            labelKey(stationID: "selected"), labelKey(graphID: "new-graph"),
            labelKey(documentID: "new-document"),
        ]
        for key in changedKeys {
            let previousCount = builds
            _ = layout(key)
            _ = layout(key)
            #expect(builds == previousCount + 1)
        }
    }

    private func labelKey(
        scale: CGFloat = 0.5, offset: CGSize = .zero,
        size: CGSize = CGSize(width: 430, height: 932), typeScale: CGFloat = 1,
        colorScheme: ColorScheme = .light, stationID: String? = nil,
        graphID: String = "graph", documentID: String = "map"
    ) -> BeckMapLabelCacheKey {
        BeckMapLabelCacheKey(
            documentID: documentID, graphGeneratedAt: graphID,
            presentation: BeckMapPresentationSnapshot(
                selectedLineID: nil, selectedStationID: stationID,
                affectedSegmentIDs: [], affectedStationIDs: [], disruptionDisplayMode: .normal,
                networkFilter: nil, networkFeaturedLineIDs: [], networkFeaturedSegmentIDs: [],
                networkSectionLineIDs: [], closedLineIDs: [], mobileCoverageMode: .off,
                mobileCoverageBySegmentID: [:], mobileCoverageByStationID: [:],
                stationOnlyCoverageStationIDs: []
            ),
            colorScheme: colorScheme, cameraScale: scale, cameraOffset: offset,
            canvasSize: size, labelTypeScale: typeScale
        )
    }
}
