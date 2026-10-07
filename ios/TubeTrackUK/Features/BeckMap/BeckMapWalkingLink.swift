import SwiftUI

/// A TfL walking interchange drawn by an overlay layer: square black dots
/// between two symbols, stopping at each symbol's edge as on the TfL map.
enum BeckMapWalkingLink {
    /// The document's walking-link width in artwork units.
    static func width(in document: BeckMapDocument) -> Double {
        if document.referenceArtwork != nil { return 2.952 }
        for marker in document.stationMarkers {
            for primitive in marker.primitives {
                if case let .walkingConnector(connector) = primitive { return connector.width }
            }
        }
        return 5.3
    }

    /// The roundel of `stationID` nearest to `point`, with its outer radius,
    /// in artwork units.
    static func roundel(
        of stationID: String,
        nearest point: CGPoint,
        in document: BeckMapDocument
    ) -> (centre: CGPoint, outerRadius: CGFloat)? {
        guard let marker = document.stationMarkers.first(where: { $0.stationID == stationID }) else { return nil }
        let circles: [(CGPoint, CGFloat)] = marker.primitives.compactMap {
            guard case let .circle(circle) = $0 else { return nil }
            return (CGPoint(x: circle.centre.x, y: circle.centre.y), CGFloat(circle.radius + circle.outlineWidth / 2))
        }
        if let nearest = circles.min(by: { hypot($0.0.x - point.x, $0.0.y - point.y) < hypot($1.0.x - point.x, $1.0.y - point.y) }) {
            return (nearest.0, nearest.1)
        }
        return (CGPoint(x: marker.anchor.x, y: marker.anchor.y), 0)
    }

    /// Strokes the link between two screen points, trimmed by each symbol's
    /// on-screen radius. `width` is the on-screen dot size.
    static func draw(
        from start: CGPoint,
        startRadius: CGFloat,
        to end: CGPoint,
        endRadius: CGFloat,
        via: [CGPoint] = [],
        width: CGFloat,
        color: Color,
        in context: inout GraphicsContext
    ) {
        guard let path = path(from: start, startRadius: startRadius, to: end,
                              endRadius: endRadius, via: via, minimumLength: width) else { return }
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: [width, width / 2])
        )
    }

    /// Trim the first and last legs at their roundels while preserving bends.
    static func path(from start: CGPoint, startRadius: CGFloat, to end: CGPoint,
                     endRadius: CGFloat, via: [CGPoint] = [], minimumLength: CGFloat = 0) -> Path? {
        var points = [start] + via + [end]
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        guard let first = lengths.first, let last = lengths.last,
              first > startRadius, last > endRadius,
              lengths.reduce(0, +) > startRadius + endRadius + minimumLength else { return nil }
        let beforeEnd = points[points.count - 2]
        points[0] = CGPoint(x: start.x + (points[1].x - start.x) / first * startRadius,
                            y: start.y + (points[1].y - start.y) / first * startRadius)
        points[points.count - 1] = CGPoint(x: end.x - (end.x - beforeEnd.x) / last * endRadius,
                                         y: end.y - (end.y - beforeEnd.y) / last * endRadius)
        var result = Path()
        result.move(to: points[0])
        points.dropFirst().forEach { result.addLine(to: $0) }
        return result
    }
}
