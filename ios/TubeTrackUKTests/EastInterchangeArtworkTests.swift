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
        let sharedPort = BeckMapPoint(x: 3280.781, y: 1545.945)
        let jubileePort = BeckMapPoint(x: 3229.053, y: 1518.282)

        #expect(dlrMarker.anchor == sharedPort)
        #expect(circleCentres(in: [tubeMarker, dlrMarker]) == [jubileePort, sharedPort])
        #expect(connectors(in: [tubeMarker, dlrMarker]) == [
            BeckMapLinePrimitive(start: jubileePort, end: sharedPort, width: 7.5),
        ])

        let subSurfaceSegments = document.segments.filter {
            ($0.fromStationID == tubeMarker.stationID || $0.toStationID == tubeMarker.stationID)
                && ($0.lineID == .district || $0.lineID == .hammersmithCity)
        }
        #expect(subSurfaceSegments.count == 4)
        #expect(subSurfaceSegments.allSatisfy { segment in
            let stationPort = segment.fromStationID == tubeMarker.stationID
                ? segment.fromPort
                : segment.toPort
            return stationPort?.x == sharedPort.x
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
        let sharedPort = BeckMapPoint(x: 2704.938, y: 1545)
        let elizabethPort = BeckMapPoint(x: 2735.05, y: 1516.281)

        #expect(tubeMarker.anchor == sharedPort)
        #expect(windrushMarker.anchor == sharedPort)
        #expect(circleCentres(in: [tubeMarker, windrushMarker, elizabethMarker]) == [
            sharedPort,
            elizabethPort,
        ])
        #expect(connectors(in: [tubeMarker, windrushMarker, elizabethMarker]) == [
            BeckMapLinePrimitive(start: sharedPort, end: elizabethPort, width: 7.5),
        ])

        let windrushSegments = document.segments.filter {
            $0.fromStationID == windrushMarker.stationID || $0.toStationID == windrushMarker.stationID
        }
        #expect(windrushSegments.count == 2)
        #expect(windrushSegments.allSatisfy { segment in
            let stationPort = segment.fromStationID == windrushMarker.stationID
                ? segment.fromPort
                : segment.toPort
            return stationPort == sharedPort
        })

        let label = try #require(document.labels.first { $0.id == "label.940GZZLUWPL" })
        #expect(label.associatedStationIDs == [windrushMarker.stationID, elizabethMarker.stationID])
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
