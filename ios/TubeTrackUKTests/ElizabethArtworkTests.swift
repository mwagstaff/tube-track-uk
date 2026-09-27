import Foundation
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

        // TfL's roundel sits just above the shared Elizabeth line port.
        #expect(marker.anchor == BeckMapPoint(x: 336.289, y: 1657.086))
        #expect(marker.primitives == [
            .circle(.init(
                centre: marker.anchor,
                radius: 10.36,
                outlineWidth: 4.14
            )),
        ])

        let stationPorts = document.segments.compactMap { segment -> BeckMapPoint? in
            guard segment.lineID == .elizabeth else { return nil }
            if segment.fromStationID == stationID { return segment.fromPort }
            if segment.toStationID == stationID { return segment.toPort }
            return nil
        }
        #expect(stationPorts.count == 3)
        #expect(Set(stationPorts).count == 1)
        #expect(stationPorts.allSatisfy {
            hypot($0.x - marker.anchor.x, $0.y - marker.anchor.y) < 0.5
        })
    }
}
