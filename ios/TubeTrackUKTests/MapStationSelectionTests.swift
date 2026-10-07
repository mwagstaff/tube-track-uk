import SwiftUI
import Testing
@testable import TubeTrackUK

@MainActor
struct MapStationSelectionTests {
    @Test func everyCombinedMapRoundelIsHighlightedWhenTapped() throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let roundels = try #require(document.referenceArtwork?.stationRoundels)
        #expect(roundels.count == 374)
        for tapped in roundels {
            let tap = try #require(BeckMapStationTapResolver.resolve(
                screenPoint: CGPoint(x: tapped.centre.x, y: tapped.centre.y),
                cameraScale: 1, cameraOffset: .zero, document: document,
                renderedSegments: [], graph: graph
            ))
            let stationIDs = BeckMapStationSelection.stationIDs(for: tap.stationID, in: graph)
            let selection = BeckMapStationSelection(document: document, stationIDs: stationIDs)
            #expect(selection.usesReferenceRoundels)
            #expect(selection.roundels.contains { $0.centre == tapped.centre }, "Missing tapped circle: \(tap.stationID)")
            for sibling in roundels where stationIDs.contains(sibling.stationID) {
                #expect(selection.roundels.contains { $0.centre == sibling.centre }, "Missing interchange circle: \(tap.stationID)")
            }
        }
    }

    @Test func everyOriginalMapRoundelIsHighlightedWhenTapped() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let cache = BeckMapCanvas.RenderCache(document: document)
        var count = 0
        for marker in document.stationMarkers {
            for primitive in marker.primitives {
                guard case let .circle(circle) = primitive else { continue }
                count += 1
                let tap = try #require(BeckMapStationTapResolver.resolve(
                    screenPoint: CGPoint(x: circle.centre.x, y: circle.centre.y),
                    cameraScale: 1, cameraOffset: .zero, document: document,
                    renderedSegments: cache.renderedSegments, graph: graph
                ))
                let stationIDs = BeckMapStationSelection.stationIDs(for: tap.stationID, in: graph)
                let selection = BeckMapStationSelection(document: document, stationIDs: stationIDs)
                #expect(!selection.usesReferenceRoundels)
                #expect(selection.roundels.contains { $0.centre == circle.centre }, "Missing tapped circle: \(tap.stationID)")
                #expect(Set(selection.roundels.map(\.centre)).count == selection.roundels.count)
            }
        }
        #expect(count == 270)
    }

    @Test(arguments: ["940GZZLUBKF", "910GBLFR"])
    func blackfriarsHighlightsAllThreeServiceCircles(selectedStationID: String) throws {
        let selection = try combinedSelection(selectedStationID)
        #expect(Set(selection.roundels.map(\.centre)) == [
            BeckMapPoint(x: 1329.797, y: 1042.117),
            BeckMapPoint(x: 1356.096, y: 1068.737),
            BeckMapPoint(x: 1366.307, y: 1068.737)
        ])
    }

    @Test(arguments: ["940GZZLUBND", "910GBONDST"])
    func bondStreetHighlightsTheWholeCompoundInterchange(selectedStationID: String) throws {
        let selection = try combinedSelection(selectedStationID)
        #expect(Set(selection.roundels.map(\.centre)) == [
            BeckMapPoint(x: 1069.276, y: 867.296),
            BeckMapPoint(x: 1049.963, y: 886.630),
            BeckMapPoint(x: 1010.790, y: 925.784)
        ])
    }

    @Test func newCrossHighlightDoesNotIncludeNewCrossGate() throws {
        let selection = try combinedSelection("910GNWCRELL")
        #expect(selection.roundels.map(\.centre) == [BeckMapPoint(x: 1678.642, y: 1349.018)])
        #expect(try combinedSelection("910GNEWXGTE").roundels.count == 2)
    }

    @Test(arguments: [CGFloat(0.2), 1, 3.8])
    func halosSurroundTheVisibleCircleAtEveryZoom(scale: CGFloat) throws {
        let selection = try combinedSelection("940GZZLUBKF")
        let path = selection.haloPath(cameraScale: scale)
        for roundel in selection.roundels {
            #expect(path.contains(CGPoint(x: roundel.centre.x + roundel.radius + 2 / scale,
                                          y: roundel.centre.y)))
        }
    }

    @Test func clearingSelectionRemovesAllHighlightsAndTicksStillHaveAnIndicator() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let stationIDs = BeckMapStationSelection.stationIDs(for: nil, in: graph)
        #expect(stationIDs.isEmpty)
        #expect(BeckMapStationSelection(document: document, stationIDs: stationIDs).roundels.isEmpty)
        let marker = try #require(document.stationMarkers.first { marker in
            marker.primitives.allSatisfy { primitive in
                if case .circle = primitive { return false }
                return true
            }
        })
        let tickSelection = BeckMapStationSelection(document: document, stationIDs: [marker.stationID])
        let centres = marker.primitives.compactMap { primitive -> BeckMapPoint? in
            guard case let .tick(tick) = primitive else { return nil }
            return BeckMapPoint(x: (tick.start.x + tick.end.x) / 2, y: (tick.start.y + tick.end.y) / 2)
        }
        #expect(Set(tickSelection.roundels.map(\.centre)) == Set(centres))
    }

    private func combinedSelection(_ stationID: String) throws -> BeckMapStationSelection {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        return BeckMapStationSelection(document: document,
            stationIDs: BeckMapStationSelection.stationIDs(for: stationID, in: graph))
    }
}
