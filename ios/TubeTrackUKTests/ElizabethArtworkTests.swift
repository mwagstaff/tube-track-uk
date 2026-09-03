import Testing
@testable import TubeTrackUK

struct ElizabethArtworkTests {
    @Test func hayesAndHarlingtonUsesOneSharedRoundel() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let stationID = "910GHAYESAH"
        let marker = try #require(document.stationMarkers.first {
            $0.stationID == stationID
        })

        #expect(marker.anchor == BeckMapPoint(x: 339.843, y: 1657.188))
        #expect(marker.primitives == [
            .circle(.init(
                centre: marker.anchor,
                radius: 8.5,
                outlineWidth: 3.5
            )),
        ])

        let stationPorts = document.segments.compactMap { segment -> BeckMapPoint? in
            guard segment.lineID == .elizabeth else { return nil }
            if segment.fromStationID == stationID { return segment.fromPort }
            if segment.toStationID == stationID { return segment.toPort }
            return nil
        }
        #expect(stationPorts.count == 3)
        #expect(stationPorts.allSatisfy { $0 == marker.anchor })
    }
}
