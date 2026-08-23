import CoreLocation
import MapKit
import Testing
@testable import TubeTrackUK

struct MapMorphTransitionTests {
    @Test func morphGeometryCoversAuthoredNetworkWithPairedSamples() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let geometry = MapMorphGeometry(document: document, graph: graph)

        #expect(geometry.segments.count >= document.segments.count - 2)
        #expect(geometry.segments.allSatisfy { segment in
            segment.beckPoints.count >= 12
                && segment.beckPoints.count == segment.geographicCoordinates.count
        })
    }

    @Test func authoredStationAnchorsRoundTripExactlyBetweenLayouts() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let marker = try #require(document.stationMarkers.first)
        let station = try #require(graph.stationsByID[marker.stationID])

        let artworkPoint = try #require(SharedMapProjection.artworkPoint(
            for: station.coordinate,
            document: document,
            graph: graph
        ))
        #expect(abs(artworkPoint.x - marker.anchor.x) < 0.001)
        #expect(abs(artworkPoint.y - marker.anchor.y) < 0.001)

        let coordinate = try #require(SharedMapProjection.coordinate(
            for: artworkPoint,
            document: document,
            graph: graph
        ))
        #expect(abs(coordinate.latitude - station.latitude) < 0.000_001)
        #expect(abs(coordinate.longitude - station.longitude) < 0.000_001)
    }

    @Test func geographicViewportPreservesCentreAndNormalizedZoom() throws {
        let graph = try TubeGraph.bundled()
        let size = CGSize(width: 393, height: 852)
        let viewport = SharedMapViewport(
            coordinate: CLLocationCoordinate2D(latitude: 51.515, longitude: -0.142),
            zoom: 3.4
        )
        let rect = SharedMapProjection.geographicRect(for: viewport, graph: graph, size: size)
        let roundTrip = SharedMapProjection.viewport(from: rect, graph: graph, size: size)

        #expect(abs(roundTrip.latitude - viewport.latitude) < 0.000_001)
        #expect(abs(roundTrip.longitude - viewport.longitude) < 0.000_001)
        #expect(abs(roundTrip.zoom - viewport.zoom) < 0.000_001)
    }
}
