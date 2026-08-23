import CoreGraphics
import MapKit

enum MapPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case beck
    case realWorld

    var id: Self { self }

    var title: String {
        switch self {
        case .beck: "Tube map"
        case .realWorld: "Real world"
        }
    }

    var symbol: String {
        switch self {
        case .beck: "map.fill"
        case .realWorld: "globe.europe.africa.fill"
        }
    }

    var toggled: Self {
        self == .beck ? .realWorld : .beck
    }
}

struct SharedMapViewport: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// A renderer-independent multiplier where 1 fits the whole network.
    var zoom: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(coordinate: CLLocationCoordinate2D, zoom: Double) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.zoom = max(0.2, min(24, zoom))
    }
}

struct BeckMapCameraSnapshot: Equatable, Sendable {
    let scale: Double
    let offsetX: Double
    let offsetY: Double
    let viewportWidth: Double
    let viewportHeight: Double

    func screenPoint(for artworkPoint: CGPoint, in size: CGSize) -> CGPoint {
        let xScale = size.width / max(1, viewportWidth)
        let yScale = size.height / max(1, viewportHeight)
        return CGPoint(
            x: (artworkPoint.x * scale + offsetX) * xScale,
            y: (artworkPoint.y * scale + offsetY) * yScale
        )
    }
}

enum SharedMapProjection {
    static func geographicBounds(for graph: TubeGraph) -> MKMapRect {
        let points = graph.stations.map { MKMapPoint($0.coordinate) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            return MKMapRect.world
        }
        let width = max(1, maxX - minX)
        let height = max(1, maxY - minY)
        return MKMapRect(
            x: minX - width * 0.08,
            y: minY - height * 0.08,
            width: width * 1.16,
            height: height * 1.16
        )
    }

    static func fittedGeographicRect(for graph: TubeGraph, size: CGSize) -> MKMapRect {
        let bounds = geographicBounds(for: graph)
        let aspect = max(0.1, Double(size.width / max(1, size.height)))
        let boundsAspect = bounds.width / max(1, bounds.height)
        if boundsAspect > aspect {
            let height = bounds.width / aspect
            return MKMapRect(
                x: bounds.minX,
                y: bounds.midY - height / 2,
                width: bounds.width,
                height: height
            )
        }
        let width = bounds.height * aspect
        return MKMapRect(
            x: bounds.midX - width / 2,
            y: bounds.minY,
            width: width,
            height: bounds.height
        )
    }

    static func geographicRect(
        for viewport: SharedMapViewport,
        graph: TubeGraph,
        size: CGSize
    ) -> MKMapRect {
        let fitted = fittedGeographicRect(for: graph, size: size)
        let centre = MKMapPoint(viewport.coordinate)
        let zoom = max(0.2, viewport.zoom)
        return MKMapRect(
            x: centre.x - fitted.width / zoom / 2,
            y: centre.y - fitted.height / zoom / 2,
            width: fitted.width / zoom,
            height: fitted.height / zoom
        )
    }

    static func viewport(
        from rect: MKMapRect,
        graph: TubeGraph,
        size: CGSize
    ) -> SharedMapViewport {
        let fitted = fittedGeographicRect(for: graph, size: size)
        let zoom = min(
            fitted.width / max(1, rect.width),
            fitted.height / max(1, rect.height)
        )
        return SharedMapViewport(
            coordinate: MKMapPoint(x: rect.midX, y: rect.midY).coordinate,
            zoom: zoom
        )
    }

    static func screenPoint(
        for coordinate: CLLocationCoordinate2D,
        in rect: MKMapRect,
        size: CGSize
    ) -> CGPoint {
        let point = MKMapPoint(coordinate)
        return CGPoint(
            x: (point.x - rect.minX) / max(1, rect.width) * size.width,
            y: (point.y - rect.minY) / max(1, rect.height) * size.height
        )
    }

    static func artworkPoint(
        for coordinate: CLLocationCoordinate2D,
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> CGPoint? {
        let stations = pairedStations(document: document, graph: graph)
        let query = MKMapPoint(coordinate)
        return weightedValue(
            query: CGPoint(x: query.x, y: query.y),
            candidates: stations.map {
                (
                    source: CGPoint(x: $0.mapPoint.x, y: $0.mapPoint.y),
                    target: $0.artworkPoint
                )
            }
        )
    }

    static func coordinate(
        for artworkPoint: CGPoint,
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> CLLocationCoordinate2D? {
        let stations = pairedStations(document: document, graph: graph)
        guard let point = weightedValue(
            query: artworkPoint,
            candidates: stations.map {
                (
                    source: $0.artworkPoint,
                    target: CGPoint(x: $0.mapPoint.x, y: $0.mapPoint.y)
                )
            }
        ) else { return nil }
        return MKMapPoint(x: point.x, y: point.y).coordinate
    }

    private static func pairedStations(
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> [(artworkPoint: CGPoint, mapPoint: MKMapPoint)] {
        let stations = graph.stationsByID
        return document.stationMarkers.compactMap { marker -> (artworkPoint: CGPoint, mapPoint: MKMapPoint)? in
            guard let station = stations[marker.stationID] else { return nil }
            return (
                CGPoint(x: marker.anchor.x, y: marker.anchor.y),
                MKMapPoint(station.coordinate)
            )
        }
    }

    /// Smoothly maps between two differently distorted layouts by blending
    /// the four nearest authored station anchors. Exact station centres remain exact.
    private static func weightedValue(
        query: CGPoint,
        candidates: [(source: CGPoint, target: CGPoint)]
    ) -> CGPoint? {
        let nearest = candidates
            .map { candidate in
                (
                    candidate: candidate,
                    distance: hypot(candidate.source.x - query.x, candidate.source.y - query.y)
                )
            }
            .sorted { $0.distance < $1.distance }
            .prefix(4)
        guard let first = nearest.first else { return nil }
        if first.distance < 0.001 { return first.candidate.target }

        var totalWeight: CGFloat = 0
        var targetX: CGFloat = 0
        var targetY: CGFloat = 0
        for item in nearest {
            let weight = 1 / max(0.001, item.distance * item.distance)
            totalWeight += weight
            targetX += item.candidate.target.x * weight
            targetY += item.candidate.target.y * weight
        }
        guard totalWeight > 0 else { return nil }
        return CGPoint(x: targetX / totalWeight, y: targetY / totalWeight)
    }
}
