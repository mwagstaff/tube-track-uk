import MapKit
import SwiftUI

struct RealWorldMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    let resetToken: Int
    @State private var position: MapCameraPosition = .region(Self.centralLondon)
    @State private var mapSelection: String?
    @State private var renderData: RealWorldMapRenderData?
    @State private var visibleRegion = Self.centralLondon
    @State private var acceptsCameraUpdates = false

    private static let centralLondon = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5078, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.095, longitudeDelta: 0.15)
    )

    var body: some View {
        ZStack {
            if let graph = appState.graph,
               let renderData,
               renderData.graphID == graph.generatedAt {
                GeometryReader { viewportProxy in
                    MapReader { proxy in
                        ZStack {
                            Map(position: $position, selection: $mapSelection) {
                                tubeOverlays(renderData: renderData)
                                stationAnnotations(graph: graph)
                            }
                            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
                            .mapControls {
                                MapCompass()
                                MapScaleView()
                            }
                            .onChange(of: mapSelection) { _, stationID in
                                guard let stationID,
                                      let station = graph.stations.first(where: { $0.id == stationID }) else { return }
                                withAnimation(.smooth(duration: 0.35)) {
                                    appState.select(station: station)
                                }
                            }
                            .onMapCameraChange(frequency: .continuous) { context in
                                visibleRegion = context.region
                                guard appState.mapPresentationMode == .realWorld,
                                      acceptsCameraUpdates else { return }
                                appState.sharedMapViewport = SharedMapProjection.viewport(
                                    from: context.rect,
                                    graph: graph,
                                    size: viewportProxy.size
                                )
                            }
                            .simultaneousGesture(
                                SpatialTapGesture()
                                    .onEnded { value in
                                        handleLineTap(
                                            at: value.location,
                                            proxy: proxy,
                                            graph: graph,
                                            renderData: renderData
                                        )
                                    }
                            )

                            if appState.showLiveTrains, appState.selectedTab == .map {
                                RealWorldTrainCanvas(
                                    proxy: proxy,
                                    pathsBySegmentID: renderData.pathsBySegmentID,
                                    visibleRegion: visibleRegion
                                )
                            }
                        }
                    }
                    .onChange(of: appState.mapPresentationMode) { _, mode in
                        acceptsCameraUpdates = false
                        guard mode == .realWorld else { return }
                        applySharedViewport(in: viewportProxy.size)
                        Task { @MainActor in
                            await Task.yield()
                            guard appState.mapPresentationMode == .realWorld else { return }
                            acceptsCameraUpdates = true
                        }
                    }
                    .onChange(of: resetToken) { _, _ in
                        guard appState.mapPresentationMode == .realWorld else { return }
                        resetCamera()
                    }
                }
            } else {
                ProgressView("Loading geographic map…")
            }
        }
        .onChange(of: appState.focusedStationIDs) { _, stations in
            guard !stations.isEmpty else { return }
            focus(on: stations)
        }
        .onChange(of: appState.selectedDisruptionID) { _, _ in
            focus(on: appState.activeAffectedStationIDs)
        }
        .onChange(of: appState.selectedStationID) { _, stationID in
            mapSelection = stationID
        }
        .onChange(of: appState.stationSelectionGeneration) { _, _ in
            guard let stationID = appState.selectedStationID else { return }
            focus(on: [stationID])
        }
        .onAppear {
            guard appState.mapPresentationMode == .realWorld else { return }
            if let stationID = appState.selectedStationID {
                mapSelection = stationID
                focus(on: [stationID])
            } else if appState.hasFocusedMapSection || appState.selectedDisruption != nil {
                focus(on: appState.activeAffectedStationIDs)
            }
            Task { @MainActor in
                await Task.yield()
                guard appState.mapPresentationMode == .realWorld else { return }
                acceptsCameraUpdates = true
            }
        }
        .task(id: appState.graph?.generatedAt) {
            guard let graph = appState.graph else {
                renderData = nil
                return
            }
            renderData = RealWorldMapRenderData(graph: graph)
        }
    }

    @MapContentBuilder
    private func tubeOverlays(renderData: RealWorldMapRenderData) -> some MapContent {
        let affectedSegmentIDs = appState.activeAffectedSegmentIDs
        let displayMode = appState.disruptionDisplayMode
        let selectedLineID = appState.selectedLineID
        let unaffectedSegmentIDs = Set(renderData.segments.map(\.id))
            .subtracting(affectedSegmentIDs)
        let unaffectedPolylines = renderData.polylines(covering: unaffectedSegmentIDs)
        let affectedPolylines = renderData.polylines(covering: affectedSegmentIDs)

        ForEach(unaffectedPolylines) { polyline in
            let muted = displayMode.mutesSegment(isAffected: false)
                || (selectedLineID != nil && selectedLineID != polyline.lineID)
            MapPolyline(polyline.overlay)
                .stroke(
                    muted ? Color.secondary.opacity(0.24) : .tubeLine(polyline.lineID),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
                .mapOverlayLevel(level: .aboveLabels)
        }

        ForEach(affectedPolylines) { polyline in
            let muted = displayMode.mutesSegment(isAffected: true)
            MapPolyline(polyline.overlay)
                .stroke(
                    muted ? Color.secondary.opacity(0.24) : .tubeLine(polyline.lineID),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
                .mapOverlayLevel(level: .aboveLabels)
        }

        if displayMode == .issues {
            ForEach(affectedPolylines) { polyline in
                MapPolyline(polyline.overlay)
                    .stroke(
                        Color.red.opacity(0.82),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                    )
                    .mapOverlayLevel(level: .aboveLabels)
            }
            ForEach(affectedPolylines) { polyline in
                MapPolyline(polyline.overlay)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )
                    .mapOverlayLevel(level: .aboveLabels)
            }
            ForEach(affectedPolylines) { polyline in
                MapPolyline(polyline.overlay)
                    .stroke(
                        Color.tubeLine(polyline.lineID),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
                    .mapOverlayLevel(level: .aboveLabels)
            }
        }
    }

    @MapContentBuilder
    private func stationAnnotations(graph: TubeGraph) -> some MapContent {
        ForEach(displayStations(graph: graph)) { station in
            Annotation(station.name, coordinate: station.coordinate, anchor: .center) {
                let selected = appState.selectedStationID == station.id
                let networkZoom = CGFloat(appState.sharedMapViewport?.zoom ?? 4)
                let markerDiameter = max(5, min(11, 3 + networkZoom * 2))
                ZStack {
                    if selected {
                        Circle()
                            .fill(Color.blue.opacity(0.16))
                            .stroke(Color.blue.opacity(0.9), lineWidth: 2.5)
                            .frame(width: 32, height: 32)
                            .shadow(color: Color.blue.opacity(0.35), radius: 6)
                    }

                    Circle()
                        .fill(.background)
                        .stroke(
                            selected ? Color.blue : Color.primary,
                            lineWidth: selected ? 3 : (markerDiameter < 8 ? 1.25 : 2)
                        )
                        .frame(
                            width: selected ? 18 : markerDiameter,
                            height: selected ? 18 : markerDiameter
                        )
                }
                    .animation(.smooth(duration: 0.3), value: selected)
                    .accessibilityLabel(station.name)
            }
            .tag(station.id)
        }
    }

    private func displayStations(graph: TubeGraph) -> [TubeStation] {
        RealWorldStationDisplay.stations(
            in: graph,
            selectedStationID: appState.selectedStationID
        )
        .filter {
            $0.id == appState.selectedStationID
                || visibleRegion.containsExpanded($0.coordinate)
        }
    }

    private func handleLineTap(
        at location: CGPoint,
        proxy: MapProxy,
        graph: TubeGraph,
        renderData: RealWorldMapRenderData
    ) {
        let stationPoints = displayStations(graph: graph).compactMap {
            proxy.convert($0.coordinate, to: .local)
        }
        guard !RealWorldLineHitTesting.isNearStation(
            location,
            stationPoints: stationPoints
        ) else { return }

        var disruptionsBySegmentID: [String: [ResolvedDisruption]] = [:]
        for disruption in appState.visibleDisruptions {
            for segmentID in disruption.affectedSegmentIDs {
                disruptionsBySegmentID[segmentID, default: []].append(disruption)
            }
        }

        var nearestHit: (distance: CGFloat, disruption: ResolvedDisruption)?
        for segment in renderData.segments {
            guard let disruptions = disruptionsBySegmentID[segment.id],
                  let disruption = disruptions.first else { continue }
            let screenPoints = segment.path.coordinates.compactMap {
                proxy.convert($0, to: .local)
            }
            guard let distance = RealWorldLineHitTesting.distance(
                from: location,
                toPolyline: screenPoints
            ), distance <= RealWorldLineHitTesting.lineHitRadius else { continue }

            if nearestHit == nil || distance < nearestHit!.distance {
                nearestHit = (distance, disruption)
            }
        }

        guard let disruption = nearestHit?.disruption else { return }
        withAnimation(.spring(duration: 0.35)) {
            appState.select(disruption: disruption)
        }
    }

    private func resetCamera() {
        position = .region(Self.centralLondon)
        appState.clearMapSelection()
    }

    private func applySharedViewport(in size: CGSize) {
        guard let graph = appState.graph,
              let viewport = appState.sharedMapViewport else { return }
        position = .rect(SharedMapProjection.geographicRect(
            for: viewport,
            graph: graph,
            size: size
        ))
    }

    private func focus(on stationIDs: Set<String>) {
        guard let graph = appState.graph else { return }
        let stations = graph.stations.filter { stationIDs.contains($0.id) }
        guard !stations.isEmpty else { return }
        let latitudes = stations.map(\.latitude)
        let longitudes = stations.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(stations.count == 1 ? 0.012 : 0.025, (maxLat - minLat) * 1.55),
                longitudeDelta: max(stations.count == 1 ? 0.02 : 0.04, (maxLon - minLon) * 1.55)
            )
        )
        withAnimation(.easeInOut(duration: 2.0)) { position = .region(region) }
    }

}

enum RealWorldLineHitTesting {
    static let lineHitRadius: CGFloat = 16
    static let stationExclusionRadius: CGFloat = 28

    static func isNearStation(
        _ point: CGPoint,
        stationPoints: [CGPoint],
        radius: CGFloat = stationExclusionRadius
    ) -> Bool {
        stationPoints.contains { hypot(point.x - $0.x, point.y - $0.y) <= radius }
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else {
            return hypot(point.x - first.x, point.y - first.y)
        }

        return zip(points, points.dropFirst()).reduce(nil as CGFloat?) { nearest, pair in
            let distance = distance(from: point, toSegmentFrom: pair.0, to: pair.1)
            return min(nearest ?? distance, distance)
        }
    }

    private static func distance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projectedFraction = ((point.x - start.x) * dx + (point.y - start.y) * dy)
            / squaredLength
        let clampedFraction = min(1, max(0, projectedFraction))
        let projectedPoint = CGPoint(
            x: start.x + clampedFraction * dx,
            y: start.y + clampedFraction * dy
        )
        return hypot(point.x - projectedPoint.x, point.y - projectedPoint.y)
    }
}

private struct RealWorldTrainCanvas: View {
    @Environment(TubeAppState.self) private var appState

    let proxy: MapProxy
    let pathsBySegmentID: [String: RealWorldRenderPath]
    let visibleRegion: MKCoordinateRegion

    var body: some View {
        let trains = appState.liveTrains

        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Canvas { context, size in
                let visibleBounds = CGRect(origin: .zero, size: size).insetBy(dx: -12, dy: -12)
                var trainIcon = context.resolve(Image(systemName: "tram.fill"))
                trainIcon.shading = .color(.white)

                for train in trains {
                    guard let path = pathsBySegmentID[train.segmentID],
                          let coordinate = path.coordinate(at: train.projectedProgress(at: timeline.date)),
                          visibleRegion.containsExpanded(coordinate),
                          let point = proxy.convert(coordinate, to: .local),
                          visibleBounds.contains(point) else { continue }

                    let markerRect = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
                    let marker = Path(roundedRect: markerRect, cornerRadius: 6)
                    context.fill(marker, with: .color(Color.tubeLine(train.lineID)))
                    context.stroke(marker, with: .color(.white), lineWidth: 1.5)
                    context.draw(trainIcon, in: markerRect.insetBy(dx: 4.5, dy: 4.5))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated live train positions")
        .accessibilityValue("\(trains.count) trains")
    }
}

private extension MKCoordinateRegion {
    func containsExpanded(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let latitudeRadius = span.latitudeDelta * 0.6
        let longitudeRadius = span.longitudeDelta * 0.6
        let rawLongitudeDelta = abs(coordinate.longitude - center.longitude)
        let wrappedLongitudeDelta = min(rawLongitudeDelta, 360 - rawLongitudeDelta)
        return abs(coordinate.latitude - center.latitude) <= latitudeRadius
            && wrappedLongitudeDelta <= longitudeRadius
    }
}

struct RealWorldMapRenderData {
    let graphID: String
    let segments: [RealWorldRenderedSegment]
    let polylines: [RealWorldRenderedPolyline]
    let pathsBySegmentID: [String: RealWorldRenderPath]

    init(graph: TubeGraph) {
        let stationsByID = graph.stationsByID
        let renderedSegments = graph.segments.map { segment in
            RealWorldRenderedSegment(
                id: segment.id,
                lineID: segment.lineID,
                fromStationID: segment.fromStationID,
                toStationID: segment.toStationID,
                path: RealWorldRenderPath(segment: segment, stationsByID: stationsByID)
            )
        }
        graphID = graph.generatedAt
        segments = renderedSegments
        polylines = RealWorldPolylineBuilder.polylines(from: renderedSegments)
        pathsBySegmentID = Dictionary(uniqueKeysWithValues: renderedSegments.map { ($0.id, $0.path) })
    }

    func polylines(covering segmentIDs: Set<String>) -> [RealWorldRenderedPolyline] {
        RealWorldPolylineBuilder.polylines(
            from: segments.filter { segmentIDs.contains($0.id) }
        )
    }
}

struct RealWorldRenderedSegment: Identifiable {
    let id: String
    let lineID: TubeLineID
    let fromStationID: String
    let toStationID: String
    let path: RealWorldRenderPath
}

struct RealWorldRenderedPolyline: Identifiable {
    let id: String
    let lineID: TubeLineID
    let segmentIDs: [String]
    let coordinates: [CLLocationCoordinate2D]
    let overlay: MKPolyline

    init(
        id: String,
        lineID: TubeLineID,
        segmentIDs: [String],
        coordinates: [CLLocationCoordinate2D]
    ) {
        self.id = id
        self.lineID = lineID
        self.segmentIDs = segmentIDs
        self.coordinates = coordinates
        self.overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
    }
}

enum RealWorldPolylineBuilder {
    static func polylines(from segments: [RealWorldRenderedSegment]) -> [RealWorldRenderedPolyline] {
        Dictionary(grouping: segments, by: \.lineID)
            .keys
            .sorted { $0.rawValue < $1.rawValue }
            .flatMap { lineID in
                buildLinePolylines(
                    lineID: lineID,
                    segments: segments.filter { $0.lineID == lineID }
                )
            }
    }

    private static func buildLinePolylines(
        lineID: TubeLineID,
        segments: [RealWorldRenderedSegment]
    ) -> [RealWorldRenderedPolyline] {
        guard !segments.isEmpty else { return [] }

        var indicesByStationID: [String: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            indicesByStationID[segment.fromStationID, default: []].append(index)
            indicesByStationID[segment.toStationID, default: []].append(index)
        }

        var unusedIndices = Set(segments.indices)
        var results: [RealWorldRenderedPolyline] = []

        for stationID in indicesByStationID.keys.sorted()
        where indicesByStationID[stationID, default: []].count != 2 {
            for segmentIndex in indicesByStationID[stationID, default: []]
            where unusedIndices.contains(segmentIndex) {
                results.append(consumePolyline(
                    lineID: lineID,
                    startingAt: stationID,
                    segmentIndex: segmentIndex,
                    segments: segments,
                    indicesByStationID: indicesByStationID,
                    unusedIndices: &unusedIndices
                ))
            }
        }

        while let segmentIndex = unusedIndices.min() {
            results.append(consumePolyline(
                lineID: lineID,
                startingAt: segments[segmentIndex].fromStationID,
                segmentIndex: segmentIndex,
                segments: segments,
                indicesByStationID: indicesByStationID,
                unusedIndices: &unusedIndices
            ))
        }
        return results
    }

    private static func consumePolyline(
        lineID: TubeLineID,
        startingAt startStationID: String,
        segmentIndex firstSegmentIndex: Int,
        segments: [RealWorldRenderedSegment],
        indicesByStationID: [String: [Int]],
        unusedIndices: inout Set<Int>
    ) -> RealWorldRenderedPolyline {
        var stationID = startStationID
        var segmentIndex = firstSegmentIndex
        var segmentIDs: [String] = []
        var coordinates: [CLLocationCoordinate2D] = []

        while unusedIndices.remove(segmentIndex) != nil {
            let segment = segments[segmentIndex]
            let travelsForward = segment.fromStationID == stationID
            let nextStationID = travelsForward ? segment.toStationID : segment.fromStationID
            if travelsForward, coordinates.isEmpty {
                coordinates.append(contentsOf: segment.path.coordinates)
            } else if travelsForward {
                coordinates.append(contentsOf: segment.path.coordinates.dropFirst())
            } else if coordinates.isEmpty {
                coordinates.append(contentsOf: segment.path.coordinates.reversed())
            } else {
                coordinates.append(contentsOf: segment.path.coordinates.reversed().dropFirst())
            }
            segmentIDs.append(segment.id)
            stationID = nextStationID

            guard indicesByStationID[stationID, default: []].count == 2,
                  let nextSegmentIndex = indicesByStationID[stationID, default: []]
                    .first(where: { unusedIndices.contains($0) }) else {
                break
            }
            segmentIndex = nextSegmentIndex
        }

        return RealWorldRenderedPolyline(
            id: "\(lineID.rawValue):\(segmentIDs.joined(separator: "|"))",
            lineID: lineID,
            segmentIDs: segmentIDs,
            coordinates: coordinates
        )
    }
}

struct RealWorldRenderPath {
    let coordinates: [CLLocationCoordinate2D]
    private let cumulativeLengths: [Double]
    private let totalLength: Double

    init(segment: TubeSegment, stationsByID: [String: TubeStation]) {
        let coordinates = Self.displayCoordinates(for: segment, stationsByID: stationsByID)
        var cumulativeLengths = [Double]()
        cumulativeLengths.reserveCapacity(coordinates.count)
        cumulativeLengths.append(0)
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            cumulativeLengths.append(
                cumulativeLengths[cumulativeLengths.endIndex - 1]
                    + hypot((end.longitude - start.longitude) * 0.62, end.latitude - start.latitude)
            )
        }

        self.coordinates = coordinates
        self.cumulativeLengths = cumulativeLengths
        totalLength = cumulativeLengths.last ?? 0
    }

    func coordinate(at progress: Double) -> CLLocationCoordinate2D? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1, totalLength > 0 else { return first }

        let clampedProgress = min(1, max(0, progress))
        if clampedProgress <= 0 { return first }
        if clampedProgress >= 1 { return coordinates.last }

        let target = totalLength * clampedProgress
        var lowerBound = 1
        var upperBound = cumulativeLengths.count - 1
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if cumulativeLengths[midpoint] < target {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        let endIndex = lowerBound
        let startIndex = endIndex - 1
        let segmentLength = cumulativeLengths[endIndex] - cumulativeLengths[startIndex]
        guard segmentLength > 0 else { return coordinates[endIndex] }
        let fraction = (target - cumulativeLengths[startIndex]) / segmentLength
        let start = coordinates[startIndex]
        let end = coordinates[endIndex]
        return CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    private static func displayCoordinates(
        for segment: TubeSegment,
        stationsByID: [String: TubeStation]
    ) -> [CLLocationCoordinate2D] {
        let coordinates = RealWorldRouteGeometry.anchoredCoordinates(
            for: segment,
            stationsByID: stationsByID
        )
        guard coordinates.count >= 2 else { return coordinates }
        let offset = laneOffset(for: segment.lineID)
        guard offset != 0 else { return coordinates }

        var offsetCoordinates = coordinates.indices.map { index in
            let before = coordinates[index == coordinates.startIndex ? index : index - 1]
            let after = coordinates[index == coordinates.index(before: coordinates.endIndex) ? index : index + 1]
            let latitude = coordinates[index].latitude
            let metresPerLongitude = max(1, 111_320 * cos(latitude * .pi / 180))
            let dx = (after.longitude - before.longitude) * metresPerLongitude
            let dy = (after.latitude - before.latitude) * 110_574
            let length = max(0.001, hypot(dx, dy))
            let normalX = -dy / length * offset
            let normalY = dx / length * offset
            return CLLocationCoordinate2D(
                latitude: coordinates[index].latitude + normalY / 110_574,
                longitude: coordinates[index].longitude + normalX / metresPerLongitude
            )
        }

        // Shared station endpoints remain exact even when adjacent track
        // segments have different tangents and lane offsets.
        offsetCoordinates[offsetCoordinates.startIndex] = coordinates[coordinates.startIndex]
        offsetCoordinates[offsetCoordinates.index(before: offsetCoordinates.endIndex)] = coordinates[
            coordinates.index(before: coordinates.endIndex)
        ]
        return offsetCoordinates
    }

    private static func laneOffset(for lineID: TubeLineID) -> Double {
        switch lineID {
        case .bakerloo: -8
        case .circle: -6
        case .district: 6
        case .hammersmithCity: 10
        case .jubilee: -4
        case .metropolitan: -10
        case .piccadilly: 4
        case .victoria: 8
        case .waterlooCity: -4
        case .central, .northern, .dlr, .elizabeth, .tram, .liberty, .lioness, .mildmay,
             .suffragette, .weaver, .windrush: 0
        }
    }
}

enum RealWorldStationDisplay {
    static func stations(
        in graph: TubeGraph,
        selectedStationID: String?
    ) -> [TubeStation] {
        Dictionary(grouping: graph.stations) { $0.hubID ?? $0.id }
            .values
            .compactMap { group in
                group.first(where: { $0.id == selectedStationID })
                    ?? group.sorted {
                        if $0.lineIDs.count != $1.lineIDs.count {
                            return $0.lineIDs.count > $1.lineIDs.count
                        }
                        return $0.id < $1.id
                    }.first
            }
            .sorted { $0.name < $1.name }
    }
}

enum RealWorldRouteGeometry {
    static func anchoredCoordinates(
        for segment: TubeSegment,
        stationsByID: [String: TubeStation]
    ) -> [CLLocationCoordinate2D] {
        var track = segment.geographicPoints.map(\.coordinate)
        guard let from = stationsByID[segment.fromStationID]?.coordinate,
              let to = stationsByID[segment.toStationID]?.coordinate else {
            return track
        }
        guard let first = track.first, let last = track.last else {
            return [from, to]
        }

        let forwardDistance = distance(from, first) + distance(last, to)
        let reverseDistance = distance(to, first) + distance(last, from)
        if reverseDistance < forwardDistance {
            track.reverse()
        }

        anchor(from, atStartOf: &track)
        anchor(to, atEndOf: &track)
        return track
    }

    private static func anchor(
        _ station: CLLocationCoordinate2D,
        atStartOf track: inout [CLLocationCoordinate2D]
    ) {
        guard let first = track.first else {
            track = [station]
            return
        }
        if distance(station, first) <= 2 {
            track[0] = station
        } else {
            track.insert(station, at: 0)
        }
    }

    private static func anchor(
        _ station: CLLocationCoordinate2D,
        atEndOf track: inout [CLLocationCoordinate2D]
    ) {
        guard let lastIndex = track.indices.last else {
            track = [station]
            return
        }
        if distance(track[lastIndex], station) <= 2 {
            track[lastIndex] = station
        } else {
            track.append(station)
        }
    }

    private static func distance(
        _ first: CLLocationCoordinate2D,
        _ second: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let meanLatitude = (first.latitude + second.latitude) * .pi / 360
        let longitudeMetres = (second.longitude - first.longitude) * 111_320 * cos(meanLatitude)
        let latitudeMetres = (second.latitude - first.latitude) * 110_574
        return hypot(longitudeMetres, latitudeMetres)
    }
}
