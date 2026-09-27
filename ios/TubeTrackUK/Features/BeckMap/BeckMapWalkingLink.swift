import SwiftUI

/// A TfL walking interchange drawn by an overlay layer: square black dots
/// between two symbols, stopping at each symbol's edge as on the TfL map.
enum BeckMapWalkingLink {
    /// The document's walking-link width in artwork units.
    static func width(in document: BeckMapDocument) -> Double {
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
        width: CGFloat,
        color: Color,
        in context: inout GraphicsContext
    ) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > startRadius + endRadius + width else { return }
        let unit = CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
        var path = Path()
        path.move(to: CGPoint(x: start.x + unit.x * startRadius, y: start.y + unit.y * startRadius))
        path.addLine(to: CGPoint(x: end.x - unit.x * endRadius, y: end.y - unit.y * endRadius))
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: [width, width / 2])
        )
    }
}
