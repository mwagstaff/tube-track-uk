import Testing
@testable import TubeTrackUK

struct RichmondBranchArtworkTests {
    @Test func districtAndMildmayStationsUsePairedRoundels() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let markersByID = Dictionary(uniqueKeysWithValues: document.stationMarkers.map {
            ($0.stationID, $0)
        })
        let stations: [(districtID: String, mildmayID: String, districtPort: BeckMapPoint, mildmayPort: BeckMapPoint)] = [
            (
                "940GZZLURMD",
                "910GRICHMND",
                BeckMapPoint(x: 580.971, y: 2139.592),
                BeckMapPoint(x: 598.908, y: 2157.53)
            ),
            (
                "940GZZLUKWG",
                "910GKEWGRDN",
                BeckMapPoint(x: 652.261, y: 2068.301),
                BeckMapPoint(x: 670.199, y: 2086.239)
            ),
            (
                "940GZZLUGBY",
                "910GGNRSBRY",
                BeckMapPoint(x: 766.339, y: 1954.224),
                BeckMapPoint(x: 784.276, y: 1972.162)
            ),
        ]

        for station in stations {
            let district = try #require(markersByID[station.districtID])
            let mildmay = try #require(markersByID[station.mildmayID])

            #expect(circleCentres(in: [district, mildmay]) == [
                station.districtPort,
                station.mildmayPort,
            ])
            #expect(connectors(in: [district, mildmay]) == [
                BeckMapLinePrimitive(
                    start: station.districtPort,
                    end: station.mildmayPort,
                    width: 7.5
                ),
            ])
            #expect(abs(
                (station.mildmayPort.x - station.districtPort.x)
                    - (station.mildmayPort.y - station.districtPort.y)
            ) < 0.002)
        }
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
