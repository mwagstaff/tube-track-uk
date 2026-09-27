import Foundation
import Testing
@testable import TubeTrackUK

struct WeaverArtworkTests {
    @Test func chingfordBranchBypassesCambridgeHeathAndLondonFields() throws {
        let graph = try TubeGraph.bundled()
        let weaver = try #require(graph.line(.weaver))
        let chingfordRoute = try #require(weaver.routes.first)
        let bypassID = "weaver:910GBTHNLGR:910GHAKNYNM"

        #expect(chingfordRoute == [
            "910GLIVST",
            "910GBTHNLGR",
            "910GHAKNYNM",
            "910GCLAPTON",
            "910GSTJMSST",
            "910GWLTWCEN",
            "910GWDST",
            "910GHGHMSPK",
            "910GCHINGFD",
        ])
        #expect(weaver.segmentIDs.contains(bypassID))

        let bypass = try #require(graph.segmentsByID[bypassID])
        #expect(bypass.fromStationID == "910GBTHNLGR")
        #expect(bypass.toStationID == "910GHAKNYNM")
    }

    @Test func beckArtworkUsesSeparateHackneyDownsBranchPorts() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let segments = Dictionary(uniqueKeysWithValues: document.segments.map { ($0.id, $0) })
        // TfL's Chingford lane runs 24.24 units east of the Enfield lane.
        let leftPort = BeckMapPoint(x: 2831.172, y: 1220.895)
        let rightPort = BeckMapPoint(x: 2855.462, y: 1220.895)

        #expect(try #require(segments["weaver:910GHAKNYNM:910GLONFLDS"]).toPort == leftPort)
        #expect(try #require(segments["weaver:910GHAKNYNM:910GRCTRYRD"]).fromPort == leftPort)
        #expect(try #require(segments["weaver:910GBTHNLGR:910GHAKNYNM"]).toPort == rightPort)
        #expect(try #require(segments["weaver:910GCLAPTON:910GHAKNYNM"]).fromPort == rightPort)

        let chingfordRoute = try #require(document.routes.first {
            $0.id == "weaver.graph-route.0.v1"
        })
        #expect(!chingfordRoute.stationIDs.contains("910GCAMHTH"))
        #expect(!chingfordRoute.stationIDs.contains("910GLONFLDS"))
        #expect(chingfordRoute.segmentIDs.contains("weaver:910GBTHNLGR:910GHAKNYNM"))
    }

    @Test func hackneyDownsUsesTfLPlatformAndCentralConnectors() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let downs = try #require(document.stationMarkers.first {
            $0.stationID == "910GHAKNYNM"
        })
        let central = try #require(document.stationMarkers.first {
            $0.stationID == "910GHACKNYC"
        })
        // TfL's two Hackney Downs roundels, a horizontal bar between them
        // and a 45-degree bar on to Hackney Central.
        let left = BeckMapPoint(x: 2831.008, y: 1219.945)
        let right = BeckMapPoint(x: 2855.156, y: 1219.953)
        let centralRoundel = BeckMapPoint(x: 2903.469, y: 1269.195)

        #expect(downs.anchor == right)
        #expect(central.anchor == centralRoundel)
        #expect(circleCentres(in: downs) == [left, right])
        #expect(circleCentres(in: central) == [centralRoundel])
        let bars = Array(connectors(in: downs)) + Array(connectors(in: central))
        #expect(bars.count == 2)
        #expect(bars.contains { isNear($0.start, left) && isNear($0.end, right) && $0.start.y == $0.end.y })
        #expect(bars.contains { bar in
            isNear(bar.start, right) && isNear(bar.end, centralRoundel)
                && abs(abs(bar.end.x - bar.start.x) - abs(bar.end.y - bar.start.y)) < 0.001
        })

        let label = try #require(document.labels.first { $0.id == "label.910GHAKNYNM" })
        #expect(label.position.x < left.x)
    }

    private func isNear(_ a: BeckMapPoint, _ b: BeckMapPoint) -> Bool {
        hypot(a.x - b.x, a.y - b.y) < 0.5
    }

    private func circleCentres(in marker: BeckMapStationMarkerRecord) -> Set<BeckMapPoint> {
        Set(marker.primitives.compactMap { primitive in
            guard case let .circle(circle) = primitive else { return nil }
            return circle.centre
        })
    }

    private func connectors(in marker: BeckMapStationMarkerRecord) -> Set<BeckMapLinePrimitive> {
        Set(marker.primitives.compactMap { primitive in
            guard case let .connector(connector) = primitive else { return nil }
            return connector
        })
    }
}
