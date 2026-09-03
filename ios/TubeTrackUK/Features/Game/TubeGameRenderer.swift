import SwiftUI

struct TubeGameRenderModel: Sendable {
    struct Segment: Identifiable, Sendable {
        let id: String
        let lineID: TubeLineID
        let geometry: TubeGamePathGeometry
        let bounds: CGRect
    }

    struct Waterway: Identifiable, Sendable {
        let id: String
        let geometry: TubeGamePathGeometry
        let strokeWidth: CGFloat
        let outlineWidth: CGFloat
        let bounds: CGRect
    }

    struct TransferSegment: Identifiable, Sendable {
        let id: String
        let geometry: TubeGamePathGeometry
        let bounds: CGRect
    }

    struct RouteEdge: Sendable {
        let id: String
        let fromStationID: String
        let toStationID: String
        let geometry: TubeGamePathGeometry
    }

    struct StationMarker: Identifiable, Sendable {
        let id: String
        let hubID: String
        let anchor: CGPoint
        let bounds: CGRect
        let primitives: [BeckMapStationMarkerPrimitive]
    }

    let artworkSize: CGSize
    let segments: [Segment]
    let transferSegments: [TransferSegment]
    let waterways: [Waterway]
    let routeEdgesByID: [String: RouteEdge]
    let stationMarkers: [StationMarker]
    let hubs: [TubeGameHub]
    let nodes: [TubeGameNode]
    let hubsByID: [String: TubeGameHub]
    let routeStrokeWidth: CGFloat
    let parallelRouteOuterStrokeWidth: CGFloat
    let parallelRouteInnerStrokeWidth: CGFloat

    init(document: BeckMapDocument, network: TubeGameNetwork) {
        let pathsByID = Dictionary(uniqueKeysWithValues: document.paths.map { ($0.id, $0) })
        segments = document.segments.compactMap { segment in
            guard let edge = network.edge(id: segment.id) else { return nil }
            return Segment(
                id: segment.id,
                lineID: segment.lineID,
                geometry: edge.geometry,
                bounds: Self.bounds(for: edge.geometry.points)
            )
        }
        transferSegments = network.edges.compactMap { edge in
            guard edge.kind.isTransfer else { return nil }
            return TransferSegment(
                id: edge.id,
                geometry: edge.geometry,
                bounds: Self.bounds(for: edge.geometry.points)
            )
        }
        routeEdgesByID = Dictionary(uniqueKeysWithValues: network.edges.map { edge in
            (
                edge.id,
                RouteEdge(
                    id: edge.id,
                    fromStationID: edge.fromStationID,
                    toStationID: edge.toStationID,
                    geometry: edge.geometry
                )
            )
        })
        stationMarkers = document.stationMarkers.compactMap { marker in
            guard let node = network.node(stationID: marker.stationID) else { return nil }
            return StationMarker(
                id: marker.stationID,
                hubID: node.hubID,
                anchor: CGPoint(x: marker.anchor.x, y: marker.anchor.y),
                bounds: Self.bounds(for: marker),
                primitives: marker.primitives
            )
        }
        waterways = (document.waterways ?? []).compactMap { waterway in
            guard let path = pathsByID[waterway.pathID] else { return nil }
            let geometry = TubeGameGeometryBuilder.build(commands: path.commands)
            guard geometry.totalLength > 0 else { return nil }
            return Waterway(
                id: waterway.id,
                geometry: geometry,
                strokeWidth: CGFloat(waterway.strokeWidth),
                outlineWidth: CGFloat(waterway.outlineWidth),
                bounds: Self.bounds(for: geometry.points)
            )
        }
        hubs = network.hubs
        nodes = network.nodes
        hubsByID = Dictionary(uniqueKeysWithValues: network.hubs.map { ($0.id, $0) })
        artworkSize = network.artworkSize
        routeStrokeWidth = CGFloat(document.styles.routeStrokeWidth)
        parallelRouteOuterStrokeWidth = CGFloat(document.styles.parallelRouteOuterStrokeWidth)
        parallelRouteInnerStrokeWidth = CGFloat(document.styles.parallelRouteInnerStrokeWidth)
    }

    private static func bounds(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(
            into: CGRect(x: first.x, y: first.y, width: 0, height: 0)
        ) { bounds, point in
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }
    }

    private static func bounds(for marker: BeckMapStationMarkerRecord) -> CGRect {
        var bounds = CGRect(
            x: marker.anchor.x,
            y: marker.anchor.y,
            width: 0,
            height: 0
        )
        for primitive in marker.primitives {
            switch primitive {
            case let .connector(connector), let .walkingConnector(connector):
                bounds = bounds.union(CGRect(
                    x: min(connector.start.x, connector.end.x),
                    y: min(connector.start.y, connector.end.y),
                    width: abs(connector.end.x - connector.start.x),
                    height: abs(connector.end.y - connector.start.y)
                ).insetBy(dx: -connector.width, dy: -connector.width))
            case let .circle(circle):
                bounds = bounds.union(CGRect(
                    x: circle.centre.x - circle.radius - circle.outlineWidth,
                    y: circle.centre.y - circle.radius - circle.outlineWidth,
                    width: (circle.radius + circle.outlineWidth) * 2,
                    height: (circle.radius + circle.outlineWidth) * 2
                ))
            case let .tick(tick):
                bounds = bounds.union(CGRect(
                    x: min(tick.start.x, tick.end.x),
                    y: min(tick.start.y, tick.end.y),
                    width: abs(tick.end.x - tick.start.x),
                    height: abs(tick.end.y - tick.start.y)
                ).insetBy(dx: -tick.width, dy: -tick.width))
            }
        }
        return bounds
    }
}

struct TubeGameCameraState: Equatable, Sendable {
    let scale: CGFloat
    let offset: CGSize
    let visibleArtworkRect: CGRect
    let playerScreenPoint: CGPoint

    static func following(
        player: CGPoint,
        artworkSize: CGSize,
        viewportSize: CGSize,
        scale: CGFloat = 0.65
    ) -> Self {
        let target = CGPoint(x: viewportSize.width / 2, y: viewportSize.height * 0.56)
        let scaledWidth = artworkSize.width * scale
        let scaledHeight = artworkSize.height * scale

        let desiredX = target.x - player.x * scale
        let desiredY = target.y - player.y * scale
        let offsetX = clampedOffset(
            desiredX,
            viewportLength: viewportSize.width,
            contentLength: scaledWidth
        )
        let offsetY = clampedOffset(
            desiredY,
            viewportLength: viewportSize.height,
            contentLength: scaledHeight
        )
        let offset = CGSize(width: offsetX, height: offsetY)
        let visibleRect = CGRect(
            x: -offset.width / scale,
            y: -offset.height / scale,
            width: viewportSize.width / scale,
            height: viewportSize.height / scale
        )
        return Self(
            scale: scale,
            offset: offset,
            visibleArtworkRect: visibleRect,
            playerScreenPoint: CGPoint(
                x: player.x * scale + offset.width,
                y: player.y * scale + offset.height
            )
        )
    }

    func screenPoint(_ artworkPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: artworkPoint.x * scale + offset.width,
            y: artworkPoint.y * scale + offset.height
        )
    }

    private static func clampedOffset(
        _ proposed: CGFloat,
        viewportLength: CGFloat,
        contentLength: CGFloat
    ) -> CGFloat {
        guard contentLength > viewportLength else {
            return (viewportLength - contentLength) / 2
        }
        return min(0, max(viewportLength - contentLength, proposed))
    }
}

struct TubeGamePlayfield: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var directionGestureIsActive = false
    @State private var gestureIntentTracker = TubeGameGestureIntentTrackerBox()

    let model: TubeGameRenderModel
    let snapshot: TubeGameSnapshot
    let onDirection: (TubeGameDirection) -> Void

    var body: some View {
        GeometryReader { proxy in
            let camera = TubeGameCameraState.following(
                player: snapshot.player.position,
                artworkSize: model.artworkSize,
                viewportSize: proxy.size
            )

            ZStack {
                Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                    drawMap(
                        context: &context,
                        size: size,
                        camera: camera,
                        palette: BeckMapPalette.resolve(for: colorScheme)
                    )
                }

                Canvas(rendersAsynchronously: false) { context, _ in
                    drawFeedbackOverlay(
                        context: &context,
                        camera: camera,
                        palette: BeckMapPalette.resolve(for: colorScheme)
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(.rect)
            .gesture(directionGesture(in: proxy))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(gameplayAccessibilityLabel)
            .accessibilityAction(named: "Go north") { onDirection(.north) }
            .accessibilityAction(named: "Go north-east") { onDirection(.northEast) }
            .accessibilityAction(named: "Go east") { onDirection(.east) }
            .accessibilityAction(named: "Go south-east") { onDirection(.southEast) }
            .accessibilityAction(named: "Go south") { onDirection(.south) }
            .accessibilityAction(named: "Go south-west") { onDirection(.southWest) }
            .accessibilityAction(named: "Go west") { onDirection(.west) }
            .accessibilityAction(named: "Go north-west") { onDirection(.northWest) }
        }
        .onChange(of: directionGestureIsActive) { _, isActive in
            if !isActive {
                gestureIntentTracker.cancel()
            }
        }
        .onChange(of: directionInputIsEnabled) { _, isEnabled in
            if !isEnabled {
                gestureIntentTracker.cancel()
            }
        }
    }

    private func drawMap(
        context: inout GraphicsContext,
        size: CGSize,
        camera: TubeGameCameraState,
        palette: BeckMapPalette
    ) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(palette.background)
        )

        var mapContext = context
        mapContext.concatenate(CGAffineTransform(
            a: camera.scale,
            b: 0,
            c: 0,
            d: camera.scale,
            tx: camera.offset.width,
            ty: camera.offset.height
        ))

        let cullingBounds = camera.visibleArtworkRect.insetBy(dx: -40, dy: -40)
        for waterway in model.waterways where waterway.bounds.intersects(cullingBounds) {
            let path = Self.path(for: waterway.geometry.points)
            mapContext.stroke(
                path,
                with: .color(palette.waterwayOutline),
                style: StrokeStyle(
                    lineWidth: waterway.strokeWidth + waterway.outlineWidth * 2,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            mapContext.stroke(
                path,
                with: .color(palette.waterwayFill),
                style: StrokeStyle(
                    lineWidth: waterway.strokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }

        for segment in model.segments where segment.bounds.intersects(cullingBounds) {
            let path = Self.path(for: segment.geometry.points)
            if let casing = palette.northernLineCasing,
               let casingWidth = palette.casingWidth(
                   for: segment.lineID,
                   routeWidth: model.routeStrokeWidth
               ) {
                mapContext.stroke(
                    path,
                    with: .color(casing),
                    style: StrokeStyle(
                        lineWidth: casingWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }

            if segment.lineID.usesParallelSchematicStroke {
                mapContext.stroke(
                    path,
                    with: .color(.tubeLine(segment.lineID)),
                    style: StrokeStyle(
                        lineWidth: segment.lineID == .tram
                            ? 8.844
                            : model.parallelRouteOuterStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                mapContext.stroke(
                    path,
                    with: .color(palette.paper),
                    style: StrokeStyle(
                        lineWidth: segment.lineID == .tram
                            ? 2.768
                            : model.parallelRouteInnerStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            } else {
                mapContext.stroke(
                    path,
                    with: .color(.tubeLine(segment.lineID)),
                    style: StrokeStyle(
                        lineWidth: model.routeStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }

        drawActiveTransfer(
            context: &mapContext,
            visibleBounds: cullingBounds,
            palette: palette
        )

    }

    private func drawActiveTransfer(
        context: inout GraphicsContext,
        visibleBounds: CGRect,
        palette: BeckMapPalette
    ) {
        guard let edgeID = snapshot.player.edgeID,
              let segment = model.transferSegments.first(where: { $0.id == edgeID }),
              segment.bounds.intersects(visibleBounds)
        else { return }

        let path = Self.path(for: segment.geometry.points)
        context.stroke(
            path,
            with: .color(palette.stationOutline.opacity(0.7)),
            style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(palette.paper),
            style: StrokeStyle(
                lineWidth: 4,
                lineCap: .round,
                lineJoin: .round,
                dash: [5, 4]
            )
        )
    }

    private func drawCollectibles(
        context: inout GraphicsContext,
        camera: TubeGameCameraState,
        palette: BeckMapPalette
    ) {
        let expandedBounds = camera.visibleArtworkRect.insetBy(dx: -30, dy: -30)
        for marker in model.stationMarkers where marker.bounds.intersects(expandedBounds) {
            let consumed = snapshot.consumedHubIDs.contains(marker.hubID)
            drawAuthoredConnectors(
                for: marker,
                consumed: consumed,
                context: &context,
                camera: camera,
                palette: palette
            )

            let circles = marker.primitives.compactMap { primitive -> BeckMapCirclePrimitive? in
                guard case let .circle(circle) = primitive else { return nil }
                return circle
            }
            if !circles.isEmpty {
                for circle in circles {
                    drawCollectibleCircle(
                        circle,
                        consumed: consumed,
                        context: &context,
                        camera: camera,
                        palette: palette
                    )
                }
                continue
            }

            guard let hub = model.hubsByID[marker.hubID] else { continue }
            let point = camera.screenPoint(marker.anchor)
            let radius = consumed
                ? CGFloat(4.2)
                : (CGFloat(6.4) + CGFloat(min(3, max(0, hub.lineIDs.count - 1)))) * 0.75
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let marker = Path(ellipseIn: rect)

            if consumed {
                context.fill(marker, with: .color(palette.paper.opacity(0.62)))
                context.stroke(
                    marker,
                    with: .color(palette.stationOutline.opacity(0.48)),
                    lineWidth: 1.4
                )
            } else {
                context.fill(
                    marker,
                    with: .color(Color(red: 1.0, green: 0.72, blue: 0.02))
                )
                context.stroke(marker, with: .color(palette.stationOutline), lineWidth: 2)

                if hub.lineIDs.count >= 3 {
                    let inner = Path(ellipseIn: rect.insetBy(dx: 3.2, dy: 3.2))
                    context.fill(inner, with: .color(palette.paper))
                }
            }
        }
    }

    private func drawAuthoredConnectors(
        for marker: TubeGameRenderModel.StationMarker,
        consumed: Bool,
        context: inout GraphicsContext,
        camera: TubeGameCameraState,
        palette: BeckMapPalette
    ) {
        for primitive in marker.primitives {
            let connector: BeckMapLinePrimitive
            let isWalking: Bool
            switch primitive {
            case let .connector(value):
                connector = value
                isWalking = false
            case let .walkingConnector(value):
                connector = value
                isWalking = true
            case .circle, .tick:
                continue
            }

            var path = Path()
            path.move(to: camera.screenPoint(CGPoint(
                x: connector.start.x,
                y: connector.start.y
            )))
            path.addLine(to: camera.screenPoint(CGPoint(
                x: connector.end.x,
                y: connector.end.y
            )))
            let width = max(1.2, CGFloat(connector.width) * camera.scale)
            let outline = palette.stationOutline.opacity(consumed ? 0.48 : 1)
            if isWalking {
                context.stroke(
                    path,
                    with: .color(outline),
                    style: StrokeStyle(
                        lineWidth: width,
                        lineCap: .butt,
                        dash: [max(3, width), max(2, width * 0.65)]
                    )
                )
            } else {
                context.stroke(
                    path,
                    with: .color(outline),
                    style: StrokeStyle(lineWidth: width + 1.8, lineCap: .round)
                )
                context.stroke(
                    path,
                    with: .color(palette.paper.opacity(consumed ? 0.62 : 1)),
                    style: StrokeStyle(lineWidth: max(1, width - 2.2), lineCap: .round)
                )
            }
        }
    }

    private func drawCollectibleCircle(
        _ circle: BeckMapCirclePrimitive,
        consumed: Bool,
        context: inout GraphicsContext,
        camera: TubeGameCameraState,
        palette: BeckMapPalette
    ) {
        let point = camera.screenPoint(CGPoint(x: circle.centre.x, y: circle.centre.y))
        let radius = max(4.2, CGFloat(circle.radius) * camera.scale)
        let marker = Path(ellipseIn: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.fill(
            marker,
            with: .color(consumed
                ? palette.paper.opacity(0.62)
                : Color(red: 1.0, green: 0.72, blue: 0.02))
        )
        context.stroke(
            marker,
            with: .color(palette.stationOutline.opacity(consumed ? 0.48 : 1)),
            lineWidth: max(1.4, CGFloat(circle.outlineWidth) * camera.scale)
        )
    }

    private func drawFeedbackOverlay(
        context: inout GraphicsContext,
        camera: TubeGameCameraState,
        palette: BeckMapPalette
    ) {
        drawRoutePreview(context: &context, camera: camera, palette: palette)
        drawCollectibles(context: &context, camera: camera, palette: palette)
        drawActors(context: &context, camera: camera, palette: palette)
        drawRecentStationLabels(context: &context, camera: camera, palette: palette)
    }

    private func drawRoutePreview(
        context: inout GraphicsContext,
        camera: TubeGameCameraState,
        palette: BeckMapPalette
    ) {
        guard let preview = snapshot.routePreview,
              let edge = model.routeEdgesByID[preview.edgeID],
              let geometry = TubeGameRouteFeedback.orientedGeometry(
                for: edge,
                fromStationID: preview.fromStationID,
                toStationID: preview.toStationID
              ),
              geometry.totalLength > 0
        else { return }

        let screenPoints = geometry.points.map(camera.screenPoint)
        let path = Self.path(for: screenPoints)
        let emphasis = preview.isCommitted ? 0.84 : 1.0
        let yellow = Color(red: 1.0, green: 0.72, blue: 0.02)

        context.stroke(
            path,
            with: .color(palette.stationOutline.opacity(0.78 * emphasis)),
            style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(palette.paper.opacity(0.82 * emphasis)),
            style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(yellow.opacity(0.82 * emphasis)),
            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
        )

        let spacing = 32 / max(camera.scale, 0.001)
        let phase = reduceMotion
            ? spacing / 2
            : CGFloat(snapshot.elapsedTime * 25) / max(camera.scale, 0.001)
        for marker in TubeGameRouteFeedback.markers(
            along: geometry,
            spacing: spacing,
            phase: phase
        ) {
            drawRouteChevron(
                at: camera.screenPoint(marker.point),
                tangent: marker.tangent,
                context: &context,
                colour: palette.stationOutline.opacity(0.90 * emphasis)
            )
        }
    }

    private func drawRouteChevron(
        at point: CGPoint,
        tangent: CGVector,
        context: inout GraphicsContext,
        colour: Color
    ) {
        let perpendicular = CGVector(dx: -tangent.dy, dy: tangent.dx)
        let tip = CGPoint(
            x: point.x + tangent.dx * 5,
            y: point.y + tangent.dy * 5
        )
        let back = CGPoint(
            x: point.x - tangent.dx * 4,
            y: point.y - tangent.dy * 4
        )
        var chevron = Path()
        chevron.move(to: CGPoint(
            x: back.x + perpendicular.dx * 4,
            y: back.y + perpendicular.dy * 4
        ))
        chevron.addLine(to: tip)
        chevron.addLine(to: CGPoint(
            x: back.x - perpendicular.dx * 4,
            y: back.y - perpendicular.dy * 4
        ))
        context.stroke(
            chevron,
            with: .color(colour),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawRecentStationLabels(
        context: inout GraphicsContext,
        camera: TubeGameCameraState,
        palette: BeckMapPalette
    ) {
        let consumptions = TubeGameStationLabelPresentation.visibleConsumptions(
            snapshot.recentStationConsumptions,
            at: snapshot.elapsedTime
        )
        for consumption in consumptions {
            let opacity = TubeGameStationLabelPresentation.opacity(
                eatenAt: consumption.eatenAtElapsedTime,
                currentTime: snapshot.elapsedTime
            )
            guard opacity > 0 else { continue }

            var point = camera.screenPoint(consumption.position)
            point.y -= 15
            point.y += TubeGameStationLabelPresentation.verticalOffset(
                eatenAt: consumption.eatenAtElapsedTime,
                currentTime: snapshot.elapsedTime,
                reduceMotion: reduceMotion
            )

            var text = context.resolve(
                Text(consumption.stationName).font(
                    AppTypography.fixedBody(size: 13, weight: .semibold)
                )
            )
            text.shading = .color(palette.ink.opacity(opacity))
            let textSize = text.measure(in: CGSize(
                width: CGFloat.infinity,
                height: CGFloat.infinity
            ))
            let labelRect = CGRect(
                x: point.x - textSize.width / 2 - 8,
                y: point.y - textSize.height / 2 - 5,
                width: textSize.width + 16,
                height: textSize.height + 10
            )
            let capsule = Path(roundedRect: labelRect, cornerRadius: labelRect.height / 2)
            context.fill(
                capsule,
                with: .color(palette.labelSurface.opacity(0.94 * opacity))
            )
            context.stroke(
                capsule,
                with: .color(palette.labelBorder.opacity(opacity)),
                lineWidth: max(0.8, palette.labelBorderWidth)
            )
            context.draw(text, at: point, anchor: .center)
        }
    }

    private func drawActors(
        context: inout GraphicsContext,
        camera: TubeGameCameraState,
        palette: BeckMapPalette
    ) {
        for train in snapshot.trains {
            let point = camera.screenPoint(train.position)
            let rect = CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
            let markerImage = context.resolve(Image(train.lineID.liveTrainMarkerAssetName))
            context.draw(markerImage, in: rect)
        }

        let playerPoint = camera.screenPoint(snapshot.player.position)
        let headingAngle = atan2(snapshot.player.heading.dy, snapshot.player.heading.dx)
        let mouth = reduceMotion
            ? 30.0
            : 22.0 + 13.0 * (sin(snapshot.elapsedTime * 11.0) + 1.0) / 2.0
        let playerRect = CGRect(x: -15, y: -15, width: 30, height: 30)
        var playerContext = context
        playerContext.translateBy(x: playerPoint.x, y: playerPoint.y)
        playerContext.rotate(by: .radians(Double(headingAngle)))
        let player = ChomperShape(mouthAngle: mouth).path(in: playerRect)
        playerContext.fill(
            player,
            with: .color(Color(red: 1.0, green: 0.72, blue: 0.02))
        )
        playerContext.stroke(player, with: .color(palette.stationOutline), lineWidth: 1.8)

        if let queuedDirection = snapshot.queuedDirection {
            Self.drawQueuedDirection(
                queuedDirection,
                playerPoint: playerPoint,
                context: &context,
                palette: palette
            )
        }
    }

    private static func drawQueuedDirection(
        _ direction: TubeGameDirection,
        playerPoint: CGPoint,
        context: inout GraphicsContext,
        palette: BeckMapPalette
    ) {
        let vector = direction.vector
        let centre = CGPoint(
            x: playerPoint.x + vector.dx * 31,
            y: playerPoint.y + vector.dy * 31
        )
        let background = Path(ellipseIn: CGRect(
            x: centre.x - 9,
            y: centre.y - 9,
            width: 18,
            height: 18
        ))
        context.fill(background, with: .color(palette.labelSurface))
        context.stroke(background, with: .color(palette.ink.opacity(0.72)), lineWidth: 1)

        let start = CGPoint(x: centre.x - vector.dx * 4, y: centre.y - vector.dy * 4)
        let tip = CGPoint(x: centre.x + vector.dx * 5, y: centre.y + vector.dy * 5)
        var arrow = Path()
        arrow.move(to: start)
        arrow.addLine(to: tip)
        let perpendicular = CGVector(dx: -vector.dy, dy: vector.dx)
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(
            x: tip.x - vector.dx * 4 + perpendicular.dx * 3.5,
            y: tip.y - vector.dy * 4 + perpendicular.dy * 3.5
        ))
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(
            x: tip.x - vector.dx * 4 - perpendicular.dx * 3.5,
            y: tip.y - vector.dy * 4 - perpendicular.dy * 3.5
        ))
        context.stroke(
            arrow,
            with: .color(palette.ink),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
    }

    private func directionGesture(in proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($directionGestureIsActive) { _, isActive, _ in
                isActive = true
            }
            .onChanged { value in
                guard directionInputIsEnabled,
                      acceptsDirectionInput(startingAt: value.startLocation, in: proxy),
                      let direction = gestureIntentTracker.updateSwipe(
                        for: value.translation
                      )
                else { return }

                onDirection(direction)
            }
            .onEnded { value in
                guard directionInputIsEnabled,
                      acceptsDirectionInput(startingAt: value.startLocation, in: proxy)
                else {
                    gestureIntentTracker.cancel()
                    return
                }
                let hadLiveSwipe = gestureIntentTracker.hasActiveSwipe
                if let direction = gestureIntentTracker.finishSwipe(
                    translation: value.translation
                ) {
                    onDirection(direction)
                    return
                }
                if !hadLiveSwipe {
                    gestureIntentTracker.cancel()
                }
            }
    }

    private func acceptsDirectionInput(
        startingAt location: CGPoint,
        in proxy: GeometryProxy
    ) -> Bool {
        location.y > proxy.safeAreaInsets.top + 92
            && location.y < proxy.size.height - max(24, proxy.safeAreaInsets.bottom)
    }

    private var directionInputIsEnabled: Bool {
        switch snapshot.phase {
        case .countdown, .playing:
            true
        case .ready, .paused, .ended:
            false
        }
    }

    fileprivate static func path(for points: [CGPoint]) -> Path {
        guard let first = points.first else { return Path() }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private var gameplayAccessibilityLabel: String {
        let seconds = Int(ceil(snapshot.remainingTime))
        let line = snapshot.player.lineID.map { ", on the \($0.displayName)" } ?? ""
        let destination = snapshot.player.destinationStationName
            .map { ", heading towards \($0)" }
            ?? ""
        let nearestTrainDistance = snapshot.trains
            .map {
                hypot(
                    $0.position.x - snapshot.player.position.x,
                    $0.position.y - snapshot.player.position.y
                )
            }
            .min()
        let danger = nearestTrainDistance.map { $0 < 150 ? " Train nearby." : "" } ?? ""
        let latestEaten = TubeGameStationLabelPresentation.visibleConsumptions(
            snapshot.recentStationConsumptions,
            at: snapshot.elapsedTime
        ).last.map { " Latest station eaten, \($0.stationName)." } ?? ""
        return "Station Chase at \(snapshot.player.stationName)\(destination)\(line). Score \(snapshot.score). \(seconds) seconds remaining. \(snapshot.remainingStationCount) stations remaining.\(danger)\(latestEaten)"
    }
}

enum TubeGameGestureIntent {
    /// Small enough to register on the first meaningful touch movement while
    /// still filtering the sub-point jitter produced when a finger lands.
    static let swipeActivationDistance: CGFloat = 1.5
    /// Cardinal directions get wider sectors than diagonals. Players usually
    /// mean “up” or “across” when a short swipe is only slightly off-axis.
    static let cardinalHalfSectorDegrees: CGFloat = 30
    static let diagonalHalfSectorDegrees: CGFloat = 15
    static let sectorBoundaryHysteresisDegrees: CGFloat = 5

    private static let cardinalSlope = tan(cardinalHalfSectorDegrees * .pi / 180)
    private static let sectorBoundaryHysteresis =
        sectorBoundaryHysteresisDegrees * .pi / 180

    static func swipeDirection(for translation: CGSize) -> TubeGameDirection? {
        let vector = CGVector(dx: translation.width, dy: translation.height)
        guard hypot(vector.dx, vector.dy) >= swipeActivationDistance else {
            return nil
        }
        return forgivingDirection(for: vector)
    }

    static func shouldLeave(
        _ activeDirection: TubeGameDirection,
        for translation: CGSize
    ) -> Bool {
        let vector = CGVector(dx: translation.width, dy: translation.height)
        guard vector.dx.isFinite, vector.dy.isFinite,
              hypot(vector.dx, vector.dy) >= swipeActivationDistance
        else { return false }

        let activeAngle = atan2(
            activeDirection.vector.dy,
            activeDirection.vector.dx
        )
        let inputAngle = atan2(vector.dy, vector.dx)
        let halfSectorWidth = halfSectorDegrees(for: activeDirection) * .pi / 180
        return absoluteAngularDistance(activeAngle, inputAngle)
            > halfSectorWidth + sectorBoundaryHysteresis
    }

    private static func forgivingDirection(for vector: CGVector) -> TubeGameDirection? {
        guard vector.dx.isFinite, vector.dy.isFinite else { return nil }
        let horizontal = abs(vector.dx)
        let vertical = abs(vector.dy)
        guard horizontal > 0 || vertical > 0 else { return nil }

        if horizontal <= vertical * cardinalSlope {
            return vector.dy < 0 ? .north : .south
        }
        if vertical <= horizontal * cardinalSlope {
            return vector.dx < 0 ? .west : .east
        }
        switch (vector.dx >= 0, vector.dy >= 0) {
        case (true, false): return .northEast
        case (true, true): return .southEast
        case (false, true): return .southWest
        case (false, false): return .northWest
        }
    }

    private static func halfSectorDegrees(for direction: TubeGameDirection) -> CGFloat {
        switch direction {
        case .north, .east, .south, .west:
            cardinalHalfSectorDegrees
        case .northEast, .southEast, .southWest, .northWest:
            diagonalHalfSectorDegrees
        }
    }

    private static func absoluteAngularDistance(
        _ lhs: CGFloat,
        _ rhs: CGFloat
    ) -> CGFloat {
        let fullTurn = CGFloat.pi * 2
        let rawDistance = abs(lhs - rhs).truncatingRemainder(dividingBy: fullTurn)
        return min(rawDistance, fullTurn - rawDistance)
    }
}

struct TubeGameGestureIntentTracker {
    private(set) var activeSwipeDirection: TubeGameDirection?

    mutating func updateSwipe(for translation: CGSize) -> TubeGameDirection? {
        guard let direction = TubeGameGestureIntent.swipeDirection(for: translation) else {
            return nil
        }
        if let activeSwipeDirection {
            guard direction != activeSwipeDirection,
                  TubeGameGestureIntent.shouldLeave(
                    activeSwipeDirection,
                    for: translation
                  )
            else { return nil }
        }

        activeSwipeDirection = direction
        return direction
    }

    mutating func finishSwipe(translation: CGSize) -> TubeGameDirection? {
        defer { activeSwipeDirection = nil }
        guard activeSwipeDirection == nil else { return nil }
        return TubeGameGestureIntent.swipeDirection(for: translation)
    }

    mutating func cancel() {
        activeSwipeDirection = nil
    }
}

@MainActor
private final class TubeGameGestureIntentTrackerBox {
    private var tracker = TubeGameGestureIntentTracker()

    var hasActiveSwipe: Bool {
        tracker.activeSwipeDirection != nil
    }

    func updateSwipe(for translation: CGSize) -> TubeGameDirection? {
        tracker.updateSwipe(for: translation)
    }

    func finishSwipe(translation: CGSize) -> TubeGameDirection? {
        tracker.finishSwipe(translation: translation)
    }

    func cancel() {
        tracker.cancel()
    }
}

enum TubeGameRouteFeedback {
    struct Marker: Equatable, Sendable {
        let point: CGPoint
        let tangent: CGVector
    }

    static func orientedGeometry(
        for edge: TubeGameRenderModel.RouteEdge,
        fromStationID: String,
        toStationID: String
    ) -> TubeGamePathGeometry? {
        if edge.fromStationID == fromStationID,
           edge.toStationID == toStationID {
            return edge.geometry
        }
        if edge.fromStationID == toStationID,
           edge.toStationID == fromStationID {
            return TubeGamePathGeometry(points: edge.geometry.points.reversed())
        }
        return nil
    }

    static func markers(
        along geometry: TubeGamePathGeometry,
        spacing: CGFloat,
        phase: CGFloat
    ) -> [Marker] {
        guard geometry.totalLength > 0,
              spacing.isFinite,
              spacing > 0,
              phase.isFinite
        else { return [] }

        var firstDistance = phase.truncatingRemainder(dividingBy: spacing)
        if firstDistance < 0 { firstDistance += spacing }
        if firstDistance < 4 { firstDistance += spacing }

        var result: [Marker] = []
        var distance = firstDistance
        while distance < geometry.totalLength - 2, result.count < 32 {
            if let marker = marker(in: geometry, at: distance) {
                result.append(marker)
            }
            distance += spacing
        }

        if result.isEmpty,
           geometry.totalLength >= 4,
           let midpoint = marker(in: geometry, at: geometry.totalLength / 2) {
            result.append(midpoint)
        }
        return result
    }

    private static func marker(
        in geometry: TubeGamePathGeometry,
        at distance: CGFloat
    ) -> Marker? {
        guard let point = geometry.point(atDistance: distance) else { return nil }
        let probe = min(2, max(0.25, geometry.totalLength / 100))
        guard let before = geometry.point(atDistance: max(0, distance - probe)),
              let after = geometry.point(
                atDistance: min(geometry.totalLength, distance + probe)
              )
        else { return nil }
        let delta = CGVector(dx: after.x - before.x, dy: after.y - before.y)
        let length = hypot(delta.dx, delta.dy)
        guard length > 0 else { return nil }
        return Marker(
            point: point,
            tangent: CGVector(dx: delta.dx / length, dy: delta.dy / length)
        )
    }
}

enum TubeGameStationLabelPresentation {
    static let lifetime: TimeInterval = 4
    /// Nearby stations can be consumed less than a second apart. Showing every
    /// four-second callout recreates the label clutter this feedback replaces,
    /// so a fresh station cleanly takes over from the previous one.
    static let maximumVisibleLabelCount = 1
    static let driftDistance: CGFloat = 26

    static func visibleConsumptions(
        _ consumptions: [TubeGameStationConsumption],
        at currentTime: TimeInterval
    ) -> [TubeGameStationConsumption] {
        let alive = consumptions
            .filter {
                isVisible(
                    eatenAt: $0.eatenAtElapsedTime,
                    currentTime: currentTime
                )
            }
            .sorted {
                if $0.eatenAtElapsedTime != $1.eatenAtElapsedTime {
                    return $0.eatenAtElapsedTime < $1.eatenAtElapsedTime
                }
                return $0.hubID < $1.hubID
            }
        return Array(alive.suffix(maximumVisibleLabelCount))
    }

    static func isVisible(
        eatenAt: TimeInterval,
        currentTime: TimeInterval
    ) -> Bool {
        let age = currentTime - eatenAt
        return age.isFinite && age >= 0 && age < lifetime
    }

    static func progress(
        eatenAt: TimeInterval,
        currentTime: TimeInterval
    ) -> Double {
        let age = currentTime - eatenAt
        guard age.isFinite else { return 1 }
        return min(1, max(0, age / lifetime))
    }

    static func opacity(
        eatenAt: TimeInterval,
        currentTime: TimeInterval
    ) -> Double {
        1 - progress(eatenAt: eatenAt, currentTime: currentTime)
    }

    static func verticalOffset(
        eatenAt: TimeInterval,
        currentTime: TimeInterval,
        reduceMotion: Bool
    ) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return -driftDistance * CGFloat(
            progress(eatenAt: eatenAt, currentTime: currentTime)
        )
    }
}

struct TubeGameMiniMap: View {
    @Environment(\.colorScheme) private var colorScheme

    let model: TubeGameRenderModel
    let snapshot: TubeGameSnapshot
    let camera: TubeGameCameraState

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let palette = BeckMapPalette.resolve(for: colorScheme)
            let transform = fittedTransform(in: size)
            var mapContext = context
            mapContext.concatenate(transform)
            let inverseScale = 1 / max(transform.a, 0.001)

            for segment in model.segments {
                mapContext.stroke(
                    TubeGamePlayfield.path(for: segment.geometry.points),
                    with: .color(Color.tubeLine(segment.lineID).opacity(0.62)),
                    style: StrokeStyle(
                        lineWidth: 0.8 * inverseScale,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }

            for hub in model.hubs where !snapshot.consumedHubIDs.contains(hub.id) {
                let radius = 0.9 * inverseScale
                mapContext.fill(
                    Path(ellipseIn: CGRect(
                        x: hub.point.x - radius,
                        y: hub.point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(Color(red: 1.0, green: 0.72, blue: 0.02))
                )
            }

            for train in snapshot.trains {
                let radius = 2.1 * inverseScale
                mapContext.fill(
                    Path(ellipseIn: CGRect(
                        x: train.position.x - radius,
                        y: train.position.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(.tubeLine(train.lineID))
                )
            }

            let playerRadius = 2.8 * inverseScale
            mapContext.fill(
                Path(ellipseIn: CGRect(
                    x: snapshot.player.position.x - playerRadius,
                    y: snapshot.player.position.y - playerRadius,
                    width: playerRadius * 2,
                    height: playerRadius * 2
                )),
                with: .color(palette.ink)
            )

            mapContext.stroke(
                Path(camera.visibleArtworkRect),
                with: .color(palette.ink.opacity(0.84)),
                lineWidth: inverseScale
            )
        }
        .padding(8)
        .frame(width: 132, height: 116)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Network overview, \(snapshot.remainingStationCount) stations remaining and \(snapshot.trains.count) trains"
        )
    }

    private func fittedTransform(in size: CGSize) -> CGAffineTransform {
        let availableWidth = max(1, size.width - 4)
        let availableHeight = max(1, size.height - 4)
        let scale = min(
            availableWidth / max(1, model.artworkSize.width),
            availableHeight / max(1, model.artworkSize.height)
        )
        return CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: (size.width - model.artworkSize.width * scale) / 2,
            ty: (size.height - model.artworkSize.height * scale) / 2
        )
    }
}

private extension BeckMapLabelAlignment {
    var unitPoint: UnitPoint {
        switch self {
        case .leading: .leading
        case .centre: .center
        case .trailing: .trailing
        }
    }
}
