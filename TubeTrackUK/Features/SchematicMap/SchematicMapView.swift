import SwiftUI
import UIKit

struct SchematicMapView: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let graph: TubeGraph
    let resetToken: Int
    private let renderingGeometry: SchematicNetworkGeometry

    @State private var cameraScale: CGFloat = 0.72
    @State private var cameraOffset = CGSize(width: -220, height: -65)
    @State private var cameraInitialized = false
    @State private var panStartOffset: CGSize?
    @State private var pinchStartScale: CGFloat?
    @State private var pinchMapPoint: CGPoint?

    private let mapCentre = CGPoint(x: 712, y: 480)
    private let routesOnlyDebugEnabled = ProcessInfo.processInfo.arguments.contains("--schematic-routes-only")
    private static let preferredCornerRadius = 28.0

    init(graph: TubeGraph, resetToken: Int) {
        self.graph = graph
        self.resetToken = resetToken
        let laneOffsets = Self.makeLaneOffsets(for: graph)
        self.renderingGeometry = SchematicNetworkGeometry(
            graph: graph,
            laneOffsets: laneOffsets,
            preferredCornerRadius: Self.preferredCornerRadius
        )
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
            let nextScale = min(2.4, max(0.32, startScale * magnification))
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
        screenPoint(station.schematicPoint)
    }

    private func drawMap(context: inout GraphicsContext, size: CGSize, date: Date) {
        let affectedSegments = appState.activeAffectedSegmentIDs
        let issuesMode = appState.disruptionDisplayMode == .issues && !affectedSegments.isEmpty

        for segment in graph.segments {
            guard let geometry = renderingGeometry.segmentPaths[segment.id] else { continue }
            let path = path(for: geometry)
            let isAffected = affectedSegments.contains(segment.id)
            let isSelectedLine = appState.selectedLineID == nil || appState.selectedLineID == segment.lineID
            let muted = (issuesMode && !isAffected) || !isSelectedLine
            strokeRoute(
                path,
                lineID: segment.lineID,
                isAffected: isAffected,
                muted: muted,
                issuesMode: issuesMode,
                context: &context
            )
        }

        // Curves that pass through stations are separate path geometry. The
        // station is merely overlaid later; it never hides a line-to-line join.
        for connector in renderingGeometry.connectors {
            let isAffected = affectedSegments.contains(connector.incomingSegmentID)
                || affectedSegments.contains(connector.outgoingSegmentID)
            let isSelectedLine = appState.selectedLineID == nil || appState.selectedLineID == connector.lineID
            let muted = (issuesMode && !isAffected) || !isSelectedLine
            strokeRoute(
                path(for: connector.path),
                lineID: connector.lineID,
                isAffected: isAffected,
                muted: muted,
                issuesMode: issuesMode,
                context: &context
            )
        }

        if !routesOnlyDebugEnabled {
            drawStations(context: &context, size: size)
            if appState.showLiveTrains {
                drawTrains(context: &context, date: date)
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
            context.stroke(path, with: .color(.white.opacity(colorScheme == .dark ? 0.75 : 1)), lineWidth: 11 * cameraScale)
            context.stroke(path, with: .color(.red.opacity(0.25)), lineWidth: 16 * cameraScale)
        }
        context.stroke(
            path,
            with: .color(
                muted
                    ? Color.secondary.opacity(issuesMode ? 0.26 : 0.18)
                    : displayColor(for: lineID)
            ),
            style: StrokeStyle(
                lineWidth: (isAffected ? 7 : 5.5) * cameraScale,
                // Square caps overlap the separately stroked tangent connector
                // by half a line width, preventing antialias seams. They do not
                // soften direction changes; those are cubic path geometry.
                lineCap: .square,
                lineJoin: .miter
            )
        )
    }

    private func drawStations(context: inout GraphicsContext, size: CGSize) {
        let selectedID = appState.selectedStationID
        let focused = appState.activeAffectedStationIDs
        let issuesMode = appState.disruptionDisplayMode == .issues && !appState.activeAffectedSegmentIDs.isEmpty

        var occupiedLabelFrames: [CGRect] = []
        let labelViewport = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let lineBounds = graph.segments.flatMap { segment in
            let points = (renderingGeometry.segmentPaths[segment.id]?.sampledPoints ?? segment.schematicPoints).map(screenPoint)
            return zip(points, points.dropFirst()).map { start, end in
                CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y),
                    width: abs(end.x - start.x), height: abs(end.y - start.y)
                ).insetBy(dx: -4, dy: -4)
            }
        }
        let majorLabels: Set<String> = [
            "Baker Street", "Bank", "Bond Street", "Canary Wharf", "Ealing Broadway",
            "Earl's Court", "Embankment", "Euston", "Finsbury Park", "Hammersmith",
            "King's Cross St. Pancras", "Liverpool Street", "London Bridge", "Oxford Circus",
            "Paddington", "Stratford", "Victoria", "Waterloo", "Wembley Park", "West Ham",
            "Whitechapel"
        ]
        let centralLabels: Set<String> = [
            "Paddington", "Baker Street", "Camden Town", "Euston",
            "King's Cross St. Pancras", "Farringdon", "Moorgate", "Liverpool Street",
            "Whitechapel", "Stratford", "Notting Hill Gate", "Bond Street",
            "Oxford Circus", "Tottenham Court Road", "Holborn", "Bank", "Tower Hill",
            "Earl's Court", "Victoria", "Green Park", "Piccadilly Circus",
            "Leicester Square", "Charing Cross", "Westminster", "Embankment",
            "Blackfriars", "Waterloo", "London Bridge", "Canary Wharf",
        ]
        let orderedStations = graph.stations.sorted { left, right in
            func priority(_ station: TubeStation) -> Int {
                if station.id == selectedID || focused.contains(station.id) { return 3 }
                if majorLabels.contains(station.name) { return 2 }
                if centralLabels.contains(station.name) { return 1 }
                return 0
            }
            let leftPriority = priority(left)
            let rightPriority = priority(right)
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            return left.name < right.name
        }

        for station in orderedStations {
            let point = stationPoint(station)
            let selected = selectedID == station.id
            let affected = focused.contains(station.id)
            let interchangeSize = min(18, 11 + CGFloat(station.lineIDs.count) * 1.5)
            let diameter: CGFloat = (selected ? 18 : station.interchange ? interchangeSize : 6.5) * max(0.72, cameraScale)
            let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)

            let fill: Color = affected && issuesMode ? .red : colorScheme == .dark ? Color(white: 0.08) : .white
            context.fill(Path(ellipseIn: rect), with: .color(fill))
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(selected ? .blue : affected && issuesMode ? .red : colorScheme == .dark ? .white : .black),
                lineWidth: selected ? 3 : station.interchange ? 2 : 1.2
            )

            let importantForIssue = issuesMode && focused.contains(station.id)
            let shouldLabel = selected || importantForIssue
                || (majorLabels.contains(station.name) && cameraScale >= 0.52)
                || (centralLabels.contains(station.name) && cameraScale >= 0.50)
                || (station.interchange && cameraScale >= 1.12)
            let width = max(34, CGFloat(station.name.count) * (selected ? 6.5 : 4.8))
            let height: CGFloat = selected ? 18 : 14
            let candidateFrames = [
                CGRect(x: point.x + 8, y: point.y - height - 10, width: width, height: height),
                CGRect(x: point.x + 8, y: point.y + 10, width: width, height: height),
                CGRect(x: point.x - width - 8, y: point.y - height - 10, width: width, height: height),
                CGRect(x: point.x - width - 8, y: point.y + 10, width: width, height: height),
            ]
            let lineFreeFrame = candidateFrames.first { candidate in
                let padded = candidate.insetBy(dx: -4, dy: -3)
                return labelViewport.contains(candidate)
                    && !occupiedLabelFrames.contains(where: { $0.intersects(padded) })
                    && !lineBounds.contains(where: { $0.intersects(candidate) })
            }
            let collisionFreeFrame = candidateFrames.first { candidate in
                let padded = candidate.insetBy(dx: -4, dy: -3)
                return labelViewport.contains(candidate)
                    && !occupiedLabelFrames.contains(where: { $0.intersects(padded) })
            }
            let labelFrame = lineFreeFrame
                ?? ((selected || importantForIssue || centralLabels.contains(station.name)) ? collisionFreeFrame : nil)
                ?? ((selected || importantForIssue) ? candidateFrames[0] : nil)

            if shouldLabel, let labelFrame {
                let backing = labelFrame.insetBy(dx: -2.5, dy: -1.5)
                context.fill(
                    Path(roundedRect: backing, cornerRadius: 3),
                    with: .color(Color(.systemBackground).opacity(0.82))
                )
                var text = context.resolve(Text(station.name).font(.system(size: selected ? 12 : 8.5, weight: .semibold)))
                text.shading = .color(colorScheme == .dark ? .primary : .tubeBlue)
                context.draw(text, at: CGPoint(x: labelFrame.minX, y: labelFrame.midY), anchor: .leading)
                occupiedLabelFrames.append(labelFrame)
            }
        }
    }

    private func drawTrains(context: inout GraphicsContext, date: Date) {
        let segments = graph.segmentsByID
        for train in appState.liveTrains {
            guard let segment = segments[train.segmentID],
                  let routePoints = renderingGeometry.segmentPaths[segment.id]?.sampledPoints,
                  let point = interpolatedPoint(
                along: routePoints,
                progress: train.projectedProgress(at: date)
            ) else { continue }

            let screen = screenPoint(point)
            let rect = CGRect(x: screen.x - 9, y: screen.y - 9, width: 18, height: 18)
            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(displayColor(for: train.lineID)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(.white), lineWidth: 2)
            let symbol = context.resolve(Image(systemName: "tram.fill"))
            context.draw(symbol, in: rect.insetBy(dx: 4, dy: 4))
        }
    }

    private func selectMapElement(at location: CGPoint, in size: CGSize) {
        if let station = graph.stations.min(by: {
            distance(stationPoint($0), location) < distance(stationPoint($1), location)
        }), distance(stationPoint(station), location) <= 24 {
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

    private func displayColor(for line: TubeLineID) -> Color {
        if line == .northern && colorScheme == .dark { return Color(white: 0.92) }
        return .tubeLine(line)
    }

    private func path(for geometry: RoundedSchematicPath) -> Path {
        var path = Path()
        path.move(to: screenPoint(geometry.start))
        for element in geometry.elements {
            switch element {
            case let .line(to):
                path.addLine(to: screenPoint(to))
            case let .curve(to, control1, control2):
                path.addCurve(
                    to: screenPoint(to),
                    control1: screenPoint(control1),
                    control2: screenPoint(control2)
                )
            }
        }
        return path
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
