import MapKit

struct RiverMapGeometry: Sendable {
    private struct Source: Decodable { let coordinates: [GeographicPoint] }
    let centreline: [CGPoint]

    init() {
        centreline = (RiverBundle.load("RiverGeometry", as: Source.self)?.coordinates ?? []).map {
            let point = MKMapPoint($0.coordinate)
            return CGPoint(x: point.x, y: point.y)
        }
    }

    func path(from: RiverPier, to: RiverPier) -> [CGPoint] {
        let a = MKMapPoint(from.coordinate), b = MKMapPoint(to.coordinate)
        let start = CGPoint(x: a.x, y: a.y), end = CGPoint(x: b.x, y: b.y)
        guard let first = RiverPolyline.project(start, onto: centreline),
              let last = RiverPolyline.project(end, onto: centreline),
              MKMapPoint(x: first.point.x, y: first.point.y).distance(to: a) < 700,
              MKMapPoint(x: last.point.x, y: last.point.y).distance(to: b) < 700 else { return [] }
        return [start] + RiverPolyline.slice(centreline, from: first, to: last) + [end]
    }

    func coordinate(for boat: EstimatedRiverBoat, network: RiverNetwork, at date: Date) -> CLLocationCoordinate2D? {
        guard let from = network.pier(boat.previousPierId), let to = network.pier(boat.nextPierId),
              let progress = boat.progress(at: date),
              let point = RiverPolyline.point(on: path(from: from, to: to), progress: progress) else { return nil }
        return MKMapPoint(x: point.x, y: point.y).coordinate
    }

    static func schematicPath(from: RiverSchematicAnchor, to: RiverSchematicAnchor, document: BeckMapDocument) -> [CGPoint] {
        guard let waterway = document.waterways?.first(where: { $0.id == "river-thames" }),
              let path = document.paths.first(where: { $0.id == waterway.pathID }) else { return [] }
        let points: [CGPoint] = path.commands.compactMap {
            switch $0 {
            case let .move(to), let .line(to): CGPoint(x: to.x, y: to.y)
            default: nil
            }
        }
        guard let a = RiverPolyline.project(from.riverPoint, onto: points),
              let b = RiverPolyline.project(to.riverPoint, onto: points) else { return [] }
        // Cross-river services share a river anchor but have distinct banks.
        if hypot(from.x - to.x, from.y - to.y) < 1 { return [from.markerPoint, to.markerPoint] }
        return RiverPolyline.slice(points, from: a, to: b)
    }
}

enum RiverPolyline {
    struct Projection { let point: CGPoint; let segment: Int; let fraction: Double }
    static func project(_ point: CGPoint, onto points: [CGPoint]) -> Projection? {
        guard points.count > 1 else { return nil }
        var result: Projection?; var distance = Double.infinity
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1], dx = b.x - a.x, dy = b.y - a.y
            let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(0.000001, dx * dx + dy * dy)))
            let p = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < distance { distance = d; result = Projection(point: p, segment: i, fraction: t) }
        }
        return result
    }

    static func slice(_ points: [CGPoint], from a: Projection, to b: Projection) -> [CGPoint] {
        if a.segment > b.segment || (a.segment == b.segment && a.fraction > b.fraction) {
            return slice(points, from: b, to: a).reversed()
        }
        let middle = a.segment < b.segment ? Array(points[(a.segment + 1)...b.segment]) : []
        return [a.point] + middle + [b.point]
    }

    static func point(on points: [CGPoint], progress: Double) -> CGPoint? {
        RiverPreparedPath(points).point(at: progress)
    }
}

/// Prepare immutable route distances once, then interpolate without allocating
/// or projecting the Thames centreline on each live tick and hit test.
struct RiverPreparedPath {
    let points: [CGPoint]
    private let lengths: [Double]
    private let total: Double

    init(_ points: [CGPoint]) {
        self.points = points
        lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        total = lengths.reduce(0, +)
    }

    func point(at progress: Double) -> CGPoint? {
        guard let first = points.first, let last = points.last else { return nil }
        guard total > 0 else { return first }
        var remaining = total * min(1, max(0, progress))
        for i in lengths.indices {
            if remaining <= lengths[i], lengths[i] > 0 {
                let t = remaining / lengths[i]
                return CGPoint(x: points[i].x + (points[i + 1].x - points[i].x) * t,
                               y: points[i].y + (points[i + 1].y - points[i].y) * t)
            }
            remaining -= lengths[i]
        }
        return last
    }
}

/// Finite pier-pair cache, independent of vehicle IDs and polling timestamps.
/// Source changes explicitly invalidate it; it never caches progress or freshness.
struct RiverBoatPathCache {
    struct Key: Hashable { let from: String; let to: String }
    private var paths: [Key: RiverPreparedPath] = [:]

    mutating func path(from: String, to: String, build: () -> [CGPoint]) -> RiverPreparedPath {
        let key = Key(from: from, to: to)
        if let path = paths[key] { return path }
        if paths.count >= 128 { paths.removeAll(keepingCapacity: true) }
        let path = RiverPreparedPath(build())
        paths[key] = path
        return path
    }
}
