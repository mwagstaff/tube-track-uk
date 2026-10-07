import Foundation
import MapKit
import SwiftUI

/// The optional map layer has route identities of its own. An operator's
/// corridors aren't TfL lines and don't imply bulk arrivals or train tracking.
struct NationalRailMap: Decodable, Sendable {
    struct Route: Decodable, Identifiable, Sendable {
        let id: String
        let operatorID: String
        let name: String
        let color: [Double]
        let fromStationID: String
        let toStationID: String
        let geographicPoints: [GeographicPoint]
    }

    let schemaVersion: Int
    let referenceRevision: String
    let stations: [TubeStation]
    let routes: [Route]

    static let bundled: Self = {
        do {
            guard let url = Bundle.main.url(forResource: "NationalRailMap", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard result.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
            return result
        } catch {
            assertionFailure("National Rail map could not load: \(error)")
            return Self(schemaVersion: 1, referenceRevision: "", stations: [], routes: [])
        }
    }()

    static func isExclusiveStation(_ id: String) -> Bool { id.hasPrefix("nr:") }
}

/// Immutable overlays are constructed once, never in a departure-refresh body.
@MainActor
final class NationalRailGeographicOverlays {
    static let shared = NationalRailGeographicOverlays()
    let routes: [GeographicMapContent.Route]

    private init() {
        routes = NationalRailMap.bundled.routes.flatMap { route in
            let coordinates = route.geographicPoints.map(\.coordinate)
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            let color = Color(red: route.color[0], green: route.color[1], blue: route.color[2])
            return [
                GeographicMapContent.Route(id: route.id, overlay: polyline, color: color, lineWidth: 3),
                GeographicMapContent.Route(id: route.id + ":inset", overlay: polyline,
                                           color: .white, lineWidth: 1, dash: [4, 3]),
            ]
        }
    }
}

/// Source vectors retain the combined reference's branch and limited-service
/// grammar. Semantic station records drive selection, accessibility and focus.
struct BeckMapReferenceArtwork: Codable, Hashable, Sendable {
    struct Shape: Codable, Hashable, Sendable {
        enum Role: String, Codable, Hashable, Sendable { case waterway }
        let commands: [BeckMapPathCommand]
        let fill: [Double]?
        let stroke: [Double]?
        let width: Double
        let dash: [Double]
        let evenOdd: Bool
        var role: Role? = nil
    }
    struct Label: Codable, Hashable, Sendable {
        let text: String
        let position: BeckMapPoint
        let size: Double
        let color: [Double]
    }
    struct StationLabel: Codable, Hashable, Sendable {
        let stationID: String
        let centre: BeckMapPoint
        let size: BeckMapSize
    }
    /// One target for each visible circle, including separate rail platforms
    /// and circles joined into a single compound interchange outline.
    struct StationRoundel: Codable, Hashable, Sendable {
        let stationID: String
        let centre: BeckMapPoint
        let radius: Double
        let sourceShapeIndex: Int
        var lineID: TubeLineID? = nil
        var operatorID: String? = nil
        var operatorName: String? = nil
    }
    /// The centre line and width of a visible source tick. Keeping its drawn
    /// service avoids selecting a neighbouring track at shared stations.
    struct StationTick: Codable, Hashable, Sendable {
        let stationID: String
        let centre: BeckMapPoint
        let start: BeckMapPoint
        let end: BeckMapPoint
        let width: Double
        let sourceShapeIndex: Int
        var lineID: TubeLineID? = nil
        var operatorID: String? = nil
        var operatorName: String? = nil

        func distance(to point: CGPoint) -> CGFloat {
            StationMarkerGeometry.distance(from: point, to: CGPoint(x: start.x, y: start.y), end: CGPoint(x: end.x, y: end.y))
        }
    }
    /// Sightseeing piers retained as map landmarks alongside live River Bus stops.
    struct PierSymbol: Codable, Hashable, Sendable {
        let id: String
        let name: String
        let centre: BeckMapPoint
    }
    struct PierWalkingLink: Codable, Hashable, Sendable {
        let pierID: String
        let shapes: [Shape]
    }
    let shapes: [Shape]
    let texts: [Label]
    var stationLabels: [StationLabel]? = nil
    var stationRoundels: [StationRoundel]? = nil
    var stationTicks: [StationTick]? = nil
    var riverAnchors: [RiverSchematicAnchor]? = nil
    var additionalRiverPiers: [PierSymbol]? = nil
    var riverWalkingLinks: [PierWalkingLink]? = nil
    var riverPath: [BeckMapPoint]? = nil
    var cableCarPoints: [BeckMapPoint]? = nil
    var cableCarAnchors: [String: BeckMapPoint]? = nil

    func stationID(at point: CGPoint) -> String? {
        stationLabels?.first { label in
            CGRect(x: label.centre.x - label.size.width / 2, y: label.centre.y - label.size.height / 2,
                   width: label.size.width, height: label.size.height).insetBy(dx: -2, dy: -2).contains(point)
        }?.stationID
    }

    func roundel(at point: CGPoint, minimumHitRadius: CGFloat = 0) -> StationRoundel? {
        stationRoundels?.filter {
            hypot($0.centre.x - point.x, $0.centre.y - point.y) <= max($0.radius, minimumHitRadius)
        }.min {
            hypot($0.centre.x - point.x, $0.centre.y - point.y)
                < hypot($1.centre.x - point.x, $1.centre.y - point.y)
        }
    }

    func tick(at point: CGPoint, minimumHitRadius: CGFloat = 0) -> StationTick? {
        stationTicks?.filter {
            $0.distance(to: point) <= max($0.width / 2, minimumHitRadius) + 0.001
        }.min { $0.distance(to: point) < $1.distance(to: point) }
    }
}

struct BeckMapReferenceRenderCache: Sendable {
    let shapes: [(path: Path, style: BeckMapReferenceArtwork.Shape)]
    let texts: [BeckMapReferenceArtwork.Label]

    nonisolated init(_ artwork: BeckMapReferenceArtwork) {
        shapes = artwork.shapes.map { shape in
            var path = Path()
            for command in shape.commands {
                switch command {
                case let .move(to): path.move(to: CGPoint(x: to.x, y: to.y))
                case let .line(to): path.addLine(to: CGPoint(x: to.x, y: to.y))
                case let .cubic(a, b, to):
                    path.addCurve(to: CGPoint(x: to.x, y: to.y),
                                  control1: CGPoint(x: a.x, y: a.y), control2: CGPoint(x: b.x, y: b.y))
                case .close: path.closeSubpath()
                }
            }
            return (path, shape)
        }
        texts = artwork.texts
    }

    func draw(context: inout GraphicsContext, palette: BeckMapPalette, isDark: Bool) {
        func color(_ rgb: [Double]) -> Color {
            Color(red: rgb[0], green: rgb[1], blue: rgb[2])
        }
        func fillColor(_ rgb: [Double], style: BeckMapReferenceArtwork.Shape) -> Color {
            if style.role == .waterway { return palette.waterwayFill }
            guard isDark else { return color(rgb) }
            if rgb.min()! > 0.84 {
                let isCurvedSymbol = style.commands.contains { if case .cubic = $0 { return true }; return false }
                    && style.commands.count < 24
                return isCurvedSymbol && rgb.min()! > 0.98 ? palette.paper : palette.background
            }
            if rgb.min()! > 0.65 { return color(rgb.map { $0 * 0.35 }) }
            return color(rgb)
        }
        for (path, style) in shapes {
            if let fill = style.fill {
                context.fill(path, with: .color(fillColor(fill, style: style)), style: FillStyle(eoFill: style.evenOdd))
            }
            if let stroke = style.stroke, style.width > 0 {
                context.stroke(path, with: .color(style.role == .waterway ? palette.waterwayOutline : color(stroke)), style: StrokeStyle(
                    lineWidth: style.width, lineCap: .butt, lineJoin: .round, dash: style.dash.map { CGFloat($0) }
                ))
            }
        }
        for label in texts {
            var text = context.resolve(Text(label.text).font(AppTypography.fixedBody(size: label.size, weight: .medium)))
            text.shading = .color(isDark ? (label.color.max()! < 0.4 ? palette.ink : color(label.color.map { max(0.7, $0) })) : color(label.color))
            context.draw(text, at: CGPoint(x: label.position.x, y: label.position.y), anchor: .topLeading)
        }
    }
}
