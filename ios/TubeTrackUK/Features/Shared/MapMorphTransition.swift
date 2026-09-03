import MapKit
import SwiftUI

struct MapMorphGeometry: Sendable {
    struct Segment: Identifiable, Sendable {
        let id: String
        let lineID: TubeLineID
        let beckPoints: [CGPoint]
        let geographicCoordinates: [CLLocationCoordinate2D]
    }

    struct Station: Identifiable, Sendable {
        let id: String
        let beckPoint: CGPoint
        let geographicCoordinate: CLLocationCoordinate2D
    }

    let routeStrokeWidth: CGFloat
    let segments: [Segment]
    let stations: [Station]
    let segmentsByID: [String: Segment]

    init(document: BeckMapDocument, graph: TubeGraph) {
        let pathsByID = Dictionary(uniqueKeysWithValues: document.paths.map { ($0.id, $0.commands) })
        let graphSegmentsByID = graph.segmentsByID
        let stationsByID = graph.stationsByID

        segments = document.segments.compactMap { segment in
            guard let commands = pathsByID[segment.pathID],
                  let graphSegment = graphSegmentsByID[segment.id] else { return nil }
            var beckPoints = Self.sampledArtworkPoints(
                commands: commands,
                translation: segment.translation
            )
            if segment.pathDirection == .reverse {
                beckPoints.reverse()
            }
            let geographicCoordinates = RealWorldRenderPath(
                segment: graphSegment,
                stationsByID: stationsByID
            ).coordinates
            guard beckPoints.count >= 2, geographicCoordinates.count >= 2 else { return nil }
            let pointCount = max(12, min(36, max(beckPoints.count, geographicCoordinates.count)))
            return Segment(
                id: segment.id,
                lineID: segment.lineID,
                beckPoints: Self.resample(points: beckPoints, count: pointCount),
                geographicCoordinates: Self.resample(
                    coordinates: geographicCoordinates,
                    count: pointCount
                )
            )
        }
        stations = document.stationMarkers.compactMap { marker in
            guard let station = stationsByID[marker.stationID] else { return nil }
            return Station(
                id: marker.stationID,
                beckPoint: CGPoint(x: marker.anchor.x, y: marker.anchor.y),
                geographicCoordinate: station.coordinate
            )
        }
        routeStrokeWidth = document.styles.routeStrokeWidth
        segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
    }

    private static func sampledArtworkPoints(
        commands: [BeckMapPathCommand],
        translation: BeckMapTranslation
    ) -> [CGPoint] {
        func point(_ value: BeckMapPoint) -> CGPoint {
            CGPoint(x: value.x + translation.x, y: value.y + translation.y)
        }
        func cubic(
            from start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            to end: CGPoint,
            progress: CGFloat
        ) -> CGPoint {
            let inverse = 1 - progress
            return CGPoint(
                x: start.x * inverse * inverse * inverse
                    + control1.x * 3 * inverse * inverse * progress
                    + control2.x * 3 * inverse * progress * progress
                    + end.x * progress * progress * progress,
                y: start.y * inverse * inverse * inverse
                    + control1.y * 3 * inverse * inverse * progress
                    + control2.y * 3 * inverse * progress * progress
                    + end.y * progress * progress * progress
            )
        }

        var result: [CGPoint] = []
        var current: CGPoint?
        var subpathStart: CGPoint?
        for command in commands {
            switch command {
            case let .move(to):
                let destination = point(to)
                if result.last != destination { result.append(destination) }
                current = destination
                subpathStart = destination
            case let .line(to):
                let destination = point(to)
                result.append(destination)
                current = destination
            case let .cubic(control1, control2, to):
                let destination = point(to)
                guard let start = current else {
                    result.append(destination)
                    current = destination
                    continue
                }
                let firstControl = point(control1)
                let secondControl = point(control2)
                let controlLength = hypot(firstControl.x - start.x, firstControl.y - start.y)
                    + hypot(secondControl.x - firstControl.x, secondControl.y - firstControl.y)
                    + hypot(destination.x - secondControl.x, destination.y - secondControl.y)
                let steps = max(4, min(24, Int(ceil(controlLength / 18))))
                for step in 1 ... steps {
                    result.append(cubic(
                        from: start,
                        control1: firstControl,
                        control2: secondControl,
                        to: destination,
                        progress: CGFloat(step) / CGFloat(steps)
                    ))
                }
                current = destination
            case .close:
                if let subpathStart, result.last != subpathStart { result.append(subpathStart) }
                current = subpathStart
            }
        }
        return result
    }

    private static func resample(points: [CGPoint], count: Int) -> [CGPoint] {
        let lengths = cumulativeLengths(points: points)
        guard let total = lengths.last, total > 0 else {
            return Array(repeating: points.first ?? .zero, count: count)
        }
        return (0 ..< count).map { index in
            interpolatedPoint(
                at: total * CGFloat(index) / CGFloat(max(1, count - 1)),
                points: points,
                lengths: lengths
            )
        }
    }

    private static func resample(
        coordinates: [CLLocationCoordinate2D],
        count: Int
    ) -> [CLLocationCoordinate2D] {
        let points = coordinates.map(MKMapPoint.init)
        let cgPoints = points.map { CGPoint(x: $0.x, y: $0.y) }
        return resample(points: cgPoints, count: count).map {
            MKMapPoint(x: $0.x, y: $0.y).coordinate
        }
    }

    private static func cumulativeLengths(points: [CGPoint]) -> [CGFloat] {
        guard !points.isEmpty else { return [] }
        var result: [CGFloat] = [0]
        for (start, end) in zip(points, points.dropFirst()) {
            result.append(result[result.endIndex - 1] + hypot(end.x - start.x, end.y - start.y))
        }
        return result
    }

    private static func interpolatedPoint(
        at distance: CGFloat,
        points: [CGPoint],
        lengths: [CGFloat]
    ) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let endIndex = lengths.firstIndex(where: { $0 >= distance }) ?? lengths.index(before: lengths.endIndex)
        guard endIndex > 0 else { return points[0] }
        let startIndex = endIndex - 1
        let segmentLength = lengths[endIndex] - lengths[startIndex]
        let fraction = segmentLength > 0 ? (distance - lengths[startIndex]) / segmentLength : 0
        return CGPoint(
            x: points[startIndex].x + (points[endIndex].x - points[startIndex].x) * fraction,
            y: points[startIndex].y + (points[endIndex].y - points[startIndex].y) * fraction
        )
    }
}

struct MapMorphTransitionLayer: View, @preconcurrency Animatable {
    @Environment(TubeAppState.self) private var appState

    let geometry: MapMorphGeometry
    let graph: TubeGraph
    var layoutProgress: CGFloat

    var animatableData: CGFloat {
        get { layoutProgress }
        set { layoutProgress = newValue }
    }

    var body: some View {
        GeometryReader { _ in
            // At either settled endpoint this layer is fully transparent. Do
            // not keep interpolating and stroking the entire network behind an
            // active renderer; it only exists for the brief mode transition.
            if layoutProgress > 0.001,
               layoutProgress < 0.999,
               let camera = appState.beckMapCameraSnapshot,
               let viewport = appState.sharedMapViewport {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                        drawNetwork(
                            context: &context,
                            size: size,
                            camera: camera,
                            viewport: viewport,
                            date: timeline.date
                        )
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawNetwork(
        context: inout GraphicsContext,
        size: CGSize,
        camera: BeckMapCameraSnapshot,
        viewport: SharedMapViewport,
        date: Date
    ) {
        let mapRect = SharedMapProjection.geographicRect(for: viewport, graph: graph, size: size)
        let progress = min(1, max(0, layoutProgress))
        let transitionVisibility = min(1, max(0, sin(progress * .pi) * 1.75))
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(uiColor: .systemBackground).opacity(transitionVisibility * 0.82))
        )
        context.opacity = transitionVisibility
        let beckWidth = geometry.routeStrokeWidth * camera.scale
        let lineWidth = max(3, beckWidth + (4 - beckWidth) * progress)
        let affectedSegmentIDs = appState.activeAffectedSegmentIDs

        for segment in geometry.segments {
            let path = interpolatedPath(
                segment: segment,
                progress: progress,
                camera: camera,
                mapRect: mapRect,
                size: size
            )
            let affected = affectedSegmentIDs.contains(segment.id)
            let muted = appState.disruptionDisplayMode.mutesSegment(isAffected: affected)
                || (appState.selectedLineID != nil && appState.selectedLineID != segment.lineID)

            if affected, appState.disruptionDisplayMode == .issues {
                context.stroke(
                    path,
                    with: .color(.red.opacity(0.86)),
                    style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    path,
                    with: .color(.white),
                    style: StrokeStyle(lineWidth: lineWidth + 2.5, lineCap: .round, lineJoin: .round)
                )
            }
            context.stroke(
                path,
                with: .color(muted ? Color.secondary.opacity(0.28) : .tubeLine(segment.lineID)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }

        for station in geometry.stations {
            let point = interpolatedPoint(
                beckPoint: station.beckPoint,
                coordinate: station.geographicCoordinate,
                progress: progress,
                camera: camera,
                mapRect: mapRect,
                size: size
            )
            let selected = appState.selectedStationID == station.id
            let overviewRadius = max(1.3, min(3, CGFloat(viewport.zoom) * 0.72))
            let radius: CGFloat = selected ? 7 : overviewRadius
            let marker = Path(ellipseIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.fill(marker, with: .color(.white))
            context.stroke(
                marker,
                with: .color(selected ? .blue : .primary),
                lineWidth: selected ? 2.5 : max(0.8, radius * 0.45)
            )
        }

        guard appState.showLiveTrains else { return }
        for train in appState.liveTrains {
            guard let segment = geometry.segmentsByID[train.segmentID],
                  let routeProgress = LiveTrainMarkerPolicy.projectedProgress(
                      for: train,
                      at: date,
                      stationBoard: appState.authoritativeStationBoardSnapshot
                  ) else { continue }
            let pointIndex = min(
                segment.beckPoints.index(before: segment.beckPoints.endIndex),
                Int((Double(segment.beckPoints.count - 1) * routeProgress).rounded())
            )
            let point = interpolatedPoint(
                beckPoint: segment.beckPoints[pointIndex],
                coordinate: segment.geographicCoordinates[pointIndex],
                progress: progress,
                camera: camera,
                mapRect: mapRect,
                size: size
            )
            let rect = CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
            let markerImage = context.resolve(Image(train.lineID.liveTrainMarkerAssetName))
            context.draw(markerImage, in: rect)
        }
    }

    private func interpolatedPath(
        segment: MapMorphGeometry.Segment,
        progress: CGFloat,
        camera: BeckMapCameraSnapshot,
        mapRect: MKMapRect,
        size: CGSize
    ) -> Path {
        var path = Path()
        for index in segment.beckPoints.indices {
            let point = interpolatedPoint(
                beckPoint: segment.beckPoints[index],
                coordinate: segment.geographicCoordinates[index],
                progress: progress,
                camera: camera,
                mapRect: mapRect,
                size: size
            )
            if index == segment.beckPoints.startIndex {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func interpolatedPoint(
        beckPoint: CGPoint,
        coordinate: CLLocationCoordinate2D,
        progress: CGFloat,
        camera: BeckMapCameraSnapshot,
        mapRect: MKMapRect,
        size: CGSize
    ) -> CGPoint {
        let start = camera.screenPoint(for: beckPoint, in: size)
        let end = SharedMapProjection.screenPoint(for: coordinate, in: mapRect, size: size)
        return CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
}
