import MapKit
import SwiftUI

struct RealWorldMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    @State private var position: MapCameraPosition = .region(Self.centralLondon)
    @State private var mapSelection: String?
    @AppStorage("statusPanelExpanded") private var statusExpanded = false

    private static let centralLondon = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5078, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.095, longitudeDelta: 0.15)
    )

    var body: some View {
        ZStack {
            if let graph = appState.graph {
                TimelineView(.periodic(from: .now, by: appState.showLiveTrains ? 1.0 : 60)) { timeline in
                    Map(position: $position, selection: $mapSelection) {
                        tubeOverlays(graph: graph)
                        stationAnnotations(graph: graph)
                        if appState.showLiveTrains {
                            trainAnnotations(graph: graph, date: timeline.date)
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
                    .mapControls {
                        MapCompass()
                        MapScaleView()
                    }
                    .onChange(of: mapSelection) { _, stationID in
                        guard let stationID, let station = graph.stations.first(where: { $0.id == stationID }) else { return }
                        withAnimation(.spring(duration: 0.35)) {
                            appState.select(station: station)
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
    }

    @MapContentBuilder
    private func tubeOverlays(graph: TubeGraph) -> some MapContent {
        ForEach(graph.segments) { segment in
            let affected = appState.activeAffectedSegmentIDs.contains(segment.id)
            let issuesMode = appState.disruptionDisplayMode == .issues && !appState.activeAffectedSegmentIDs.isEmpty
            let muted = (issuesMode && !affected)
                || (appState.selectedLineID != nil && appState.selectedLineID != segment.lineID)
            MapPolyline(coordinates: displayCoordinates(for: segment))
                .stroke(
                    muted ? Color.secondary.opacity(0.24) : (affected && issuesMode ? .red : .tubeLine(segment.lineID)),
                    style: StrokeStyle(lineWidth: affected ? 7 : 4, lineCap: .round, lineJoin: .round)
                )
        }
    }

    @MapContentBuilder
    private func stationAnnotations(graph: TubeGraph) -> some MapContent {
        ForEach(graph.stations.filter { $0.interchange || $0.id == appState.selectedStationID }) { station in
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

    @MapContentBuilder
    private func trainAnnotations(graph: TubeGraph, date: Date) -> some MapContent {
        ForEach(appState.liveTrains) { train in
            if let coordinate = trainCoordinate(train, graph: graph, date: date) {
                Annotation("\(train.lineID.displayName) line train", coordinate: coordinate) {
                    Image(systemName: "tram.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.tubeLine(train.lineID), in: .rect(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 1.5) }
                        .shadow(radius: 2)
                }
            }
        }
    }

    private var bottomOverlay: some View {
        VStack(spacing: 9) {
            if appState.showLiveTrains { TrainFilterBar() }
            if let station = appState.selectedStation {
                StationDetailCard(station: station)
                    .padding(.horizontal, 12)
            } else if let lineID = appState.selectedLineID, appState.selectedDisruptionID == nil {
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

    private func trainCoordinate(_ train: LiveTubeTrain, graph: TubeGraph, date: Date) -> CLLocationCoordinate2D? {
        guard let segment = graph.segmentsByID[train.segmentID] else { return nil }
        let points = displayCoordinates(for: segment)
        guard let first = points.first else { return nil }
        let progress = train.projectedProgress(at: date)
        guard points.count > 1 else { return first }
        let lengths = zip(points, points.dropFirst()).map {
            hypot(($1.longitude - $0.longitude) * 0.62, $1.latitude - $0.latitude)
        }
        let target = lengths.reduce(0, +) * min(1, max(0, progress))
        var travelled = 0.0
        for (index, length) in lengths.enumerated() {
            if travelled + length >= target, length > 0 {
                let fraction = (target - travelled) / length
                let start = points[index]
                let end = points[index + 1]
                return CLLocationCoordinate2D(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                )
            }
            travelled += length
        }
        return points.last
    }

    private func displayCoordinates(for segment: TubeSegment) -> [CLLocationCoordinate2D] {
        let coordinates = segment.geographicPoints.map(\.coordinate)
        guard coordinates.count >= 2 else { return coordinates }
        let laneMetres: [TubeLineID: Double] = [
            .bakerloo: -8, .central: 0, .circle: -6, .district: 6,
            .hammersmithCity: 10, .jubilee: -4, .metropolitan: -10,
            .northern: 0, .piccadilly: 4, .victoria: 8, .waterlooCity: -4,
        ]
        let offset = laneMetres[segment.lineID, default: 0]
        guard offset != 0 else { return coordinates }

        return coordinates.indices.map { index in
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
    }
}
