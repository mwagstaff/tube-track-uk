import SwiftUI
import UIKit

struct SchematicMapView: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let graph: TubeGraph
    let resetToken: Int
    private let renderingGeometry: SchematicNetworkGeometry
    private let stationPlatformPoints: [String: [SchematicPoint]]
    private let cachedSegmentPaths: [String: Path]
    private let cachedSegmentBounds: [String: CGRect]
    private let cachedConnectorPaths: [Path]
    private let cachedConnectorBounds: [CGRect]
    private let cachedSupplementaryPaths: [Path]
    private let cachedSupplementaryBounds: [CGRect]
    private let cachedInterchangeConnectorPaths: [Path]
    private let cachedInterchangeConnectorBounds: [CGRect]
    private let lineSpatialIndex: SchematicLineSpatialIndex
    private let baseOrderedStations: [TubeStation]

    @State private var cameraScale: CGFloat = 0.72
    @State private var cameraOffset = CGSize(width: -220, height: -65)
    @State private var cameraInitialized = false
    @State private var panStartOffset: CGSize?
    @State private var pinchStartScale: CGFloat?
    @State private var pinchMapPoint: CGPoint?

    private let mapCentre = CGPoint(x: 712, y: 480)
    private let routesOnlyDebugEnabled = ProcessInfo.processInfo.arguments.contains("--schematic-routes-only")
    private static let preferredCornerRadius = 28.0
    private static let maximumCameraScale: CGFloat = 2.4
    private static let allLabelsCameraScale: CGFloat = 2.2
    private static let majorLabels: Set<String> = [
        "Baker Street", "Bank", "Bond Street", "Canary Wharf", "Ealing Broadway",
        "Earl's Court", "Embankment", "Euston", "Finsbury Park", "Hammersmith",
        "King's Cross St. Pancras", "Liverpool Street", "London Bridge", "Oxford Circus",
        "Paddington", "Stratford", "Victoria", "Waterloo", "Wembley Park", "West Ham",
        "Whitechapel",
    ]
    private static let centralLabels: Set<String> = [
        "Paddington", "Baker Street", "Camden Town", "Euston",
        "King's Cross St. Pancras", "Farringdon", "Moorgate", "Liverpool Street",
        "Whitechapel", "Stratford", "Notting Hill Gate", "Bond Street",
        "Oxford Circus", "Tottenham Court Road", "Holborn", "Bank", "Tower Hill",
        "Earl's Court", "Victoria", "Green Park", "Piccadilly Circus",
        "Leicester Square", "Charing Cross", "Westminster", "Embankment",
        "Blackfriars", "Waterloo", "London Bridge", "Canary Wharf",
    ]

    init(graph: TubeGraph, resetToken: Int) {
        self.graph = graph
        self.resetToken = resetToken
        let laneOffsets = Self.makeLaneOffsets(for: graph)
        let renderingGeometry = SchematicNetworkGeometry(
            graph: graph,
            laneOffsets: laneOffsets,
            laneTranslationOverrides: Self.makeLaneTranslationOverrides(for: graph),
            preferredCornerRadius: Self.preferredCornerRadius
        )
        self.renderingGeometry = renderingGeometry
        let stationPlatformPoints = Self.makeStationPlatformPoints(
            graph: graph,
            renderingGeometry: renderingGeometry
        )
        self.stationPlatformPoints = stationPlatformPoints
        let segmentPaths = renderingGeometry.segmentPaths.mapValues(Self.makeMapPath)
        let connectorPaths = renderingGeometry.connectors.map { Self.makeMapPath($0.path) }
        let supplementaryPaths = renderingGeometry.supplementaryRoutes.map { Self.makeMapPath($0.path) }
        self.cachedSegmentPaths = segmentPaths
        self.cachedSegmentBounds = segmentPaths.mapValues(Self.expandedDrawingBounds)
        self.cachedConnectorPaths = connectorPaths
        self.cachedConnectorBounds = connectorPaths.map(Self.expandedDrawingBounds)
        self.cachedSupplementaryPaths = supplementaryPaths
        self.cachedSupplementaryBounds = supplementaryPaths.map(Self.expandedDrawingBounds)
        let interchangeConnectorPaths = Self.makeInterchangeConnectorPaths(
            graph: graph,
            stationPlatformPoints: stationPlatformPoints
        )
        self.cachedInterchangeConnectorPaths = interchangeConnectorPaths
        self.cachedInterchangeConnectorBounds = interchangeConnectorPaths.map(Self.expandedDrawingBounds)
        self.lineSpatialIndex = SchematicLineSpatialIndex(
            bounds: Self.makeLineCollisionBounds(renderingGeometry: renderingGeometry)
        )
        let majorLabels = Self.majorLabels
        let centralLabels = Self.centralLabels
        self.baseOrderedStations = graph.stations.sorted { left, right in
            func priority(_ station: TubeStation) -> Int {
                if majorLabels.contains(station.name) { return 2 }
                if centralLabels.contains(station.name) { return 1 }
                return 0
            }
            let leftPriority = priority(left)
            let rightPriority = priority(right)
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            return left.name < right.name
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TimelineView(.animation(minimumInterval: appState.showLiveTrains ? 1 / 12 : 1, paused: !appState.showLiveTrains || reduceMotion)) { timeline in
                    Canvas { context, size in
                        drawMap(context: &context, size: size, date: timeline.date)
                    }
                    .allowsHitTesting(false)
                }

                SchematicGestureSurface(
                    onPan: handlePan,
                    onPinch: handlePinch,
                    onTap: { location in
                        selectMapElement(at: location, in: proxy.size)
                    }
                )
                .accessibilityHidden(true)
            }
            .accessibilityRepresentation {
                stationAccessibilityList
            }
            .task(id: proxy.size) {
                guard !cameraInitialized, proxy.size.width > 0, proxy.size.height > 0 else { return }
                await Task.yield()
                resetCamera(in: proxy.size)
                cameraInitialized = true
                if !appState.activeAffectedStationIDs.isEmpty {
                    focus(on: appState.activeAffectedStationIDs, in: proxy.size)
                }
            }
            .onChange(of: resetToken) { _, _ in
                withAnimation(.smooth(duration: 0.55)) {
                    resetCamera(in: proxy.size)
                }
            }
            .onChange(of: appState.selectedDisruptionID) { _, _ in
                focus(on: appState.activeAffectedStationIDs, in: proxy.size)
            }
            .onChange(of: appState.focusedStationIDs) { _, stations in
                focus(on: stations, in: proxy.size)
            }
        }
    }

    private func handlePan(translation: CGSize, phase: SchematicGesturePhase) {
        switch phase {
        case .began:
            panStartOffset = cameraOffset
        case .changed:
            guard hypot(translation.width, translation.height) >= 6 else { return }
            let start = panStartOffset ?? cameraOffset
            panStartOffset = start
            cameraOffset = CGSize(
                width: start.width + translation.width,
                height: start.height + translation.height
            )
        case .ended:
            panStartOffset = nil
        }
    }

    private func handlePinch(magnification: CGFloat, location: CGPoint, phase: SchematicGesturePhase) {
        switch phase {
        case .began:
            pinchStartScale = cameraScale
            pinchMapPoint = CGPoint(
                x: (location.x - cameraOffset.width) / cameraScale,
                y: (location.y - cameraOffset.height) / cameraScale
            )
        case .changed:
            guard let startScale = pinchStartScale, let mapPoint = pinchMapPoint else { return }
            let nextScale = min(Self.maximumCameraScale, max(0.32, startScale * magnification))
            cameraScale = nextScale
            // Preserve the map point beneath the fingers. Using the recognizer's
            // current centroid also supports natural two-finger translation.
            cameraOffset = CGSize(
                width: location.x - mapPoint.x * nextScale,
                height: location.y - mapPoint.y * nextScale
            )
        case .ended:
            pinchStartScale = nil
            pinchMapPoint = nil
            panStartOffset = nil
        }
    }

    private var stationAccessibilityList: some View {
        ScrollView {
            LazyVStack {
                ForEach(graph.stations) { station in
                    Button("\(station.name), \(station.lineIDs.map(\.displayName).joined(separator: ", "))") {
                        appState.select(station: station)
                    }
                }
            }
        }
        .accessibilityLabel("Interactive London Underground map")
    }

    private func resetCamera(in size: CGSize) {
        cameraScale = max(0.48, min(0.68, size.width / 750))
        cameraOffset = CGSize(
            width: size.width / 2 - mapCentre.x * cameraScale,
            height: size.height / 2 - mapCentre.y * cameraScale
        )
    }

    private func focus(on stationIDs: Set<String>, in size: CGSize) {
        let stations = graph.stations.filter { stationIDs.contains($0.id) }
        guard !stations.isEmpty else { return }
        let xValues = stations.map(\.schematicX)
        let yValues = stations.map(\.schematicY)
        guard let minX = xValues.min(), let maxX = xValues.max(),
              let minY = yValues.min(), let maxY = yValues.max() else { return }
        let width = max(120, maxX - minX)
        let height = max(120, maxY - minY)
        let nextScale = min(1.45, max(0.52, min((size.width - 70) / width, (size.height - 260) / height)))
        let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        withAnimation(.smooth(duration: 0.65)) {
            cameraScale = nextScale
            cameraOffset = CGSize(
                width: size.width / 2 - centre.x * nextScale,
                height: size.height / 2 - centre.y * nextScale - 35
            )
        }
    }

    private func screenPoint(_ point: SchematicPoint) -> CGPoint {
        CGPoint(
            x: point.x * cameraScale + cameraOffset.width,
            y: point.y * cameraScale + cameraOffset.height
        )
    }

    private func stationPoint(_ station: TubeStation) -> CGPoint {
        let points = stationPlatformPoints[station.id] ?? [station.schematicPoint]
        let centre = points.reduce(SchematicPoint(x: 0, y: 0)) { partial, point in
            SchematicPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let divisor = Double(max(1, points.count))
        return screenPoint(SchematicPoint(x: centre.x / divisor, y: centre.y / divisor))
    }

    private func drawMap(context: inout GraphicsContext, size: CGSize, date: Date) {
        let affectedSegments = appState.activeAffectedSegmentIDs
        let issuesMode = appState.disruptionDisplayMode == .issues && !affectedSegments.isEmpty
        let visibleMapRect = visibleMapRect(in: size).insetBy(dx: -32, dy: -32)
        var mapContext = context
        mapContext.concatenate(CGAffineTransform(
            a: cameraScale,
            b: 0,
            c: 0,
            d: cameraScale,
            tx: cameraOffset.width,
            ty: cameraOffset.height
        ))

        for segment in graph.segments {
            guard let path = cachedSegmentPaths[segment.id],
                  cachedSegmentBounds[segment.id]?.intersects(visibleMapRect) == true else { continue }
            let isAffected = affectedSegments.contains(segment.id)
            let isSelectedLine = appState.selectedLineID == nil || appState.selectedLineID == segment.lineID
            let muted = (issuesMode && !isAffected) || !isSelectedLine
            strokeRoute(
                path,
                lineID: segment.lineID,
                isAffected: isAffected,
                muted: muted,
                issuesMode: issuesMode,
                context: &mapContext
            )
        }

        for (index, route) in renderingGeometry.supplementaryRoutes.enumerated() {
            guard cachedSupplementaryPaths.indices.contains(index),
                  cachedSupplementaryBounds[index].intersects(visibleMapRect) else { continue }
            let isSelectedLine = appState.selectedLineID == nil || appState.selectedLineID == route.lineID
            strokeRoute(
                cachedSupplementaryPaths[index],
                lineID: route.lineID,
                isAffected: false,
                muted: issuesMode || !isSelectedLine,
                issuesMode: issuesMode,
                context: &mapContext
            )
        }

        // Curves that pass through stations are separate path geometry. The
        // station is merely overlaid later; it never hides a line-to-line join.
        for (index, connector) in renderingGeometry.connectors.enumerated() {
            guard cachedConnectorPaths.indices.contains(index),
                  cachedConnectorBounds[index].intersects(visibleMapRect) else { continue }
            let isAffected = affectedSegments.contains(connector.incomingSegmentID)
                || affectedSegments.contains(connector.outgoingSegmentID)
            let isSelectedLine = appState.selectedLineID == nil || appState.selectedLineID == connector.lineID
            let muted = (issuesMode && !isAffected) || !isSelectedLine
            strokeRoute(
                cachedConnectorPaths[index],
                lineID: connector.lineID,
                isAffected: isAffected,
                muted: muted,
                issuesMode: issuesMode,
                context: &mapContext
            )
        }

        if !routesOnlyDebugEnabled {
            drawStationInfrastructure(context: &mapContext, visibleMapRect: visibleMapRect)
            drawStationLabels(context: &context, size: size)
            if appState.showLiveTrains {
                drawTrains(context: &mapContext, date: date, visibleMapRect: visibleMapRect)
            }
        }
    }

    private func strokeRoute(
        _ path: Path,
        lineID: TubeLineID,
        isAffected: Bool,
        muted: Bool,
        issuesMode: Bool,
        context: inout GraphicsContext
    ) {
        if isAffected && issuesMode {
            context.stroke(path, with: .color(.white.opacity(colorScheme == .dark ? 0.75 : 1)), lineWidth: 11)
            context.stroke(path, with: .color(.red.opacity(0.25)), lineWidth: 16)
        }
        context.stroke(
            path,
            with: .color(
                muted
                    ? Color.secondary.opacity(issuesMode ? 0.26 : 0.18)
                    : displayColor(for: lineID)
            ),
            style: StrokeStyle(
                lineWidth: isAffected ? 7 : 5.5,
                // Square caps overlap the separately stroked tangent connector
                // by half a line width, preventing antialias seams. They do not
                // soften direction changes; those are cubic path geometry.
                lineCap: .square,
                lineJoin: .miter
            )
        )
    }

    private func drawInterchangeConnectors(
        context: inout GraphicsContext,
        visibleMapRect: CGRect
    ) {
        let outline = colorScheme == .dark ? SchematicMapPalette.darkStationOutline : Color.black
        let fill = colorScheme == .dark ? SchematicMapPalette.darkStationFill : Color.white
        let widthCompensation = max(0.72, cameraScale) / cameraScale
        for (index, path) in cachedInterchangeConnectorPaths.enumerated()
        where cachedInterchangeConnectorBounds[index].intersects(visibleMapRect) {
            context.stroke(
                path,
                with: .color(outline),
                style: StrokeStyle(lineWidth: 5.2 * widthCompensation, lineCap: .round)
            )
            context.stroke(
                path,
                with: .color(fill),
                style: StrokeStyle(lineWidth: 2.2 * widthCompensation, lineCap: .round)
            )
        }
    }

    private func drawStationInfrastructure(
        context: inout GraphicsContext,
        visibleMapRect: CGRect
    ) {
        let selectedID = appState.selectedStationID
        let focused = appState.activeAffectedStationIDs
        let issuesMode = appState.disruptionDisplayMode == .issues && !appState.activeAffectedSegmentIDs.isEmpty

        drawInterchangeConnectors(context: &context, visibleMapRect: visibleMapRect)

        let sizeCompensation = max(0.72, cameraScale) / cameraScale
        for station in graph.stations {
            let platformPoints = stationPlatformPoints[station.id] ?? [station.schematicPoint]
            guard platformPoints.contains(where: { visibleMapRect.contains(CGPoint($0)) }) else { continue }
            let selected = selectedID == station.id
            let affected = focused.contains(station.id)
            let interchangeSize = min(18, 11 + CGFloat(station.lineIDs.count) * 1.5)
            let diameter = (selected ? 18 : station.interchange ? interchangeSize : 6.5) * sizeCompensation
            let fill: Color = affected && issuesMode
                ? .red
                : colorScheme == .dark ? SchematicMapPalette.darkStationFill : .white
            let outline: Color = selected
                ? .blue
                : affected && issuesMode
                    ? .red
                    : colorScheme == .dark ? SchematicMapPalette.darkStationOutline : .black
            let outlineWidth = (selected ? 3 : station.interchange ? 2 : 1.2) / cameraScale

            for platformPoint in platformPoints {
                let point = CGPoint(platformPoint)
                guard visibleMapRect.contains(point) else { continue }
                let rect = CGRect(
                    x: point.x - diameter / 2,
                    y: point.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                let marker = Path(ellipseIn: rect)
                context.fill(marker, with: .color(fill))
                context.stroke(marker, with: .color(outline), lineWidth: outlineWidth)
            }
        }
    }

    private func drawStationLabels(context: inout GraphicsContext, size: CGSize) {
        let selectedID = appState.selectedStationID
        let focused = appState.activeAffectedStationIDs
        let issuesMode = appState.disruptionDisplayMode == .issues && !appState.activeAffectedSegmentIDs.isEmpty

        var occupiedLabelFrames: [CGRect] = []
        let labelViewport = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let majorLabels = Self.majorLabels
        let centralLabels = Self.centralLabels
        var promotedStationIDs = focused
        if let selectedID { promotedStationIDs.insert(selectedID) }
        let orderedStations = baseOrderedStations.filter { promotedStationIDs.contains($0.id) }
            + baseOrderedStations.filter { !promotedStationIDs.contains($0.id) }

        for station in orderedStations {
            let selected = selectedID == station.id

            let importantForIssue = issuesMode && focused.contains(station.id)
            let showEveryVisibleLabel = Self.showsAllStationLabels(at: cameraScale)
                && (stationPlatformPoints[station.id] ?? [station.schematicPoint]).contains { platformPoint in
                    labelViewport.insetBy(dx: -24, dy: -24).contains(screenPoint(platformPoint))
                }
            let shouldLabel = selected || importantForIssue
                || (majorLabels.contains(station.name) && cameraScale >= 0.52)
                || (centralLabels.contains(station.name) && cameraScale >= 0.50)
                || (station.interchange && cameraScale >= 1.12)
                || showEveryVisibleLabel
            guard shouldLabel else { continue }
            let point = stationPoint(station)
            guard selected || importantForIssue
                    || labelViewport.insetBy(dx: -220, dy: -40).contains(point) else { continue }
            let width = max(34, CGFloat(station.name.count) * (selected ? 6.5 : 4.8))
            let height: CGFloat = selected ? 18 : 14
            let candidateFrames = [
                CGRect(x: point.x + 8, y: point.y - height - 10, width: width, height: height),
                CGRect(x: point.x + 8, y: point.y + 10, width: width, height: height),
                CGRect(x: point.x - width - 8, y: point.y - height - 10, width: width, height: height),
                CGRect(x: point.x - width - 8, y: point.y + 10, width: width, height: height),
                CGRect(x: point.x - width / 2, y: point.y - height - 12, width: width, height: height),
                CGRect(x: point.x - width / 2, y: point.y + 12, width: width, height: height),
            ]
            let lineFreeFrame = candidateFrames.first { candidate in
                let padded = candidate.insetBy(dx: -4, dy: -3)
                return labelViewport.contains(candidate)
                    && !occupiedLabelFrames.contains(where: { $0.intersects(padded) })
                    && !lineSpatialIndex.intersects(mapRect(forScreenRect: candidate))
            }
            let collisionFreeFrame = candidateFrames.first { candidate in
                let padded = candidate.insetBy(dx: -4, dy: -3)
                return labelViewport.contains(candidate)
                    && !occupiedLabelFrames.contains(where: { $0.intersects(padded) })
            }
            let leastObstructedFrame = candidateFrames
                .filter(labelViewport.contains)
                .min { left, right in
                    labelObstructionScore(left, occupiedLabels: occupiedLabelFrames)
                        < labelObstructionScore(right, occupiedLabels: occupiedLabelFrames)
                }
            let fallback = candidateFrames[0]
            let clampedVisibleFrame = CGRect(
                x: min(max(fallback.minX, labelViewport.minX), labelViewport.maxX - fallback.width),
                y: min(max(fallback.minY, labelViewport.minY), labelViewport.maxY - fallback.height),
                width: fallback.width,
                height: fallback.height
            )
            let labelFrame = lineFreeFrame
                ?? ((selected || importantForIssue || centralLabels.contains(station.name) || showEveryVisibleLabel) ? collisionFreeFrame : nil)
                ?? (showEveryVisibleLabel ? (leastObstructedFrame ?? clampedVisibleFrame) : nil)
                ?? ((selected || importantForIssue) ? candidateFrames[0] : nil)

            if shouldLabel, let labelFrame {
                let backing = labelFrame.insetBy(dx: -2.5, dy: -1.5)
                context.fill(
                    Path(roundedRect: backing, cornerRadius: 3),
                    with: .color(
                        colorScheme == .dark
                            ? SchematicMapPalette.darkBackground.opacity(0.90)
                            : Color(.systemBackground).opacity(0.82)
                    )
                )
                var text = context.resolve(Text(station.name).font(.system(size: selected ? 12 : 8.5, weight: .semibold)))
                let primaryLabel = selected || importantForIssue || majorLabels.contains(station.name)
                text.shading = .color(
                    colorScheme == .dark
                        ? primaryLabel
                            ? SchematicMapPalette.darkPrimaryLabel
                            : SchematicMapPalette.darkSecondaryLabel
                        : .tubeBlue
                )
                context.draw(text, at: CGPoint(x: labelFrame.minX, y: labelFrame.midY), anchor: .leading)
                occupiedLabelFrames.append(labelFrame)
            }
        }
    }

    private func drawTrains(
        context: inout GraphicsContext,
        date: Date,
        visibleMapRect: CGRect
    ) {
        let segments = graph.segmentsByID
        let symbol = context.resolve(Image(systemName: "tram.fill"))
        let markerSize = 18 / cameraScale
        for train in appState.liveTrains {
            guard let segment = segments[train.segmentID],
                  let routePoints = renderingGeometry.segmentPaths[segment.id]?.sampledPoints,
                  let point = interpolatedPoint(
                along: routePoints,
                progress: train.projectedProgress(at: date)
            ) else { continue }

            let mapPoint = CGPoint(point)
            guard visibleMapRect.contains(mapPoint) else { continue }
            let rect = CGRect(
                x: mapPoint.x - markerSize / 2,
                y: mapPoint.y - markerSize / 2,
                width: markerSize,
                height: markerSize
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: 5 / cameraScale),
                with: .color(displayColor(for: train.lineID))
            )
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 5 / cameraScale),
                with: .color(.white),
                lineWidth: 2 / cameraScale
            )
            context.draw(symbol, in: rect.insetBy(dx: 4 / cameraScale, dy: 4 / cameraScale))
        }
    }

    private func labelObstructionScore(
        _ frame: CGRect,
        occupiedLabels: [CGRect]
    ) -> Int {
        let occupiedCount = occupiedLabels.reduce(0) { count, occupied in
            count + (occupied.intersects(frame.insetBy(dx: -4, dy: -3)) ? 1 : 0)
        }
        let crossedLines = lineSpatialIndex.intersectionCount(in: mapRect(forScreenRect: frame))
        return occupiedCount * 100 + crossedLines
    }

    private func selectMapElement(at location: CGPoint, in size: CGSize) {
        if let station = graph.stations.min(by: {
            distanceToStation($0, from: location) < distanceToStation($1, from: location)
        }), distanceToStation(station, from: location) <= 24 {
            withAnimation(.spring(duration: 0.35)) {
                appState.select(station: station)
            }
            return
        }

        var nearest: (segment: TubeSegment, distance: CGFloat)?
        for segment in graph.segments {
            let points = (renderingGeometry.segmentPaths[segment.id]?.sampledPoints ?? segment.schematicPoints).map(screenPoint)
            for pair in zip(points, points.dropFirst()) {
                let candidate = distanceFromPoint(location, to: pair.0, and: pair.1)
                if candidate < (nearest?.distance ?? .greatestFiniteMagnitude) {
                    nearest = (segment, candidate)
                }
            }
        }
        if let nearest, nearest.distance <= 15 {
            withAnimation(.easeInOut(duration: 0.3)) {
                appState.selectedLineID = nearest.segment.lineID
                appState.selectedStationID = nil
            }
        } else {
            appState.clearMapSelection()
        }
    }

    private func distanceToStation(_ station: TubeStation, from location: CGPoint) -> CGFloat {
        (stationPlatformPoints[station.id] ?? [station.schematicPoint])
            .map { distance(screenPoint($0), location) }
            .min() ?? .greatestFiniteMagnitude
    }

    private func displayColor(for line: TubeLineID) -> Color {
        return .tubeLine(line)
    }

    private func visibleMapRect(in size: CGSize) -> CGRect {
        CGRect(
            x: -cameraOffset.width / cameraScale,
            y: -cameraOffset.height / cameraScale,
            width: size.width / cameraScale,
            height: size.height / cameraScale
        )
    }

    private func mapRect(forScreenRect rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - cameraOffset.width) / cameraScale,
            y: (rect.minY - cameraOffset.height) / cameraScale,
            width: rect.width / cameraScale,
            height: rect.height / cameraScale
        ).insetBy(dx: -4 / cameraScale, dy: -4 / cameraScale)
    }

    private static func makeMapPath(_ geometry: RoundedSchematicPath) -> Path {
        var path = Path()
        path.move(to: CGPoint(geometry.start))
        for element in geometry.elements {
            switch element {
            case let .line(to):
                path.addLine(to: CGPoint(to))
            case let .curve(to, control1, control2):
                path.addCurve(
                    to: CGPoint(to),
                    control1: CGPoint(control1),
                    control2: CGPoint(control2)
                )
            }
        }
        return path
    }

    private static func expandedDrawingBounds(_ path: Path) -> CGRect {
        path.boundingRect.insetBy(dx: -20, dy: -20)
    }

    static func makeLineCollisionBounds(
        renderingGeometry: SchematicNetworkGeometry
    ) -> [CGRect] {
        let paths = Array(renderingGeometry.segmentPaths.values)
            + renderingGeometry.connectors.map(\.path)
            + renderingGeometry.supplementaryRoutes.map(\.path)
        return paths.flatMap { geometry in
            zip(geometry.sampledPoints, geometry.sampledPoints.dropFirst()).map { start, end in
                CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                ).insetBy(dx: -0.5, dy: -0.5)
            }
        }
    }

    private static func makeInterchangeConnectorPaths(
        graph: TubeGraph,
        stationPlatformPoints: [String: [SchematicPoint]]
    ) -> [Path] {
        let linkedStationGroups = [
            ["940GZZLUPAC", "940GZZLUPAH"], // Paddington's two station records
        ]
        var linkedStationIDs: Set<String> = []
        var paths: [Path] = []

        func appendNetwork(_ schematicPoints: [SchematicPoint]) {
            let points = schematicPoints.map(CGPoint.init)
            guard points.count > 1 else { return }
            var path = Path()
            for (start, end) in minimumSpanningConnectorPairs(points) {
                path.move(to: start)
                path.addLine(to: end)
            }
            paths.append(path)
        }

        for stationIDs in linkedStationGroups {
            appendNetwork(stationIDs.flatMap { stationPlatformPoints[$0] ?? [] })
            linkedStationIDs.formUnion(stationIDs)
        }
        for station in graph.stations where !linkedStationIDs.contains(station.id) {
            appendNetwork(stationPlatformPoints[station.id] ?? [])
        }
        return paths
    }

    private static func minimumSpanningConnectorPairs(
        _ points: [CGPoint]
    ) -> [(CGPoint, CGPoint)] {
        guard points.count > 1 else { return [] }
        var connected: Set<Int> = [0]
        var pairs: [(CGPoint, CGPoint)] = []
        while connected.count < points.count {
            var best: (from: Int, to: Int, distance: CGFloat)?
            for from in connected {
                for to in points.indices where !connected.contains(to) {
                    let candidate = hypot(
                        points[from].x - points[to].x,
                        points[from].y - points[to].y
                    )
                    if candidate < (best?.distance ?? .greatestFiniteMagnitude) {
                        best = (from, to, candidate)
                    }
                }
            }
            guard let best else { break }
            connected.insert(best.to)
            pairs.append((points[best.from], points[best.to]))
        }
        return pairs
    }

    private static func makeLaneOffsets(for graph: TubeGraph) -> [String: Double] {
        let groups = Dictionary(grouping: graph.segments) { segment in
            [segment.fromStationID, segment.toStationID].sorted().joined(separator: ":")
        }
        var result: [String: Double] = [:]
        for siblings in groups.values where siblings.count > 1 {
            let ordered = siblings.sorted { $0.lineID.rawValue < $1.lineID.rawValue }
            let midpoint = Double(ordered.count - 1) / 2
            for (index, segment) in ordered.enumerated() {
                result[segment.id] = (Double(index) - midpoint) * 7
            }
        }
        return result
    }

    /// Keep the District and Piccadilly corridors independently readable from
    /// Hammersmith through Earl's Court. These are geometry translations, not
    /// stroke joins: both routes retain their own continuous schematic axis.
    static func makeLaneTranslationOverrides(for graph: TubeGraph) -> [String: SchematicPoint] {
        let districtPairs: Set<String> = [
            "940GZZLUHSD:940GZZLUBSC",
            "940GZZLUBSC:940GZZLUWKN",
            "940GZZLUWKN:940GZZLUECT",
            "940GZZLUECT:940GZZLUGTR",
        ]
        let piccadillyPairs: Set<String> = [
            "940GZZLUHSD:940GZZLUBSC",
            "940GZZLUBSC:940GZZLUECT",
            "940GZZLUECT:940GZZLUGTR",
        ]

        var result: [String: SchematicPoint] = [:]
        for segment in graph.segments {
            let forward = "\(segment.fromStationID):\(segment.toStationID)"
            let reverse = "\(segment.toStationID):\(segment.fromStationID)"
            if segment.lineID == .district,
               districtPairs.contains(forward) || districtPairs.contains(reverse) {
                result[segment.id] = SchematicPoint(x: 0, y: 6)
            } else if segment.lineID == .piccadilly,
                      piccadillyPairs.contains(forward) || piccadillyPairs.contains(reverse) {
                result[segment.id] = SchematicPoint(x: 0, y: -6)
            }
        }
        for segmentID in [
            "circle:940GZZLUBWT:940GZZLUPAC",
            "circle:940GZZLUERC:940GZZLUPAC",
        ] {
            result[segmentID] = SchematicPoint(x: 0, y: -3.5)
        }
        for segmentID in [
            "district:940GZZLUBWT:940GZZLUPAC",
            "district:940GZZLUERC:940GZZLUPAC",
        ] {
            result[segmentID] = SchematicPoint(x: 0, y: 3.5)
        }
        return result
    }

    static func makeStationPlatformPoints(
        graph: TubeGraph,
        renderingGeometry: SchematicNetworkGeometry
    ) -> [String: [SchematicPoint]] {
        var result: [String: [SchematicPoint]] = [:]
        for segment in graph.segments {
            guard let endpoints = renderingGeometry.renderedStationPoints[segment.id] else { continue }
            for stationID in [segment.fromStationID, segment.toStationID] {
                guard let point = endpoints[stationID] else { continue }
                let isDuplicate = result[stationID, default: []].contains { existing in
                    hypot(existing.x - point.x, existing.y - point.y) < 0.75
                }
                if !isDuplicate {
                    result[stationID, default: []].append(point)
                }
            }
        }
        for station in graph.stations where result[station.id]?.isEmpty != false {
            result[station.id] = [station.schematicPoint]
        }
        return result
    }

    static func showsAllStationLabels(at cameraScale: CGFloat) -> Bool {
        cameraScale >= allLabelsCameraScale
    }

    private func interpolatedPoint(along points: [SchematicPoint], progress: Double) -> SchematicPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let target = lengths.reduce(0, +) * min(1, max(0, progress))
        var travelled = 0.0
        for (index, length) in lengths.enumerated() {
            if travelled + length >= target, length > 0 {
                let fraction = (target - travelled) / length
                return SchematicPoint(
                    x: points[index].x + (points[index + 1].x - points[index].x) * fraction,
                    y: points[index].y + (points[index + 1].y - points[index].y) * fraction
                )
            }
            travelled += length
        }
        return points.last
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func distanceFromPoint(_ point: CGPoint, to start: CGPoint, and end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard dx != 0 || dy != 0 else { return distance(point, start) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
        return distance(point, CGPoint(x: start.x + t * dx, y: start.y + t * dy))
    }
}

struct SchematicLineSpatialIndex {
    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    private let cellSize: CGFloat
    private let bounds: [CGRect]
    private let cells: [Cell: [Int]]

    init(bounds: [CGRect], cellSize: CGFloat = 80) {
        self.cellSize = cellSize
        self.bounds = bounds
        var cells: [Cell: [Int]] = [:]
        for (index, rect) in bounds.enumerated() where !rect.isNull && !rect.isInfinite {
            for cell in Self.cells(overlapping: rect, cellSize: cellSize) {
                cells[cell, default: []].append(index)
            }
        }
        self.cells = cells
    }

    var totalBoundsCount: Int { bounds.count }

    func intersects(_ rect: CGRect) -> Bool {
        for cell in Self.cells(overlapping: rect, cellSize: cellSize) {
            for index in cells[cell] ?? [] where bounds[index].intersects(rect) {
                return true
            }
        }
        return false
    }

    func intersectionCount(in rect: CGRect) -> Int {
        var matchingIndices: Set<Int> = []
        for cell in Self.cells(overlapping: rect, cellSize: cellSize) {
            for index in cells[cell] ?? [] where bounds[index].intersects(rect) {
                matchingIndices.insert(index)
            }
        }
        return matchingIndices.count
    }

    func candidateCount(in rect: CGRect) -> Int {
        var indices: Set<Int> = []
        for cell in Self.cells(overlapping: rect, cellSize: cellSize) {
            indices.formUnion(cells[cell] ?? [])
        }
        return indices.count
    }

    private static func cells(overlapping rect: CGRect, cellSize: CGFloat) -> [Cell] {
        guard !rect.isNull, !rect.isInfinite, cellSize > 0 else { return [] }
        let minX = Int(floor(rect.minX / cellSize))
        let maxX = Int(floor(rect.maxX / cellSize))
        let minY = Int(floor(rect.minY / cellSize))
        let maxY = Int(floor(rect.maxY / cellSize))
        return (minX ... maxX).flatMap { x in
            (minY ... maxY).map { y in Cell(x: x, y: y) }
        }
    }
}

private extension CGPoint {
    init(_ point: SchematicPoint) {
        self.init(x: CGFloat(point.x), y: CGFloat(point.y))
    }
}

private enum SchematicGesturePhase {
    case began
    case changed
    case ended
}

/// UIKit gives us explicit touch-count ownership: a one-finger recognizer pans,
/// while two fingers exclusively control anchored magnification. This avoids the
/// first finger of a pinch being interpreted as a map drag.
private struct SchematicGestureSurface: UIViewRepresentable {
    let onPan: (CGSize, SchematicGesturePhase) -> Void
    let onPinch: (CGFloat, CGPoint, SchematicGesturePhase) -> Void
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: pan)
        tap.require(toFail: pinch)

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SchematicGestureSurface

        init(parent: SchematicGestureSurface) {
            self.parent = parent
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            parent.onPan(
                CGSize(width: translation.x, height: translation.y),
                phase(for: recognizer.state)
            )
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent.onPinch(recognizer.scale, recognizer.location(in: view), phase(for: recognizer.state))
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            parent.onTap(recognizer.location(in: view))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        private func phase(for state: UIGestureRecognizer.State) -> SchematicGesturePhase {
            switch state {
            case .began: .began
            case .changed: .changed
            default: .ended
            }
        }
    }
}
