import Foundation
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
                BeckMapPoint(x: 572.734, y: 2145.43),
                BeckMapPoint(x: 591.852, y: 2164.648)
            ),
            (
                "940GZZLUKWG",
                "910GKEWGRDN",
                BeckMapPoint(x: 644.523, y: 2073.633),
                BeckMapPoint(x: 663.789, y: 2093.18)
            ),
            (
                "940GZZLUGBY",
                "910GGNRSBRY",
                BeckMapPoint(x: 745.969, y: 1974.828),
                BeckMapPoint(x: 764.016, y: 1992.859)
            ),
        ]

        for station in stations {
            let district = try #require(markersByID[station.districtID])
            let mildmay = try #require(markersByID[station.mildmayID])

            #expect(circleCentres(in: [district, mildmay]) == [
                station.districtPort,
                station.mildmayPort,
            ])
            // One 45-degree bar between the two TfL roundels.
            let bars = connectors(in: [district, mildmay])
            #expect(bars.count == 1)
            for bar in bars {
                #expect(hypot(bar.start.x - station.districtPort.x, bar.start.y - station.districtPort.y) < 0.5)
                #expect(hypot(bar.end.x - station.mildmayPort.x, bar.end.y - station.mildmayPort.y) < 0.5)
                #expect(abs((bar.end.x - bar.start.x) - (bar.end.y - bar.start.y)) < 0.002)
                #expect(bar.width == 12.4)
            }
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
