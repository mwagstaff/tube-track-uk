import SwiftUI
import UIKit

struct RiverPierPlacement {
    let pier: RiverPier
    let anchor: RiverSchematicAnchor
    let point: CGPoint
    let riverPoint: CGPoint
    let labelFrame: CGRect?
}

enum RiverSchematicLayout {
    private static func walkIntersects(_ frame: CGRect, points: [CGPoint]) -> Bool {
        zip(points, points.dropFirst()).contains { start, end in
            var entry: CGFloat = 0, exit: CGFloat = 1
            for (origin, delta, lower, upper) in [
                (start.x, end.x - start.x, frame.minX, frame.maxX),
                (start.y, end.y - start.y, frame.minY, frame.maxY)
            ] {
                if abs(delta) < 0.001 {
                    if origin < lower || origin > upper { return false }
                } else {
                    let a = (lower - origin) / delta, b = (upper - origin) / delta
                    entry = max(entry, min(a, b)); exit = min(exit, max(a, b))
                    if entry > exit { return false }
                }
            }
            return true
        }
    }

    static func placements(network: RiverNetwork, anchors: [RiverSchematicAnchor], selected: String?, lineId: String?,
                           scale: CGFloat, offset: CGSize, viewport: CGSize, typeScale: CGFloat,
                           blocked: [CGRect], document: BeckMapDocument? = nil) -> [RiverPierPlacement] {
        let bounds = CGRect(origin: .zero, size: viewport)
        var occupied = blocked
        var markers: [CGRect] = []
        var result: [RiverPierPlacement] = []
        // Piers the TfL map shows, with walking links to stations, are always
        // drawn like the stations they serve.
        func prominent(_ anchor: RiverSchematicAnchor) -> Bool {
            anchor.major || !(anchor.walkingLinkStationIDs ?? []).isEmpty
        }
        let ordered = anchors.sorted {
            if ($0.id == selected) != ($1.id == selected) { return $0.id == selected }
            if prominent($0) != prominent($1) { return prominent($0) }
            return $0.id < $1.id
        }
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.width, y: p.y * scale + offset.height) }
        // Include later piers too; an earlier label must not cover their discs.
        let labelMarkerFrames: [(String, CGRect)] = anchors.compactMap { anchor in
            guard let pier = network.pier(anchor.id),
                  lineId == nil || pier.lineIds.contains(lineId!) || pier.id == selected,
                  prominent(anchor) || scale >= 0.55 || pier.id == selected else { return nil }
            let point = screen(anchor.markerPoint)
            let radius = BeckRiverLayer.markerRadius(selected: pier.id == selected, scale: scale, document: document) + 1
            return (anchor.id, CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        for anchor in ordered {
            guard let pier = network.pier(anchor.id),
                  lineId == nil || pier.lineIds.contains(lineId!) || pier.id == selected,
                  prominent(anchor) || scale >= 0.55 || pier.id == selected else { continue }
            let point = screen(anchor.markerPoint)
            // Piers only give way to piers they would actually overlap.
            let radius = BeckRiverLayer.markerRadius(selected: pier.id == selected, scale: scale, document: document) + 1
            let hit = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            guard bounds.intersects(hit),
                  !markers.contains(where: { $0.intersects(hit) }) || pier.id == selected || prominent(anchor)
            else { continue }
            markers.append(hit)
            var labelFrame: CGRect?
            let walks: [[CGPoint]] = (anchor.walkingLinkVia ?? []).isEmpty ? [] : (anchor.walkingLinkStationIDs ?? []).compactMap { id in
                guard let document,
                      let roundel = BeckMapWalkingLink.roundel(of: id, nearest: anchor.markerPoint, in: document) else { return nil }
                return [point] + (anchor.walkingLinkVia ?? []).map { screen(CGPoint(x: $0.x, y: $0.y)) } + [screen(roundel.centre)]
            }
            // Keep ordinary station-focused views clear; reveal pier names
            // at a closer zoom, or when the pier itself is selected.
            if scale >= 2.0 || pier.id == selected {
                let font = UIFont.systemFont(ofSize: 12 * min(1.6, typeScale), weight: .semibold)
                let rect = (pier.name as NSString).boundingRect(with: CGSize(width: 190, height: 80), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
                let width = ceil(rect.width) + 12, height = ceil(rect.height) + 8
                let gap = radius + 5
                let candidates = [
                    CGRect(x: point.x + gap, y: point.y - height / 2, width: width, height: height),
                    CGRect(x: point.x - width - gap, y: point.y - height / 2, width: width, height: height),
                    CGRect(x: point.x - width / 2, y: point.y + gap, width: width, height: height),
                    CGRect(x: point.x - width / 2, y: point.y - height - gap, width: width, height: height),
                    CGRect(x: point.x + gap, y: point.y + 4 * scale, width: width, height: height),
                    CGRect(x: point.x - width - gap, y: point.y + 4 * scale, width: width, height: height)
                ]
                let preferred = anchor.labelSide < 0
                    ? [candidates[1], candidates[3], candidates[0], candidates[2], candidates[5], candidates[4]] : candidates
                labelFrame = preferred.first { frame in
                    bounds.contains(frame) && !occupied.contains(where: { $0.intersects(frame) })
                        && !labelMarkerFrames.contains { $0.0 != anchor.id && $0.1.intersects(frame) }
                        && !walks.contains { walkIntersects(frame.insetBy(dx: -2 * scale, dy: -2 * scale), points: $0) }
                }
                if let labelFrame { occupied.append(labelFrame.insetBy(dx: -4, dy: -4)) }
            }
            result.append(RiverPierPlacement(pier: pier, anchor: anchor, point: point,
                                             riverPoint: screen(anchor.riverPoint), labelFrame: labelFrame))
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

    /// Match the station roundels in each document, including at overview zoom.
    /// The separate tap target stays large; the visible disc has no size floor.
    static func markerRadius(selected: Bool, scale: CGFloat, document: BeckMapDocument? = nil) -> CGFloat {
        let artworkRadius: CGFloat = document?.referenceArtwork == nil ? 12.43 : 7.1
        return artworkRadius * scale * (selected ? 1.15 : 1)
    }

    private static func drawPier(at point: CGPoint, selected: Bool, scale: CGFloat,
                                 document: BeckMapDocument, context: inout GraphicsContext) {
        let radius = markerRadius(selected: selected, scale: scale, document: document)
        let outline = (selected ? 2.0 : 1.2) * scale
        let discRadius = max(0, radius - outline / 2)
        let circle = Path(ellipseIn: CGRect(x: point.x - discRadius, y: point.y - discRadius,
                                           width: discRadius * 2, height: discRadius * 2))
        context.fill(circle, with: .color(selected ? .blue : Color(.systemBackground)))
        context.stroke(circle, with: .color(.blue), lineWidth: outline)
        if selected || radius >= 5 {
            var icon = context.resolve(Image(systemName: "ferry.fill"))
            icon.shading = .color(selected ? .white : .blue)
            let iconSize = radius * 1.35
            context.draw(icon, in: CGRect(x: point.x - iconSize / 2, y: point.y - iconSize / 2,
                                         width: iconSize, height: iconSize))
        }
    }

    var body: some View {
        let river = appState.river
        let canvasOffset = CGSize(width: offset.width + overscan, height: offset.height + overscan)
        let anchors = river.anchors(in: document)
        let placements = RiverSchematicLayout.placements(network: river.network, anchors: anchors,
            selected: river.selectedPierId, lineId: river.selectedLineId, scale: scale, offset: canvasOffset,
            viewport: canvasSize, typeScale: typeScale, blocked: blocked, document: document)
        let sourceWalkingLinks = (document.referenceArtwork?.riverWalkingLinks ?? []).map {
            (pierID: $0.pierID, cache: BeckMapReferenceRenderCache(.init(shapes: $0.shapes, texts: [])))
        }
        let key = "\(scale):\(offset):\(canvasSize):\(typeScale):\(colorScheme):\(river.selectedPierId ?? ""):\(river.selectedLineId ?? ""):\(placements.map { $0.pier.name }.joined())"
        BeckMapRetainedCanvas(key: key, camera: camera, renderScale: scale, renderOffset: offset,
            overscan: overscan, canvasSize: canvasSize, colorScheme: colorScheme) { context, _ in
            if let lineId = river.selectedLineId {
                var seen = Set<String>()
                for route in river.network.routes where route.lineId == lineId {
                    for (a, b) in zip(route.stopIds, route.stopIds.dropFirst()) {
                        let id = [a, b].sorted().joined(separator: ":")
                        guard seen.insert(id).inserted,
                              let from = anchors.first(where: { $0.id == a }),
                              let to = anchors.first(where: { $0.id == b }) else { continue }
                        let points = RiverMapGeometry.schematicPath(from: from, to: to, document: document)
                            .map { CGPoint(x: $0.x * scale + canvasOffset.width, y: $0.y * scale + canvasOffset.height) }
                        guard let first = points.first else { continue }
                        var path = Path(); path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }
                        context.stroke(path, with: .color(.blue.opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }
            }
            // TfL joins piers to nearby stations with dotted walking links.
            let palette = BeckMapPalette.resolve(for: colorScheme)
            let visiblePiers = Set(placements.map { $0.pier.id })
                .union((document.referenceArtwork?.additionalRiverPiers ?? []).map(\.id))
            var walkingContext = context
            walkingContext.translateBy(x: canvasOffset.width, y: canvasOffset.height)
            walkingContext.scaleBy(x: scale, y: scale)
            for link in sourceWalkingLinks where visiblePiers.contains(link.pierID) {
                for (path, style) in link.cache.shapes {
                    walkingContext.fill(path, with: .color(palette.stationOutline), style: FillStyle(eoFill: style.evenOdd))
                }
            }
            let walkWidth = CGFloat(BeckMapWalkingLink.width(in: document)) * scale
            for item in placements {
                guard item.anchor.walkingLinksInArtwork != true else { continue }
                for stationID in item.anchor.walkingLinkStationIDs ?? [] {
                    guard let roundel = BeckMapWalkingLink.roundel(
                        of: stationID, nearest: item.anchor.markerPoint, in: document
                    ) else { continue }
                    BeckMapWalkingLink.draw(
                        from: item.point, startRadius: Self.markerRadius(selected: item.pier.id == river.selectedPierId, scale: scale, document: document),
                        to: CGPoint(x: roundel.centre.x * scale + canvasOffset.width, y: roundel.centre.y * scale + canvasOffset.height),
                        endRadius: roundel.outerRadius * scale,
                        via: (item.anchor.walkingLinkVia ?? []).map {
                            CGPoint(x: $0.x * scale + canvasOffset.width, y: $0.y * scale + canvasOffset.height)
                        },
                        width: walkWidth, color: palette.stationOutline, in: &context
                    )
                }
            }
            for item in placements {
                // As on the TfL map, each pier is centred on its river bank
                // edge (RiverSchematic.json), so no leader to the river is drawn.
                let selected = item.pier.id == river.selectedPierId
                Self.drawPier(at: item.point, selected: selected, scale: scale, document: document, context: &context)
                if let frame = item.labelFrame {
                    context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(Color(.systemBackground).opacity(0.94)))
                    let label = context.resolve(Text(item.pier.name).font(.system(size: 12 * min(1.6, typeScale), weight: .semibold)).foregroundStyle(.primary))
                    context.draw(label, in: frame.insetBy(dx: 6, dy: 4))
                }
            }
            for pier in document.referenceArtwork?.additionalRiverPiers ?? [] {
                let point = CGPoint(x: pier.centre.x * scale + canvasOffset.width,
                                    y: pier.centre.y * scale + canvasOffset.height)
                Self.drawPier(at: point, selected: false, scale: scale, document: document, context: &context)
            }
        }
        .allowsHitTesting(false)
        if river.shouldShowBoats, !appState.isOffline,
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
    func anchors(in document: BeckMapDocument) -> [RiverSchematicAnchor] {
        document.referenceArtwork?.riverAnchors ?? anchors
    }

    func schematicPoint(for boat: EstimatedRiverBoat, document: BeckMapDocument, at date: Date) -> CGPoint? {
        let anchors = anchors(in: document)
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
