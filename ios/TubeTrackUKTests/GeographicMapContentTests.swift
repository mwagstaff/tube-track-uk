import MapKit
import SwiftUI
import Testing
@testable import TubeTrackUK

@MainActor
struct GeographicMapContentTests {
    @Test func cachedDisplayStationsMatchTheGroupedGraph() throws {
        let graph = try TubeGraph.bundled()
        let data = RealWorldMapRenderData(graph: graph)
        // Unselected, a DLR platform inside a hub, and a tram stop.
        for selectedStationID in [nil, "940GZZDLBNK", "940GZZCRWMB", "940GZZLUSWF"] {
            let cached = data.displayStations(selectedStationID: selectedStationID).map(\.id)
            let grouped = RealWorldStationDisplay.stations(
                in: graph,
                selectedStationID: selectedStationID
            ).map(\.id)
            #expect(cached == grouped)
        }
    }

    @Test func annotationLevelOnlyChangesAtStylingThresholds() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.15)
        )
        // Within one band, zoom jitter must not produce a content update.
        #expect(GeographicAnnotationLevel(zoom: 2.1, region: region)
            == GeographicAnnotationLevel(zoom: 2.9, region: region))
        #expect(GeographicAnnotationLevel(zoom: 6.3, region: region)
            == GeographicAnnotationLevel(zoom: 9, region: region))

        let overview = GeographicAnnotationLevel(zoom: 1, region: region)
        #expect(!overview.showsRoundels && !overview.showsNames && !overview.showsFeatureNames)
        #expect(overview.markerDiameter == 5)

        let roundels = GeographicAnnotationLevel(zoom: RealWorldStationVisibilityPolicy.roundelMinimumZoom, region: region)
        #expect(roundels.showsRoundels && !roundels.showsNames)
        #expect(roundels.markerDiameter == 11)

        let names = GeographicAnnotationLevel(zoom: RealWorldStationVisibilityPolicy.nameMinimumZoom, region: region)
        #expect(names.showsRoundels && names.showsNames && names.showsFeatureNames)

        let narrow = MKCoordinateRegion(center: region.center, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.1))
        #expect(!GeographicAnnotationLevel(zoom: 6, region: region).showsAllPiers)
        #expect(GeographicAnnotationLevel(zoom: 6, region: narrow).showsAllPiers)
    }

    @Test func installedStationSetIncludesBothEndsOfALongPan() throws {
        let graph = try TubeGraph.bundled()
        let data = RealWorldMapRenderData(graph: graph)
        let stations = data.displayStations(selectedStationID: nil)
        let western = try #require(stations.min { $0.longitude < $1.longitude })
        let eastern = try #require(stations.max { $0.longitude < $1.longitude })
        #expect(eastern.longitude - western.longitude > 0.5)
        // Both ends stay installed; MapKit controls onscreen visibility rather
        // than replacing the Map content when a viewport crosses a boundary.
        let installedIDs = Set(stations.map(\.id))
        #expect(installedIDs.contains(western.id))
        #expect(installedIDs.contains(eastern.id))
        #expect(stations.count <= graph.stations.count)
    }

    @Test func contentEqualityUsesOverlayIdentityAndStyle() throws {
        let graph = try TubeGraph.bundled()
        let data = RealWorldMapRenderData(graph: graph)
        let polyline = try #require(data.polylines.first)
        let route = GeographicMapContent.Route(
            id: "route:\(polyline.id)", overlay: polyline.overlay, color: .red, lineWidth: 4
        )
        var content = GeographicMapContent()
        content.routes = [route]
        var same = GeographicMapContent()
        same.routes = [route]
        #expect(content == same)

        // A rebuilt render-data cache owns different overlay objects.
        let replacement = try #require(RealWorldMapRenderData(graph: graph).polylines.first)
        same.routes = [.init(id: route.id, overlay: replacement.overlay, color: .red, lineWidth: 4)]
        #expect(content != same)

        same.routes = [.init(id: route.id, overlay: polyline.overlay, color: .blue, lineWidth: 4)]
        #expect(content != same)
    }
}
