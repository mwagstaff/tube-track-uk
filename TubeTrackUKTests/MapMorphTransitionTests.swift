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

    @Test func geographicViewportPreservesCentreAndVisibleFootprint() throws {
        let graph = try TubeGraph.bundled()
        let size = CGSize(width: 393, height: 852)
        let centre = MKMapPoint(CLLocationCoordinate2D(latitude: 51.515, longitude: -0.142))
        let rect = MKMapRect(
            x: centre.x - 18_000,
            y: centre.y - 39_023,
            width: 36_000,
            height: 78_046
        )
        let viewport = SharedMapProjection.viewport(from: rect, graph: graph, size: size)
        let roundTrip = SharedMapProjection.geographicRect(for: viewport, graph: graph, size: size)

        #expect(abs(roundTrip.midX - rect.midX) < 0.001)
        #expect(abs(roundTrip.midY - rect.midY) < 0.001)
        #expect(abs(roundTrip.width - rect.width) < 1)
        #expect(abs(roundTrip.height - rect.height) < 1)
    }

    @Test func localBeckViewportProducesAReusableGeographicFootprint() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let markers = document.stationMarkers.filter {
            $0.name == "East Croydon" || $0.name == "Lebanon Road"
        }
        #expect(markers.count == 2)
        let bounds = markers.reduce(CGRect.null) { partial, marker in
            partial.union(CGRect(x: marker.anchor.x, y: marker.anchor.y, width: 1, height: 1))
        }.insetBy(dx: -80, dy: -160)
        let size = CGSize(width: 393, height: 852)

        let viewport = try #require(SharedMapProjection.viewport(
            fromArtworkRect: bounds,
            document: document,
            graph: graph,
            size: size
        ))
        let restoredArtworkRect = try #require(SharedMapProjection.artworkRect(
            for: viewport,
            document: document,
            graph: graph,
            size: size
        ))

        #expect(viewport.mapPointWidth > 1)
        #expect(viewport.mapPointHeight > viewport.mapPointWidth)
        #expect(markers.allSatisfy {
            restoredArtworkRect.insetBy(dx: -1, dy: -1).contains(CGPoint(
                x: $0.anchor.x,
                y: $0.anchor.y
            ))
        })
    }
}
