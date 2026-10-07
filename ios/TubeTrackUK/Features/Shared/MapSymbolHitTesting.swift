import Foundation

/// Actual symbols are tested before labels, routes or padded touch areas.
/// Shared by the schematic and geographic maps so overlapping transport
/// layers cannot replace a station, pier or terminal with a nearby feature.
enum MapSymbolHitTesting {
    struct Target {
        let id: String
        let point: CGPoint
        let radius: CGFloat
    }

    static func nearestID(at point: CGPoint, targets: [Target]) -> String? {
        targets.filter {
            hypot($0.point.x-point.x, $0.point.y-point.y) <= $0.radius
        }.min {
            hypot($0.point.x-point.x, $0.point.y-point.y)
                < hypot($1.point.x-point.x, $1.point.y-point.y)
        }?.id
    }
}
