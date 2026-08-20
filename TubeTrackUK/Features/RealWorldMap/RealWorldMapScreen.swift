import MapKit
import Observation
import SwiftUI

struct RealWorldMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    @State private var position: MapCameraPosition = .region(Self.centralLondon)
    @State private var mapSelection: String?
    @State private var renderData: RealWorldMapRenderData?
    @State private var viewport = RealWorldMapViewport()
    @AppStorage("statusPanelExpanded") private var statusExpanded = false

    private static let centralLondon = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5078, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.095, longitudeDelta: 0.15)
    )

    var body: some View {
        ZStack {
            if let graph = appState.graph,
               let renderData,
               renderData.graphID == graph.generatedAt {
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
                            withAnimation(.spring(duration: 0.35)) {
                                appState.select(station: station)
                            }
                        }
                        .onMapCameraChange(frequency: .continuous) { context in
                            viewport.mapDidMove(to: context.region)
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

                        if appState.showLiveTrains, appState.selectedTab == .realWorld {
                            RealWorldTrainCanvas(
                                proxy: proxy,
                                pathsBySegmentID: renderData.pathsBySegmentID,
                                viewport: viewport
                            )
                        }
                    }
                }
            } else {
                ProgressView("Loading geographic map…")
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                MapToolbar { resetCamera() }
                HStack {
                    Spacer()
                    Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                        Text("© OpenStreetMap contributors")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12)
            }
        }
        .overlay(alignment: .bottom) {
            bottomOverlay
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
            if let stationID { focus(on: [stationID]) }
        }
        .onAppear {
            if !appState.activeAffectedStationIDs.isEmpty {
                focus(on: appState.activeAffectedStationIDs)
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
        let issuesMode = appState.disruptionDisplayMode == .issues && !affectedSegmentIDs.isEmpty
        let selectedLineID = appState.selectedLineID

        ForEach(renderData.segments) { segment in
            let affected = affectedSegmentIDs.contains(segment.id)
            let muted = (issuesMode && !affected)
                || (selectedLineID != nil && selectedLineID != segment.lineID)
            MapPolyline(coordinates: segment.path.coordinates)
                .stroke(
                    muted ? Color.secondary.opacity(0.24) : .tubeLine(segment.lineID),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
                .mapOverlayLevel(level: .aboveLabels)
        }

        if issuesMode {
            ForEach(renderData.segments.filter { affectedSegmentIDs.contains($0.id) }) { segment in
                MapPolyline(coordinates: segment.path.coordinates)
                    .stroke(
                        Color.red.opacity(0.82),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                    )
                    .mapOverlayLevel(level: .aboveLabels)
            }
            ForEach(renderData.segments.filter { affectedSegmentIDs.contains($0.id) }) { segment in
                MapPolyline(coordinates: segment.path.coordinates)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )
                    .mapOverlayLevel(level: .aboveLabels)
            }
            ForEach(renderData.segments.filter { affectedSegmentIDs.contains($0.id) }) { segment in
                MapPolyline(coordinates: segment.path.coordinates)
                    .stroke(
                        Color.tubeLine(segment.lineID),
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
                Button {
                    mapSelection = station.id
                } label: {
                    Circle()
                        .fill(.background)
                        .stroke(appState.selectedStationID == station.id ? Color.blue : Color.primary, lineWidth: 2)
                        .frame(width: appState.selectedStationID == station.id ? 18 : 11)
                        .shadow(radius: 1)
                }
                .buttonStyle(.plain)
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
        for disruption in appState.disruptions {
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

    private var bottomOverlay: some View {
        VStack(spacing: 9) {
            if appState.showLiveTrains { TrainFilterBar() }
            if let station = appState.selectedStation {
                StationDetailCard(station: station)
                    .padding(.horizontal, 12)
            } else if let disruption = appState.selectedDisruption {
                DisruptionDetailCard(disruption: disruption)
                    .padding(.horizontal, 12)
            } else if let lineID = appState.selectedLineID {
                LineDetailCard(lineID: lineID)
                    .padding(.horizontal, 12)
            }
            if statusExpanded {
                LiveStatusPanel(expanded: $statusExpanded)
                    .padding(.horizontal, 12)
            } else {
                LiveStatusDock(expanded: $statusExpanded)
                    .padding(.horizontal, 12)
            }
        }
        .safeAreaPadding(.bottom, 4)
        .animation(.spring(duration: 0.4, bounce: 0.12), value: appState.selectedStationID)
        .animation(.spring(duration: 0.4, bounce: 0.12), value: appState.showLiveTrains)
    }

    private func resetCamera() {
        position = .region(Self.centralLondon)
        appState.clearMapSelection()
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
                latitudeDelta: max(0.025, (maxLat - minLat) * 1.55),
                longitudeDelta: max(0.04, (maxLon - minLon) * 1.55)
            )
        )
        withAnimation(.smooth(duration: 0.6)) { position = .region(region) }
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

@Observable
private final class RealWorldMapViewport {
    private(set) var region: MKCoordinateRegion?

    func mapDidMove(to region: MKCoordinateRegion) {
        self.region = region
    }
}

private struct RealWorldTrainCanvas: View {
    @Environment(TubeAppState.self) private var appState

    let proxy: MapProxy
    let pathsBySegmentID: [String: RealWorldRenderPath]
    let viewport: RealWorldMapViewport

    var body: some View {
        let trains = appState.liveTrains
        let visibleRegion = viewport.region

        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Canvas { context, size in
                let visibleBounds = CGRect(origin: .zero, size: size).insetBy(dx: -12, dy: -12)
                var trainIcon = context.resolve(Image(systemName: "tram.fill"))
                trainIcon.shading = .color(.white)

                for train in trains {
                    guard let path = pathsBySegmentID[train.segmentID],
                          let coordinate = path.coordinate(at: train.projectedProgress(at: timeline.date)),
                          visibleRegion?.containsExpanded(coordinate) != false,
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

private struct RealWorldMapRenderData {
    let graphID: String
    let segments: [RealWorldRenderedSegment]
    let pathsBySegmentID: [String: RealWorldRenderPath]

    init(graph: TubeGraph) {
        let stationsByID = graph.stationsByID
        let renderedSegments = graph.segments.map { segment in
            RealWorldRenderedSegment(
                id: segment.id,
                lineID: segment.lineID,
                path: RealWorldRenderPath(segment: segment, stationsByID: stationsByID)
            )
        }
        graphID = graph.generatedAt
        segments = renderedSegments
        pathsBySegmentID = Dictionary(uniqueKeysWithValues: renderedSegments.map { ($0.id, $0.path) })
    }
}

private struct RealWorldRenderedSegment: Identifiable {
    let id: String
    let lineID: TubeLineID
    let path: RealWorldRenderPath
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
        case .central, .northern, .dlr, .elizabeth: 0
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
