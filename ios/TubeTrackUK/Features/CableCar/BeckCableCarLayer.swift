import SwiftUI
import UIKit

enum CableCarSchematic {
    static let anchors: [String: CGPoint] = [
        "940GZZALGWP": CGPoint(x: 3210, y: 1967),
        "940GZZALRDK": CGPoint(x: 3455, y: 1822)
    ]
    static let points = [CGPoint(x: 3210, y: 1967), CGPoint(x: 3260, y: 1967),
                         CGPoint(x: 3405, y: 1822), CGPoint(x: 3455, y: 1822)]
    static let midpoint = CGPoint(x: 3332.5, y: 1894.5)

    static func path(scale: CGFloat, offset: CGSize) -> Path {
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
            let path = CableCarSchematic.path(scale: scale, offset: canvasOffset)
            let strokeScale = min(1, scale)
            context.stroke(path, with: .color(Color(.systemBackground)), style: StrokeStyle(lineWidth: 10 * strokeScale, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: (cable.hasSelection ? 7 : 6) * strokeScale, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(Color(.systemBackground)), style: StrokeStyle(lineWidth: 2 * strokeScale, lineCap: .round, lineJoin: .round))
            for terminal in cable.network.terminals {
                guard let anchor = CableCarSchematic.anchors[terminal.id] else { continue }
                let point = screen(anchor)
                let selected = cable.selectedTerminalID == terminal.id
                if selected, let rail = document.stationMarkers.first(where: { $0.stationID == terminal.railStationID }) {
                    let railPoint = screen(CGPoint(x: rail.anchor.x, y: rail.anchor.y))
                    var walk = Path(); walk.move(to: point); walk.addLine(to: railPoint)
                    context.stroke(walk, with: .color(.secondary), style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                    let walkLabel = Text("Walk").font(.system(size: 11 * min(typeScale, 1.5))).foregroundStyle(.primary)
                    context.draw(walkLabel, at: CGPoint(x: (point.x + railPoint.x) / 2, y: (point.y + railPoint.y) / 2 - 12))
                }
                let showsIcon = selected || scale >= 1.1
                let radius: CGFloat = selected ? 17 : showsIcon ? 13 : 8.5 * scale
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
            if cable.presentation.kind != .open {
                let center = screen(CableCarSchematic.midpoint)
                let text = scale >= 0.9 || cable.hasSelection ? cable.presentation.headline : cable.presentation.isClosed ? "Closed" : "Cable Car"
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
