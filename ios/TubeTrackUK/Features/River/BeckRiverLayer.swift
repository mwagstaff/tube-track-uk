import SwiftUI
import UIKit

struct RiverPierPlacement {
    let pier: RiverPier
    let point: CGPoint
    let riverPoint: CGPoint
    let labelFrame: CGRect?
}

enum RiverSchematicLayout {
    static func placements(network: RiverNetwork, anchors: [RiverSchematicAnchor], selected: String?, lineId: String?,
                           scale: CGFloat, offset: CGSize, viewport: CGSize, typeScale: CGFloat,
                           blocked: [CGRect]) -> [RiverPierPlacement] {
        let bounds = CGRect(origin: .zero, size: viewport)
        var occupied = blocked
        var markers: [CGRect] = []
        var result: [RiverPierPlacement] = []
        let ordered = anchors.sorted {
            if ($0.id == selected) != ($1.id == selected) { return $0.id == selected }
            if $0.major != $1.major { return $0.major }
            return $0.id < $1.id
        }
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.width, y: p.y * scale + offset.height) }
        for anchor in ordered {
            guard let pier = network.pier(anchor.id),
                  lineId == nil || pier.lineIds.contains(lineId!) || pier.id == selected,
                  anchor.major || scale >= 0.55 || pier.id == selected else { continue }
            let point = screen(anchor.markerPoint)
            let hit = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            guard bounds.intersects(hit), !markers.contains(where: { $0.intersects(hit) }) || pier.id == selected else { continue }
            markers.append(hit)
            var labelFrame: CGRect?
            if scale >= 1.1 || pier.id == selected {
                let font = UIFont.systemFont(ofSize: 12 * min(1.6, typeScale), weight: .semibold)
                let rect = (pier.name as NSString).boundingRect(with: CGSize(width: 190, height: 80), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
                let width = ceil(rect.width) + 12, height = ceil(rect.height) + 8
                let candidates = [
                    CGRect(x: point.x + 19, y: point.y - height / 2, width: width, height: height),
                    CGRect(x: point.x - width - 19, y: point.y - height / 2, width: width, height: height),
                    CGRect(x: point.x - width / 2, y: point.y + 20, width: width, height: height),
                    CGRect(x: point.x - width / 2, y: point.y - height - 20, width: width, height: height)
                ]
                let preferred = anchor.labelSide < 0 ? [candidates[1], candidates[3], candidates[0], candidates[2]] : candidates
                labelFrame = preferred.first { frame in
                    bounds.contains(frame) && !occupied.contains(where: { $0.intersects(frame) })
                        && !markers.dropLast().contains(where: { $0.intersects(frame) })
                }
                if let labelFrame { occupied.append(labelFrame.insetBy(dx: -4, dy: -4)) }
            }
            result.append(RiverPierPlacement(pier: pier, point: point, riverPoint: screen(anchor.riverPoint), labelFrame: labelFrame))
        }
        return result
    }
}

/// Retains the static pier layer separately from the ticking vessel layer.
struct BeckRiverLayer: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let document: BeckMapDocument
    let camera: BeckMapLayerCamera
    let scale: CGFloat
    let offset: CGSize
    let overscan: CGFloat
    let canvasSize: CGSize
    let typeScale: CGFloat
    let blocked: [CGRect]

    var body: some View {
        let river = appState.river
        let canvasOffset = CGSize(width: offset.width + overscan, height: offset.height + overscan)
        let placements = RiverSchematicLayout.placements(network: river.network, anchors: river.anchors,
            selected: river.selectedPierId, lineId: river.selectedLineId, scale: scale, offset: canvasOffset,
            viewport: canvasSize, typeScale: typeScale, blocked: blocked)
        let key = "\(scale):\(offset):\(canvasSize):\(typeScale):\(colorScheme):\(river.selectedPierId ?? ""):\(river.selectedLineId ?? ""):\(placements.map { $0.pier.name }.joined())"
        BeckMapRetainedCanvas(key: key, camera: camera, renderScale: scale, renderOffset: offset,
            overscan: overscan, canvasSize: canvasSize, colorScheme: colorScheme) { context, _ in
            if let lineId = river.selectedLineId {
                var seen = Set<String>()
                for route in river.network.routes where route.lineId == lineId {
                    for (a, b) in zip(route.stopIds, route.stopIds.dropFirst()) {
                        let id = [a, b].sorted().joined(separator: ":")
                        guard seen.insert(id).inserted,
                              let from = river.anchors.first(where: { $0.id == a }),
                              let to = river.anchors.first(where: { $0.id == b }) else { continue }
                        let points = RiverMapGeometry.schematicPath(from: from, to: to, document: document)
                            .map { CGPoint(x: $0.x * scale + canvasOffset.width, y: $0.y * scale + canvasOffset.height) }
                        guard let first = points.first else { continue }
                        var path = Path(); path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }
                        context.stroke(path, with: .color(.blue.opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }
            }
            for item in placements {
                let selected = item.pier.id == river.selectedPierId
                var leader = Path(); leader.move(to: item.riverPoint); leader.addLine(to: item.point)
                context.stroke(leader, with: .color(.blue.opacity(0.7)), lineWidth: 1)
                let showsIcon = selected || scale >= 1.1
                let r: CGFloat = selected ? 16 : showsIcon ? 12 : 8.5 * scale
                let circle = Path(ellipseIn: CGRect(x: item.point.x - r, y: item.point.y - r, width: r * 2, height: r * 2))
                context.fill(circle, with: .color(selected ? .blue : Color(.systemBackground)))
                context.stroke(circle, with: .color(.blue), lineWidth: selected ? 2.5 : showsIcon ? 1.5 : 3.5 * scale)
                if showsIcon {
                    var icon = context.resolve(Image(systemName: "ferry.fill"))
                    icon.shading = .color(selected ? .white : .blue)
                    context.draw(icon, in: CGRect(x: item.point.x - 8, y: item.point.y - 8, width: 16, height: 16))
                }
                if let frame = item.labelFrame {
                    context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(Color(.systemBackground).opacity(0.94)))
                    let label = context.resolve(Text(item.pier.name).font(.system(size: 12 * min(1.6, typeScale), weight: .semibold)).foregroundStyle(.primary))
                    context.draw(label, in: frame.insetBy(dx: 6, dy: 4))
                }
            }
        }
        .allowsHitTesting(false)
        if river.showsBoats, !appState.isOffline,
           appState.selectedTab == .map, appState.mapPresentationMode == .beck {
            BeckRiverBoatLayer(document: document, camera: camera, scale: scale, offset: offset,
                               overscan: overscan, canvasSize: canvasSize)
        }
    }
}

private struct BeckRiverBoatLayer: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let document: BeckMapDocument
    let camera: BeckMapLayerCamera
    let scale: CGFloat
    let offset: CGSize
    let overscan: CGFloat
    let canvasSize: CGSize
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 30 : 1)) { timeline in
            let boats = appState.river.filteredBoats
            let key = "\(boats.hashValue):\(Int(timeline.date.timeIntervalSince1970)):\(scale):\(offset):\(canvasSize):\(colorScheme)"
            BeckMapRetainedCanvas(key: key, camera: camera, renderScale: scale, renderOffset: offset,
                overscan: overscan, canvasSize: canvasSize, colorScheme: colorScheme) { context, size in
                var icon = context.resolve(Image(systemName: "ferry.fill"))
                icon.shading = .color(.blue)
                let visibleBounds = CGRect(origin: .zero, size: size).insetBy(dx: -12, dy: -12)
                for boat in boats {
                    guard let point = appState.river.schematicPoint(for: boat, document: document, at: timeline.date) else { continue }
                    let screen = CGPoint(x: point.x * scale + offset.width + overscan, y: point.y * scale + offset.height + overscan)
                    guard visibleBounds.contains(screen) else { continue }
                    context.draw(icon, in: CGRect(x: screen.x - 12, y: screen.y - 12, width: 24, height: 24))
                }
            }
        }.allowsHitTesting(false)
    }
}

extension RiverBusState {
    func schematicPoint(for boat: EstimatedRiverBoat, document: BeckMapDocument, at date: Date) -> CGPoint? {
        guard let progress = boat.progress(at: date),
              let from = anchors.first(where: { $0.id == boat.previousPierId }),
              let to = anchors.first(where: { $0.id == boat.nextPierId }) else { return nil }
        let documentKey = document.identifier + ":" + document.source.graphGeneratedAt
        if schematicBoatDocumentKey != documentKey {
            schematicBoatPaths = RiverBoatPathCache()
            schematicBoatDocumentKey = documentKey
        }
        return schematicBoatPaths.path(from: from.id, to: to.id) {
            RiverMapGeometry.schematicPath(from: from, to: to, document: document)
        }.point(at: progress)
    }
}
