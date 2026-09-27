import Foundation
import Testing
@testable import TubeTrackUK

struct EastInterchangeArtworkTests {
    @Test func westHamUsesOneSharedDLRAndSubSurfaceRoundel() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let tubeMarker = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUWHM"
        })
        let dlrMarker = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZDLWHM"
        })
        let sharedPort = BeckMapPoint(x: 3280.789, y: 1545.531)
        let jubileePort = BeckMapPoint(x: 3253.062, y: 1517.797)

        #expect(dlrMarker.anchor == sharedPort)
        #expect(circleCentres(in: [tubeMarker, dlrMarker]) == [jubileePort, sharedPort])
        let bars = connectors(in: [tubeMarker, dlrMarker])
        #expect(bars.count == 1)
        for bar in bars {
            #expect(isNear(bar.start, jubileePort) && isNear(bar.end, sharedPort))
            #expect(abs(abs(bar.end.x - bar.start.x) - abs(bar.end.y - bar.start.y)) < 0.001)
            #expect(bar.width == 12.4)
        }

        let subSurfaceSegments = document.segments.filter {
            ($0.fromStationID == tubeMarker.stationID || $0.toStationID == tubeMarker.stationID)
                && ($0.lineID == .district || $0.lineID == .hammersmithCity)
        }
        #expect(subSurfaceSegments.count == 4)
        #expect(subSurfaceSegments.allSatisfy { segment in
            let stationPort = segment.fromStationID == tubeMarker.stationID
                ? segment.fromPort
                : segment.toPort
            return stationPort.map { abs($0.x - sharedPort.x) < 0.05 } == true
        })

        let label = try #require(document.labels.first { $0.id == "label.940GZZLUWHM" })
        #expect(label.associatedStationIDs == [dlrMarker.stationID])
    }

    @Test func whitechapelUsesOneSharedWindrushAndSubSurfaceRoundel() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let tubeMarker = try #require(document.stationMarkers.first {
            $0.stationID == "940GZZLUWPL"
        })
        let windrushMarker = try #require(document.stationMarkers.first {
            $0.stationID == "910GWCHAPEL"
        })
        let elizabethMarker = try #require(document.stationMarkers.first {
            $0.stationID == "910GWCHAPXR"
        })
        let sharedPort = BeckMapPoint(x: 2704.852, y: 1545.617)
        let elizabethPort = BeckMapPoint(x: 2735.141, y: 1516.258)

        #expect(tubeMarker.anchor == sharedPort)
        #expect(windrushMarker.anchor == sharedPort)
        #expect(circleCentres(in: [tubeMarker, windrushMarker, elizabethMarker]) == [
            sharedPort,
            elizabethPort,
        ])
        let bars = connectors(in: [tubeMarker, windrushMarker, elizabethMarker])
        #expect(bars.count == 1)
        for bar in bars {
            #expect(
                (isNear(bar.start, sharedPort) && isNear(bar.end, elizabethPort))
                    || (isNear(bar.start, elizabethPort) && isNear(bar.end, sharedPort))
            )
            #expect(abs(abs(bar.end.x - bar.start.x) - abs(bar.end.y - bar.start.y)) < 0.001)
        }

        let windrushSegments = document.segments.filter {
            $0.fromStationID == windrushMarker.stationID || $0.toStationID == windrushMarker.stationID
        }
        #expect(windrushSegments.count == 2)
        #expect(windrushSegments.allSatisfy { segment in
            let stationPort = segment.fromStationID == windrushMarker.stationID
                ? segment.fromPort
                : segment.toPort
            return stationPort.map { isNear($0, sharedPort) } == true
        })

        let label = try #require(document.labels.first { $0.id == "label.940GZZLUWPL" })
        #expect(label.associatedStationIDs == [windrushMarker.stationID, elizabethMarker.stationID])
    }

    /// Bars are squared to 45 degrees about their midpoint, so their ends
    /// sit within a fraction of a unit of the TfL symbol centres.
    private func isNear(_ a: BeckMapPoint, _ b: BeckMapPoint) -> Bool {
        hypot(a.x - b.x, a.y - b.y) < 0.5
    }

    private func circleCentres(
        in markers: [BeckMapStationMarkerRecord]
    ) -> Set<BeckMapPoint> {
        Set(markers.flatMap(\.primitives).compactMap { primitive in
            guard case let .circle(circle) = primitive else { return nil }
            return circle.centre
        })
    }

    private func connectors(
        in markers: [BeckMapStationMarkerRecord]
    ) -> Set<BeckMapLinePrimitive> {
        Set(markers.flatMap(\.primitives).compactMap { primitive in
            guard case let .connector(connector) = primitive else { return nil }
            return connector
        })
    }
}
