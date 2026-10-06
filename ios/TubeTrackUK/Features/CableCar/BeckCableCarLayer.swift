import SwiftUI
import UIKit

/// The cable car as drawn on the September 2026 TfL map: terminal symbols
/// east of North Greenwich and south-east of Royal Victoria, joined by a
/// horizontal, diagonal, horizontal route.
enum CableCarSchematic {
    static let anchors: [String: CGPoint] = [
        "940GZZALGWP": CGPoint(x: 3243.3, y: 1948.73),
        "940GZZALRDK": CGPoint(x: 3490.34, y: 1793.45)
    ]
    static let points = [CGPoint(x: 3243.3, y: 1949.2), CGPoint(x: 3267.1, y: 1949.2),
                         CGPoint(x: 3431.2, y: 1792.0), CGPoint(x: 3490.3, y: 1792.0)]
    static let midpoint = CGPoint(x: 3349.2, y: 1870.6)

    static func anchors(in document: BeckMapDocument) -> [String: CGPoint] {
        document.referenceArtwork?.cableCarAnchors?.mapValues { CGPoint(x: $0.x, y: $0.y) } ?? anchors
    }

    static func points(in document: BeckMapDocument) -> [CGPoint] {
        document.referenceArtwork?.cableCarPoints?.map { CGPoint(x: $0.x, y: $0.y) } ?? points
    }

    static func midpoint(in document: BeckMapDocument) -> CGPoint {
        RiverPolyline.point(on: points(in: document), progress: 0.5) ?? midpoint
    }

    static func path(scale: CGFloat, offset: CGSize, points: [CGPoint] = points) -> Path {
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.width, y: p.y * scale + offset.height) }
        var path = Path(); path.move(to: screen(points[0]))
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1], point = points[index], next = points[index + 1]
            let before = hypot(point.x - previous.x, point.y - previous.y)
            let after = hypot(next.x - point.x, next.y - point.y)
            let a = CGPoint(x: point.x - (point.x - previous.x) / before * 9, y: point.y - (point.y - previous.y) / before * 9)
            let b = CGPoint(x: point.x + (next.x - point.x) / after * 9, y: point.y + (next.y - point.y) / after * 9)
            path.addLine(to: screen(a)); path.addQuadCurve(to: screen(b), control: screen(point))
        }
        path.addLine(to: screen(points.last!)); return path
    }
}

struct BeckCableCarLayer: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let document: BeckMapDocument
    let camera: BeckMapLayerCamera
    let scale: CGFloat
    let offset: CGSize
    let overscan: CGFloat
    let canvasSize: CGSize
    let typeScale: CGFloat

    var body: some View {
        let cable = appState.cableCar
        let canvasOffset = CGSize(width: offset.width + overscan, height: offset.height + overscan)
        let key = "cable:\(scale):\(offset):\(canvasSize):\(typeScale):\(colorScheme):\(cable.presentation):\(cable.selectedTerminalID ?? ""):\(cable.hasSelection):\(cable.network.terminals)"
        BeckMapRetainedCanvas(key: key, camera: camera, renderScale: scale, renderOffset: offset,
            overscan: overscan, canvasSize: canvasSize, colorScheme: colorScheme) { context, _ in
            let tint = cable.presentation.routeTint
            func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + canvasOffset.width, y: p.y * scale + canvasOffset.height) }
            let path = CableCarSchematic.path(scale: scale, offset: canvasOffset, points: CableCarSchematic.points(in: document))
            let strokeScale = min(1, scale)
            context.stroke(path, with: .color(Color(.systemBackground)), style: StrokeStyle(lineWidth: 10 * strokeScale, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: (cable.hasSelection ? 7 : 6) * strokeScale, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(Color(.systemBackground)), style: StrokeStyle(lineWidth: 2 * strokeScale, lineCap: .round, lineJoin: .round))
            let palette = BeckMapPalette.resolve(for: colorScheme)
            let walkWidth = CGFloat(BeckMapWalkingLink.width(in: document)) * scale
            for terminal in cable.network.terminals {
                guard let anchor = CableCarSchematic.anchors(in: document)[terminal.id] else { continue }
                let point = screen(anchor)
                let selected = cable.selectedTerminalID == terminal.id
                let showsIcon = selected || scale >= 1.1
                let radius: CGFloat = selected ? 17 : showsIcon ? 13 : 8.5 * scale
                // TfL shows each terminal's walking interchange with a dotted link.
                if let stationID = terminal.railStationID,
                   let rail = BeckMapWalkingLink.roundel(of: stationID, nearest: anchor, in: document) {
                    let railPoint = screen(rail.centre)
                    BeckMapWalkingLink.draw(
                        from: point, startRadius: radius, to: railPoint, endRadius: rail.outerRadius * scale,
                        width: walkWidth, color: palette.stationOutline, in: &context
                    )
                    if selected {
                        let walkLabel = Text("Walk").font(.system(size: 11 * min(typeScale, 1.5))).foregroundStyle(.primary)
                        context.draw(walkLabel, at: CGPoint(x: (point.x + railPoint.x) / 2, y: (point.y + railPoint.y) / 2 - 12))
                    }
                }
                let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                context.fill(circle, with: .color(selected ? .red : Color(.systemBackground)))
                context.stroke(circle, with: .color(.red), lineWidth: showsIcon ? 2 : 3.5 * scale)
                if showsIcon {
                    let glyph = CableCarGlyph().path(in: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
                    context.fill(glyph, with: .color(selected ? Color(.systemBackground) : .red), style: FillStyle(eoFill: true))
                }
                if scale >= 0.9 || selected || cable.hasSelection {
                    let name = terminal.name.replacingOccurrences(of: "Greenwich Peninsula", with: "Greenwich\nPeninsula")
                    let label = context.resolve(Text(name).font(.system(size: 12 * min(typeScale, 1.6), weight: .semibold)).foregroundStyle(.primary))
                    let size = label.measure(in: CGSize(width: 170, height: 90))
                    // Keep Greenwich Peninsula clear of the existing North Greenwich label.
                    let labelX = terminal.id == "940GZZALGWP" ? point.x + 20 : point.x - size.width / 2 - 4
                    let frame = CGRect(x: labelX, y: point.y + 19, width: size.width + 8, height: size.height + 4)
                    context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(Color(.systemBackground).opacity(0.96)))
                    context.draw(label, in: frame.insetBy(dx: 4, dy: 2))
                }
            }
            if cable.presentation.kind != .open && !cable.presentation.isClosed {
                let center = screen(CableCarSchematic.midpoint(in: document))
                let text = scale >= 0.9 || cable.hasSelection ? cable.presentation.headline : "Cable Car"
                let label = context.resolve(Text(text).font(.system(size: 11 * min(typeScale, 1.5), weight: .semibold)).foregroundStyle(.primary))
                let size = label.measure(in: CGSize(width: 200, height: 70))
                let frame = CGRect(x: center.x - size.width / 2 - 7, y: center.y - size.height - 13, width: size.width + 14, height: size.height + 8)
                context.fill(Path(roundedRect: frame, cornerRadius: 8), with: .color(Color(.systemBackground)))
                context.stroke(Path(roundedRect: frame, cornerRadius: 8), with: .color(tint.opacity(0.5)), lineWidth: 1)
                context.draw(label, in: frame.insetBy(dx: 7, dy: 4))
            }
        }.allowsHitTesting(false)
    }
}
