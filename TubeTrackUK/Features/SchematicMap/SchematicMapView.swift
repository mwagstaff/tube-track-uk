import SwiftUI

struct SchematicMapView: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let graph: TubeGraph
    let resetToken: Int

    @State private var cameraScale: CGFloat = 0.72
    @State private var cameraOffset = CGSize(width: -220, height: -65)
    @State private var cameraInitialized = false
    @State private var gestureStartScale: CGFloat?
    @State private var gestureStartOffset: CGSize?

    private let mapCentre = CGPoint(x: 540, y: 520)

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: appState.showLiveTrains ? 1 / 12 : 1, paused: !appState.showLiveTrains || reduceMotion)) { timeline in
                Canvas { context, size in
                    drawMap(context: &context, size: size, date: timeline.date)
                }
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { tap in
                            selectMapElement(at: tap.location, in: proxy.size)
                        }
                )
                .accessibilityRepresentation {
                    stationAccessibilityList
                }
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

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if gestureStartOffset == nil { gestureStartOffset = cameraOffset }
                guard let start = gestureStartOffset else { return }
                cameraOffset = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in gestureStartOffset = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if gestureStartScale == nil { gestureStartScale = cameraScale }
                guard let start = gestureStartScale else { return }
                cameraScale = min(2.4, max(0.32, start * value.magnification))
            }
            .onEnded { _ in gestureStartScale = nil }
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
        cameraScale = max(0.52, min(0.78, size.width / 520))
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
            guard let path = path(for: segment.schematicPoints), !segment.schematicPoints.isEmpty else { continue }
            let isAffected = affectedSegments.contains(segment.id)
            let isSelectedLine = appState.selectedLineID == nil || appState.selectedLineID == segment.lineID
            let muted = (issuesMode && !isAffected) || !isSelectedLine
            let color = displayColor(for: segment.lineID)

            if isAffected && issuesMode {
                context.stroke(path, with: .color(.white.opacity(colorScheme == .dark ? 0.75 : 1)), lineWidth: 11 * cameraScale)
                context.stroke(path, with: .color(.red.opacity(0.25)), lineWidth: 16 * cameraScale)
            }
            context.stroke(
                path,
                with: .color(muted ? Color.secondary.opacity(issuesMode ? 0.26 : 0.18) : color),
                style: StrokeStyle(lineWidth: (isAffected ? 7 : 5.5) * cameraScale, lineCap: .round, lineJoin: .round)
            )
        }

        drawStations(context: &context)
        if appState.showLiveTrains {
            drawTrains(context: &context, date: date)
        }
    }

    private func drawStations(context: inout GraphicsContext) {
        let selectedID = appState.selectedStationID
        let focused = appState.activeAffectedStationIDs
        let issuesMode = appState.disruptionDisplayMode == .issues && !appState.activeAffectedSegmentIDs.isEmpty

        var occupiedLabelFrames: [CGRect] = []
        let majorLabels: Set<String> = [
            "Baker Street", "Bank", "Bond Street", "Canary Wharf", "Ealing Broadway",
            "Earl's Court", "Embankment", "Euston", "Finsbury Park", "Hammersmith",
            "King's Cross St. Pancras", "Liverpool Street", "London Bridge", "Oxford Circus",
            "Paddington", "Stratford", "Victoria", "Waterloo", "Wembley Park", "West Ham",
            "Whitechapel"
        ]
        let orderedStations = graph.stations.sorted { left, right in
            let leftPriority = left.id == selectedID || focused.contains(left.id)
            let rightPriority = right.id == selectedID || focused.contains(right.id)
            return leftPriority && !rightPriority
        }

        for station in orderedStations {
            let point = stationPoint(station)
            let selected = selectedID == station.id
            let affected = focused.contains(station.id)
            let diameter: CGFloat = (selected ? 17 : station.interchange ? 10 : 6.5) * max(0.72, cameraScale)
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
                || (station.interchange && cameraScale >= 1.12)
            let labelFrame = CGRect(
                x: point.x + 6,
                y: point.y - 25,
                width: max(36, CGFloat(station.name.count) * (selected ? 6.5 : 5.2)),
                height: selected ? 18 : 14
            )
            if shouldLabel && (selected || importantForIssue || !occupiedLabelFrames.contains(where: { $0.intersects(labelFrame.insetBy(dx: -4, dy: -3)) })) {
                var text = context.resolve(Text(station.name).font(.system(size: selected ? 12 : 9, weight: .semibold)))
                text.shading = .color(.primary)
                context.draw(text, at: CGPoint(x: point.x + 7, y: point.y - 8), anchor: .bottomLeading)
                occupiedLabelFrames.append(labelFrame)
            }
        }
    }

    private func drawTrains(context: inout GraphicsContext, date: Date) {
        let segments = graph.segmentsByID
        for train in appState.liveTrains {
            guard let segment = segments[train.segmentID], let point = interpolatedPoint(
                along: segment.schematicPoints,
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
            let points = segment.schematicPoints.map(screenPoint)
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

    private func path(for points: [SchematicPoint]) -> Path? {
        guard let first = points.first else { return nil }
        var path = Path()
        path.move(to: screenPoint(first))
        for point in points.dropFirst() { path.addLine(to: screenPoint(point)) }
        return path
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
