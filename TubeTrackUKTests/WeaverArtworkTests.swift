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
        let leftPort = BeckMapPoint(x: 2831.172, y: 1220.895)
        let rightPort = BeckMapPoint(x: 2857.172, y: 1220.895)

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
        let leftPort = BeckMapPoint(x: 2831.172, y: 1220.895)
        let rightPort = BeckMapPoint(x: 2857.172, y: 1220.895)
        let centralPort = BeckMapPoint(x: 2905.59, y: 1269.313)

        #expect(downs.anchor == leftPort)
        #expect(central.anchor == centralPort)
        #expect(circleCentres(in: downs) == [leftPort, rightPort, centralPort])
        #expect(connectors(in: downs) == [
            BeckMapLinePrimitive(start: leftPort, end: rightPort, width: 7.5),
            BeckMapLinePrimitive(start: rightPort, end: centralPort, width: 7.5),
        ])
        #expect(abs(centralPort.y - leftPort.y - 48.418) < 0.001)

        let label = try #require(document.labels.first { $0.id == "label.910GHAKNYNM" })
        #expect(label.position == BeckMapPoint(x: 2815.172, y: 1202.895))
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
