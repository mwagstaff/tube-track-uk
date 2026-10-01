import MapKit
import SwiftUI

struct RealWorldMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let resetToken: Int
    let locationFocusRequest: MapLocationFocusRequest?
    let onResetAvailabilityChange: (Bool) -> Void
    let onOverviewOpacityChange: (Double) -> Void
    let screenFurnitureOpacity: Double
    let onInteractionChange: (Bool) -> Void
    let onUserInteraction: () -> Void
    @State private var position: MapCameraPosition = .region(Self.centralLondon)
    @State private var mapSelection: String?
    @State private var renderData: RealWorldMapRenderData?
    /// Continuous camera state. Only leaf overlays observe it, so a camera
    /// frame never re-evaluates the Map's content builder.
    @State private var camera = GeographicCameraState(region: Self.centralLondon)
    /// Annotation styling changes only when zoom settles. Keep the bounded
    /// station set installed so crossing a culling boundary never rebuilds the
    /// entire SwiftUI Map in the middle of a drag or coast.
    @State private var annotationLevel = GeographicAnnotationLevel(zoom: 0, region: Self.centralLondon)
    /// The Map content last shown while this renderer was active. Reused while
    /// the network map is in front, so its selections and filters do not
    /// update a Map nobody can see.
    @State private var frozenContent: GeographicMapContent?
    @Namespace private var mapScope
    @State private var acceptsCameraUpdates = false
    @State private var resetAvailable = false
    @State private var overviewOpacity = 1.0
    @State private var fittedNetworkZoom: Double?
    @State private var recapturesOverviewZoom = false
    @GestureState private var isTrackingPan = false
    @GestureState private var isTrackingPinch = false

    private static let centralLondon = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5078, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.095, longitudeDelta: 0.15)
    )

    private var mapSurface: some View {
        ZStack {
            if let graph = appState.graph,
               let renderData,
               renderData.graphID == graph.generatedAt {
                GeometryReader { viewportProxy in
                    MapReader { proxy in
                        ZStack {
                            GeographicMapView(
                                content: mapContent(graph: graph, renderData: renderData),
                                selectionValue: mapSelection,
                                position: $position,
                                selection: $mapSelection,
                                scope: mapScope,
                                graphID: graph.generatedAt,
                                viewportSize: viewportProxy.size,
                                camera: camera,
                                reduceMotion: reduceMotion,
                                onCameraChange: { context in
                                    handleCameraChange(context, graph: graph, viewportSize: viewportProxy.size)
                                },
                                onCameraChangeEnd: { context in
                                    commitAnnotationLevel(region: context.region)
                                }
                            )
                            .equatable()
                            .simultaneousGesture(
                                SpatialTapGesture()
                                    .onEnded { value in
                                        onUserInteraction()
                                        handleMapTap(
                                            at: value.location,
                                            proxy: proxy,
                                            graph: graph,
                                            renderData: renderData
                                        )
                                    }
                            )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .updating($isTrackingPan) { _, isTracking, _ in
                                        isTracking = true
                                    }
                            )
                            .simultaneousGesture(
                                MagnifyGesture(minimumScaleDelta: 0.005)
                                    .updating($isTrackingPinch) { _, isTracking, _ in
                                        isTracking = true
                                    }
                            )

                            if appState.river.isEnabled, appState.river.showsBoats,
                               !appState.isOffline, appState.selectedTab == .map,
                               appState.mapPresentationMode == .realWorld {
                                GeographicRiverBoats(proxy: proxy, camera: camera)
                            }
                            if appState.showLiveTrains, appState.selectedTab == .map,
                               appState.mapPresentationMode == .realWorld {
                                RealWorldTrainCanvas(
                                    proxy: proxy,
                                    pathsBySegmentID: renderData.pathsBySegmentID,
                                    camera: camera
                                )
                            }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        MapCompass(scope: mapScope)
                            .opacity(screenFurnitureOpacity)
                            .padding(8)
                    }
                    .overlay(alignment: .topLeading) {
                        MapScaleView(scope: mapScope)
                            .opacity(screenFurnitureOpacity)
                            .padding(8)
                    }
                    .mapScope(mapScope)
                    .onChange(of: mapSelection) { _, stationID in
                        handleMapSelection(stationID, graph: graph)
                    }
                    .onChange(of: appState.mapPresentationMode) { _, mode in
                        acceptsCameraUpdates = false
                        frozenContent = mode == .realWorld
                            ? nil
                            : makeMapContent(graph: graph, renderData: renderData)
                        guard mode == .realWorld else { return }
                        mapSelection = appState.selectedStationID
                        calibrateOverviewZoomFromBeckMap()
                        applySharedViewport(in: viewportProxy.size)
                        focusRiverSelection()
                        if appState.selectedDisruption != nil {
                            focus(on: appState.activeAffectedStationIDs)
                        }
                        Task { @MainActor in
                            await Task.yield()
                            guard appState.mapPresentationMode == .realWorld else { return }
                            acceptsCameraUpdates = true
                        }
                    }
                    .onChange(of: resetToken) { _, _ in
                        guard appState.mapPresentationMode == .realWorld else { return }
                        recapturesOverviewZoom = true
                        resetCamera()
                        setResetAvailable(false)
                        setOverviewOpacity(1)
                    }
                }
            } else {
                ProgressView("Loading geographic map…")
            }
        }
    }

    var body: some View {
        mapSurface
        .onChange(of: appState.cableCar.selectionGeneration) { focusRiverSelection() }
        .onChange(of: appState.river.selectionGeneration) { focusRiverSelection() }
        .onChange(of: appState.focusedStationIDs) { _, stations in
            guard !stations.isEmpty else { return }
            focus(on: stations)
        }
        .onChange(of: isTrackingPan || isTrackingPinch) { _, isInteracting in
            onInteractionChange(isInteracting)
        }
        .onChange(of: locationFocusRequest?.id) { _, _ in
            guard appState.mapPresentationMode == .realWorld,
                  let locationFocusRequest else { return }
            focus(on: locationFocusRequest.coordinate)
        }
        .onChange(of: appState.disruptionSelectionGeneration) { _, _ in
            focus(on: appState.activeAffectedStationIDs)
        }
        .onChange(of: appState.disruptionOverviewFocusGeneration) { _, _ in
            guard appState.mapPresentationMode == .realWorld else { return }
            focus(on: appState.activeAffectedStationIDs)
        }
        .onChange(of: appState.selectedStationID) { _, stationID in
            guard appState.mapPresentationMode == .realWorld else { return }
            mapSelection = stationID
        }
        .onChange(of: appState.stationSelectionGeneration) { _, _ in
            guard appState.mapPresentationMode == .realWorld,
                  let stationID = appState.selectedStationID else { return }
            focus(on: [stationID])
        }
        .onChange(of: appState.trainSelectionGeneration) { _, _ in
            guard appState.mapPresentationMode == .realWorld,
                  let train = appState.selectedTrain,
                  let renderData else { return }
            focus(on: train, renderData: renderData, at: .now)
        }
        .onChange(of: reduceMotion) { _, _ in
            guard appState.mapPresentationMode == .realWorld else { return }
            updateOverviewOpacity(at: calibratedOverviewZoom(for: camera.networkZoom))
        }
        .onAppear(perform: handleAppearance)
        .task(id: appState.graph?.generatedAt) {
            guard let graph = appState.graph else {
                renderData = nil
                return
            }
            let data = RealWorldMapRenderData(graph: graph)
            renderData = data
            frozenContent = appState.mapPresentationMode == .realWorld
                ? nil
                : makeMapContent(graph: graph, renderData: data)
        }
        .onDisappear {
            onInteractionChange(false)
        }
    }

    private func handleAppearance() {
        guard appState.mapPresentationMode == .realWorld else { return }
        if appState.river.hasSelection || appState.cableCar.hasSelection {
            focusRiverSelection()
        } else if let stationID = appState.selectedStationID {
            mapSelection = stationID
            focus(on: [stationID])
        } else if appState.hasFocusedMapSection
            || appState.selectedDisruption != nil
            || appState.isViewingDisruptedLines {
            focus(on: appState.activeAffectedStationIDs)
        }
        Task { @MainActor in
            await Task.yield()
            guard appState.mapPresentationMode == .realWorld else { return }
            acceptsCameraUpdates = true
        }
    }

    private func handleCameraChange(
        _ context: MapCameraUpdateContext,
        graph: TubeGraph,
        viewportSize: CGSize
    ) {
        let viewport = SharedMapProjection.viewport(
            from: context.rect,
            graph: graph,
            size: viewportSize
        )
        camera.update(
            region: context.region,
            heading: context.camera.heading,
            networkZoom: viewport.zoom
        )
        guard appState.mapPresentationMode == .realWorld else { return }
        let overviewZoom = calibratedOverviewZoom(
            for: viewport.zoom
        )
        updateResetAvailability(at: overviewZoom)
        updateOverviewOpacity(at: overviewZoom)
        guard acceptsCameraUpdates else { return }
        appState.sharedMapViewport = viewport
    }

    private func handleMapSelection(_ stationID: String?, graph: TubeGraph) {
        if let id = stationID, id.hasPrefix("cable:"),
           let terminal = appState.cableCar.network.terminals.first(where: { $0.id == String(id.dropFirst(6)) }) {
            if appState.cableCar.selectedTerminalID != terminal.id { appState.selectCableCar(terminal: terminal) }
            return
        }
        if let id = stationID, id.hasPrefix("pier:"),
           let pier = appState.river.network.pier(String(id.dropFirst(5))) {
            if appState.river.selectedPierId != pier.id { appState.select(pier: pier) }
            return
        }
        guard let stationID = RealWorldMapSelectionPolicy.stationIDToSelect(
            mapSelection: stationID,
            selectedStationID: appState.selectedStationID,
            presentationMode: appState.mapPresentationMode
        ),
              let station = graph.stationsByID[stationID] else { return }
        withAnimation(.smooth(duration: 0.35)) {
            appState.select(station: station)
        }
    }

    /// While the network map is in front, the hidden geographic Map keeps the
    /// content it last showed. Reading no other app state here means hidden
    /// selection and filter changes do not re-evaluate this screen's Map.
    private func mapContent(
        graph: TubeGraph,
        renderData: RealWorldMapRenderData
    ) -> GeographicMapContent {
        if appState.mapPresentationMode != .realWorld, let frozenContent {
            return frozenContent
        }
        return makeMapContent(graph: graph, renderData: renderData)
    }

    private func makeMapContent(
        graph: TubeGraph,
        renderData: RealWorldMapRenderData
    ) -> GeographicMapContent {
        var content = GeographicMapContent()
        content.routes = tubeRoutes(renderData: renderData)
        content.stations = stationMarkers(graph: graph)
        content.markerDiameter = annotationLevel.markerDiameter
        content.expandedSymbols = annotationLevel.showsNames
        if appState.river.isEnabled {
            content.riverSegments = appState.river.geographicSegments.map {
                GeographicMapContent.RiverSegment(id: $0.id, coordinates: $0.coordinates)
            }
            let selectedPierID = appState.river.selectedPierId
            content.piers = visibleRiverPiers.map { pier in
                GeographicMapContent.Pier(
                    pier: pier,
                    showsName: annotationLevel.showsFeatureNames || pier.id == selectedPierID,
                    selected: pier.id == selectedPierID
                )
            }
        }
        if appState.cableCar.isEnabled {
            let cable = appState.cableCar
            let walkingConnection = cable.selectedTerminal.flatMap { terminal in
                terminal.railStationID.flatMap { graph.stationsByID[$0] }.map { rail in
                    GeographicMapContent.CableCar.WalkingConnection(
                        terminalLatitude: terminal.latitude,
                        terminalLongitude: terminal.longitude,
                        stationLatitude: rail.coordinate.latitude,
                        stationLongitude: rail.coordinate.longitude
                    )
                }
            }
            content.cableCar = GeographicMapContent.CableCar(
                route: cable.network.coordinates.map(\.location),
                terminals: cable.network.terminals,
                selectedTerminalID: cable.selectedTerminalID,
                showsTerminalNames: annotationLevel.showsFeatureNames || cable.hasSelection,
                presentation: cable.presentation,
                walkingConnection: walkingConnection
            )
        }
        return content
    }

    private func tubeRoutes(renderData: RealWorldMapRenderData) -> [GeographicMapContent.Route] {
        let networkSummary = appState.mapNetworkStatusSummary
        let networkFilter = appState.selectedMapNetworkStat
        let featuredLineIDs = networkFilter.map(networkSummary.lineIDs(for:)) ?? []
        let disruptionScope = appState.disruptionHighlightScope
        let filtersDisruptedSections = disruptionScope != nil
        let filteredDisruptions = appState.visibleDisruptions.filter { disruption in
            disruptionScope?.includes(disruption) == true
                && featuredLineIDs.contains(disruption.lineID)
        }
        let featuredSegmentIDs = Set(filteredDisruptions.flatMap(\.affectedSegmentIDs))
        let sectionLineIDs = Set(filteredDisruptions.compactMap { disruption in
            disruption.affectedSegmentIDs.isEmpty ? nil : disruption.lineID
        })
        let affectedSegmentIDs = filtersDisruptedSections
            ? featuredSegmentIDs
            : appState.activeAffectedSegmentIDs
        let displayMode = appState.disruptionDisplayMode
        let selectedLineID = appState.selectedLineID
        let unaffectedSegmentIDs = Set(renderData.segments.map(\.id))
            .subtracting(affectedSegmentIDs)
        let unaffectedPolylines = renderData.polylines(covering: unaffectedSegmentIDs)
        let affectedPolylines = renderData.polylines(covering: affectedSegmentIDs)
        let mobileCoverageMode = appState.mobileCoverageMode
        let mobileCoverage = appState.mobileCoverage
        let mutedColor = Color.secondary.opacity(0.24)
        var routes: [GeographicMapContent.Route] = []

        for polyline in unaffectedPolylines {
            let muted = mobileCoverageMode.isActive || MapNetworkRouteStyling.mutesSegment(
                lineID: polyline.lineID,
                isAffected: false,
                isFeaturedSection: !featuredSegmentIDs.isDisjoint(with: polyline.segmentIDs),
                selectedFilter: networkFilter,
                featuredLineIDs: featuredLineIDs,
                sectionLineIDs: sectionLineIDs,
                closedLineIDs: networkSummary.closedLineIDs,
                disruptionDisplayMode: displayMode
            )
                || (selectedLineID != nil && selectedLineID != polyline.lineID)
            routes.append(.init(
                id: "route:\(polyline.id)", overlay: polyline.overlay,
                color: muted ? mutedColor : .tubeLine(polyline.lineID), lineWidth: 4
            ))
        }

        for polyline in affectedPolylines {
            let muted = MapNetworkRouteStyling.mutesSegment(
                lineID: polyline.lineID,
                isAffected: true,
                isFeaturedSection: !featuredSegmentIDs.isDisjoint(with: polyline.segmentIDs),
                selectedFilter: networkFilter,
                featuredLineIDs: featuredLineIDs,
                sectionLineIDs: sectionLineIDs,
                closedLineIDs: networkSummary.closedLineIDs,
                disruptionDisplayMode: displayMode
            )
            routes.append(.init(
                id: "affected:\(polyline.id)", overlay: polyline.overlay,
                color: muted ? mutedColor : .tubeLine(polyline.lineID), lineWidth: 4
            ))
        }

        if displayMode == .issues {
            routes += affectedPolylines.map {
                .init(id: "issue-outer:\($0.id)", overlay: $0.overlay, color: .red.opacity(0.82), lineWidth: 8)
            }
            routes += affectedPolylines.map {
                .init(id: "issue-knockout:\($0.id)", overlay: $0.overlay, color: .white, lineWidth: 6)
            }
            routes += affectedPolylines.map {
                .init(id: "issue-route:\($0.id)", overlay: $0.overlay, color: .tubeLine($0.lineID), lineWidth: 4)
            }
        }

        if mobileCoverageMode.isActive {
            let graphSegmentsByID = appState.graph?.segmentsByID
            var availableSegmentIDs: Set<String> = []
            var unknownSegmentIDs: Set<String> = []
            for segment in renderData.segments {
                guard let graphSegment = graphSegmentsByID?[segment.id] else { continue }
                switch mobileCoverage?.availability(for: graphSegment, mode: mobileCoverageMode) {
                case .available: availableSegmentIDs.insert(segment.id)
                case .unknown: unknownSegmentIDs.insert(segment.id)
                default: break
                }
            }
            routes += renderData.polylines(covering: availableSegmentIDs).map {
                .init(id: "coverage:\($0.id)", overlay: $0.overlay, color: .tubeLine($0.lineID), lineWidth: 4)
            }
            routes += renderData.polylines(covering: unknownSegmentIDs).map {
                .init(
                    id: "coverage-unknown:\($0.id)", overlay: $0.overlay,
                    color: .orange.opacity(0.72), lineWidth: 4, dash: [8, 6]
                )
            }
        }
        return routes
    }

    private var visibleRiverPiers: [RiverPier] {
        appState.river.filteredPiers.filter { pier in
            pier.id == appState.river.selectedPierId || annotationLevel.showsAllPiers
                || appState.river.anchors.first(where: { $0.id == pier.id })?.major == true
        }
    }

    private func focusRiverSelection() {
        guard appState.mapPresentationMode == .realWorld else { return }
        if appState.cableCar.hasSelection {
            focus(on: appState.cableCar.selectedTerminal?.coordinate ?? CLLocationCoordinate2D(latitude: 51.50365, longitude: 0.013), riverSelection: true)
        } else if let pier = appState.river.selectedPier { focus(on: pier.coordinate, riverSelection: true) }
        else if let boat = appState.river.selectedBoat,
                let coordinate = appState.river.boatCoordinate(for: boat, at: .now) {
            focus(on: coordinate, riverSelection: true)
        }
    }

    private func stationMarkers(graph: TubeGraph) -> [GeographicMapContent.Station] {
        let selectedStationID = appState.selectedStationID
        guard annotationLevel.showsRoundels || selectedStationID != nil else { return [] }
        let coverageMode = appState.mobileCoverageMode
        let coverage = appState.mobileCoverage
        return displayStations(graph: graph)
            .filter { annotationLevel.showsRoundels || $0.id == selectedStationID }
            .map { station in
                let selected = selectedStationID == station.id
                let availability = coverage?.availability(for: station.id, mode: coverageMode) ?? .outOfScope
                let stationOnly = coverageMode.isActive
                    && coverage?.stationOnlyCoverageStationIDs.contains(station.id) == true
                return GeographicMapContent.Station(
                    id: station.id,
                    name: station.name,
                    latitude: station.coordinate.latitude,
                    longitude: station.coordinate.longitude,
                    showsName: selected || annotationLevel.showsNames,
                    selected: selected,
                    opacity: stationMarkerOpacity(availability, selected: selected),
                    stationOnlyCoverage: stationOnly,
                    accessibilityLabel: stationCoverageAccessibilityLabel(
                        station: station,
                        availability: availability,
                        stationOnly: stationOnly
                    )
                )
            }
    }

    private func stationMarkerOpacity(
        _ availability: MobileCoverageAvailability,
        selected: Bool
    ) -> Double {
        guard appState.mobileCoverageMode.isActive, !selected else { return 1 }
        switch availability {
        case .available: return 1
        case .unavailable: return 0.42
        case .unknown: return 0.72
        case .outOfScope: return 0.22
        }
    }

    private func stationCoverageAccessibilityLabel(
        station: TubeStation,
        availability: MobileCoverageAvailability,
        stationOnly: Bool
    ) -> String {
        guard appState.mobileCoverageMode.isActive else { return station.name }
        if stationOnly {
            return "\(station.name), mobile coverage in station only"
        }
        let coverageDescription = switch availability {
        case .available: "mobile coverage available"
        case .unavailable: "no verified mobile coverage"
        case .unknown: "mobile coverage unknown"
        case .outOfScope: "outside the underground coverage view"
        }
        return "\(station.name), \(coverageDescription)"
    }

    private func displayStations(graph: TubeGraph) -> [TubeStation] {
        let selectedStationID = appState.selectedStationID
        return renderData?.displayStations(selectedStationID: selectedStationID)
            ?? RealWorldStationDisplay.stations(in: graph, selectedStationID: selectedStationID)
    }

    /// Zoom styling (roundels, names, symbol sizes) changes once the camera
    /// settles rather than repeatedly during a pinch or animated move.
    private func commitAnnotationLevel(region: MKCoordinateRegion) {
        guard appState.mapPresentationMode == .realWorld else { return }
        let level = GeographicAnnotationLevel(zoom: camera.networkZoom, region: region)
        if level != annotationLevel { annotationLevel = level }
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

    private func handleMapTap(
        at location: CGPoint,
        proxy: MapProxy,
        graph: TubeGraph,
        renderData: RealWorldMapRenderData
    ) {
        if appState.cableCar.isEnabled {
            for terminal in appState.cableCar.network.terminals {
                if let point = proxy.convert(terminal.coordinate, to: .local), hypot(point.x - location.x, point.y - location.y) < 22 {
                    appState.selectCableCar(terminal: terminal); return
                }
            }
            let points = appState.cableCar.network.coordinates.compactMap { proxy.convert($0.location, to: .local) }
            if let distance = RealWorldLineHitTesting.distance(from: location, toPolyline: points), distance < 16 {
                appState.selectCableCar(); return
            }
        }
        if appState.river.isEnabled {
            if appState.river.showsBoats, !appState.isOffline {
                for boat in appState.river.filteredBoats {
                    if let coordinate = appState.river.boatCoordinate(for: boat, at: .now),
                       let point = proxy.convert(coordinate, to: .local), hypot(point.x - location.x, point.y - location.y) < 22 {
                        appState.select(boat: boat); return
                    }
                }
            }
            let candidates = visibleRiverPiers.compactMap { pier -> (RiverPier, CGFloat)? in
                guard let point = proxy.convert(pier.coordinate, to: .local) else { return nil }
                return (pier, hypot(point.x - location.x, point.y - location.y))
            }
            if let hit = candidates.min(by: { $0.1 < $1.1 }), hit.1 < 22 {
                if appState.river.selectedPierId != hit.0.id { appState.select(pier: hit.0) }
                return
            }
        }
        if appState.showLiveTrains,
           let train = train(
               at: location,
               date: .now,
               proxy: proxy,
               renderData: renderData
           ) {
            withAnimation(.smooth(duration: 0.25)) {
                appState.select(train: train)
            }
            return
        }

        appState.selectedTrainID = nil
        handleLineTap(
            at: location,
            proxy: proxy,
            graph: graph,
            renderData: renderData
        )
    }

    private func train(
        at location: CGPoint,
        date: Date,
        proxy: MapProxy,
        renderData: RealWorldMapRenderData
    ) -> LiveTubeTrain? {
        let candidates = appState.liveTrains.compactMap { train
            -> (train: LiveTubeTrain, point: CGPoint)? in
            guard let path = renderData.pathsBySegmentID[train.segmentID],
                  let progress = LiveTrainMarkerPolicy.projectedProgress(
                      for: train,
                      at: date,
                      stationBoard: appState.authoritativeStationBoardSnapshot
                  ),
                  let coordinate = path.coordinate(
                      at: progress,
                      previousStationID: train.previousStationID,
                      nextStationID: train.nextStationID
                  ),
                  let point = proxy.convert(coordinate, to: .local) else { return nil }
            return (train, point)
        }
        return LiveTrainHitTesting.nearest(to: location, candidates: candidates)
    }

    private func resetCamera() {
        position = .region(Self.centralLondon)
        appState.clearMapSelection()
    }

    private func calibrateOverviewZoomFromBeckMap() {
        guard let viewport = appState.sharedMapViewport,
              let camera = appState.beckMapCameraSnapshot else {
            fittedNetworkZoom = nil
            return
        }
        // The geographic graph contains outlying stations, so its raw fitted zoom
        // is not the visible Tube-map overview. Remove the Beck camera's current
        // zoom to recover the equivalent fitted geographic baseline.
        let beckZoom = camera.scale / max(0.000_001, camera.fittedScale)
        fittedNetworkZoom = viewport.zoom / max(0.000_001, beckZoom)
    }

    private func calibratedOverviewZoom(for networkZoom: Double) -> Double {
        if recapturesOverviewZoom || fittedNetworkZoom == nil {
            fittedNetworkZoom = max(0.000_001, networkZoom)
            recapturesOverviewZoom = false
        }
        return networkZoom / max(0.000_001, fittedNetworkZoom ?? networkZoom)
    }

    private func updateResetAvailability(at overviewZoom: Double) {
        setResetAvailable(RealWorldMapOverviewVisibilityPolicy.shouldShowReset(
            at: overviewZoom
        ))
    }

    private func updateOverviewOpacity(at overviewZoom: Double) {
        setOverviewOpacity(RealWorldMapOverviewVisibilityPolicy.opacity(
            at: overviewZoom,
            reduceMotion: reduceMotion
        ))
    }

    private func setOverviewOpacity(_ opacity: Double) {
        guard abs(opacity - overviewOpacity) > 0.001 else { return }
        overviewOpacity = opacity
        onOverviewOpacityChange(opacity)
    }

    private func setResetAvailable(_ available: Bool) {
        guard available != resetAvailable else { return }
        resetAvailable = available
        onResetAvailabilityChange(available)
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

    private func focus(on coordinate: CLLocationCoordinate2D, riverSelection: Bool = false) {
        // Reserve space below the selected pier for its board and map controls.
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude - (riverSelection ? 0.0038 : 0), longitude: coordinate.longitude)
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.02)
        )
        withAnimation(.easeInOut(duration: 0.8)) {
            position = .region(region)
        }
        setResetAvailable(true)
    }

    private func focus(
        on train: LiveTubeTrain,
        renderData: RealWorldMapRenderData,
        at date: Date
    ) {
        guard let path = renderData.pathsBySegmentID[train.segmentID],
              let progress = LiveTrainMarkerPolicy.projectedProgress(
                  for: train,
                  at: date,
                  stationBoard: appState.authoritativeStationBoardSnapshot
              ),
              let coordinate = path.coordinate(
                  at: progress,
                  previousStationID: train.previousStationID,
                  nextStationID: train.nextStationID
              ) else { return }
        let region = TrainMapFocusPolicy.geographicRegion(
            centeredAt: coordinate,
            currentSpan: camera.region.span
        )

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                position = .region(region)
            }
        } else {
            withAnimation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.45)) {
                position = .region(region)
            }
        }
        setResetAvailable(true)
    }

}

/// The renderer's own state, environment and observed app state still drive
/// its updates. Comparing only the value inputs lets SwiftUI skip it when the
/// parent's chrome changes; the callbacks capture only the parent's stable
/// state storage, so ignoring them cannot leave a stale handler behind.
extension RealWorldMapScreen: @MainActor Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resetToken == rhs.resetToken
            && lhs.locationFocusRequest == rhs.locationFocusRequest
            && lhs.screenFurnitureOpacity == rhs.screenFurnitureOpacity
    }
}

enum RealWorldMapOverviewVisibilityPolicy {
    static let fullyVisibleMaximumZoomRatio = 1.08
    static let hiddenZoomRatio = 1.55

    static func opacity(
        at networkZoomRatio: Double,
        reduceMotion: Bool = false
    ) -> Double {
        if reduceMotion {
            return networkZoomRatio < hiddenZoomRatio ? 1 : 0
        }
        guard networkZoomRatio > fullyVisibleMaximumZoomRatio else { return 1 }
        guard networkZoomRatio < hiddenZoomRatio else { return 0 }
        let fadeProgress = (networkZoomRatio - fullyVisibleMaximumZoomRatio)
            / (hiddenZoomRatio - fullyVisibleMaximumZoomRatio)
        return 1 - fadeProgress
    }

    static func shouldShowReset(at networkZoomRatio: Double) -> Bool {
        networkZoomRatio > fullyVisibleMaximumZoomRatio
    }
}

enum RealWorldMapSelectionPolicy {
    static func stationIDToSelect(
        mapSelection: String?,
        selectedStationID: String?,
        presentationMode: MapPresentationMode
    ) -> String? {
        // Both map renderers stay mounted during mode transitions. Only a new,
        // user-driven selection on the active geographic map may select again.
        guard presentationMode == .realWorld,
              mapSelection != selectedStationID else {
            return nil
        }
        return mapSelection
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
    let camera: GeographicCameraState

    var body: some View {
        // Observing the camera here keeps per-frame motion inside this layer.
        let visibleRegion = camera.region
        let trains = appState.liveTrains
        let stationsByID = appState.graph?.stationsByID ?? [:]
        let closedLineIDs = appState.currentlyClosedLineIDs
        let stationBoard = appState.authoritativeStationBoardSnapshot

        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            GeometryReader { viewport in
                ZStack {
                    Canvas { context, size in
                        let visibleBounds = CGRect(origin: .zero, size: size)
                            .insetBy(dx: -12, dy: -12)

                        var markerRenderer = LiveTrainMarkerRenderer()
                        for train in trains {
                            guard let point = markerPoint(
                                for: train,
                                at: timeline.date,
                                visibleBounds: visibleBounds, stationBoard: stationBoard,
                                visibleRegion: visibleRegion
                            ) else { continue }

                            let selected = train.id == appState.selectedTrainID
                            let diameter: CGFloat = selected ? 28 : 22
                            let markerRect = CGRect(
                                x: point.x - diameter / 2,
                                y: point.y - diameter / 2,
                                width: diameter,
                                height: diameter
                            )
                            if selected {
                                let halo = Path(ellipseIn: markerRect.insetBy(dx: -5, dy: -5))
                                context.fill(
                                    halo,
                                    with: .color(Color.tubeLine(train.lineID).opacity(0.18))
                                )
                            }
                            let servicePresentation = LiveTrainServicePresentation.resolve(
                                lineID: train.lineID,
                                closedLineIDs: closedLineIDs
                            )
                            markerRenderer.draw(
                                presentation: servicePresentation,
                                lineID: train.lineID,
                                context: &context,
                                in: markerRect
                            )
                        }
                    }
                    .allowsHitTesting(false)

                    ForEach(trains) { train in
                        if let point = markerPoint(
                            for: train,
                            at: timeline.date,
                            visibleBounds: CGRect(origin: .zero, size: viewport.size), stationBoard: stationBoard,
                            visibleRegion: visibleRegion
                        ) {
                            Button {
                                withAnimation(.smooth(duration: 0.25)) {
                                    appState.select(train: train)
                                }
                            } label: {
                                Color.clear
                                    .frame(width: 44, height: 44)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .position(point)
                            .accessibilityLabel(accessibilityLabel(for: train, stationsByID: stationsByID, closedLineIDs: closedLineIDs))
                            .accessibilityHint("Shows this train's next stop and arrival time")
                        }
                    }

                    if let train = appState.selectedTrain,
                       let markerPoint = markerPoint(
                           for: train,
                           at: timeline.date,
                           visibleBounds: CGRect(origin: .zero, size: viewport.size), stationBoard: stationBoard,
                           visibleRegion: visibleRegion
                       ),
                       let nextStopName = stationsByID[train.callingStationID]?.name {
                        TrainMapCalloutOverlay(
                            train: train,
                            servicePresentation: .resolve(
                                lineID: train.lineID,
                                closedLineIDs: closedLineIDs
                            ),
                            nextStopName: nextStopName,
                            date: timeline.date,
                            markerPoint: markerPoint,
                            viewportSize: viewport.size
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Estimated live train positions")
    }

    private func markerPoint(
        for train: LiveTubeTrain,
        at date: Date,
        visibleBounds: CGRect,
        stationBoard: LiveTrainStationBoardSnapshot?,
        visibleRegion: MKCoordinateRegion
    ) -> CGPoint? {
        guard let path = pathsBySegmentID[train.segmentID],
              let progress = LiveTrainMarkerPolicy.projectedProgress(
                  for: train,
                  at: date,
                  stationBoard: stationBoard
              ),
              let coordinate = path.coordinate(
                  at: progress,
                  previousStationID: train.previousStationID,
                  nextStationID: train.nextStationID
              ),
              visibleRegion.containsExpanded(coordinate),
              let point = proxy.convert(coordinate, to: .local),
              visibleBounds.contains(point) else { return nil }
        return point
    }

    private func accessibilityLabel(for train: LiveTubeTrain, stationsByID: [String: TubeStation],
                                    closedLineIDs: Set<TubeLineID>) -> String {
        let destination = train.destination ?? "unknown destination"
        let nextStop = stationsByID[train.nextStationID]?.name
            ?? "unknown next stop"
        let summary: String
        if let direction = LiveTrainDirection.displayName(for: train.direction) {
            summary = "\(direction) train to \(destination), next stop \(nextStop)"
        } else {
            summary = "Train to \(destination), next stop \(nextStop)"
        }
        let presentation = LiveTrainServicePresentation.resolve(
            lineID: train.lineID,
            closedLineIDs: closedLineIDs
        )
        guard let note = presentation.informationalNote(for: train.lineID) else {
            return summary
        }
        return "\(summary). \(note)"
    }
}

/// Per-frame geographic camera values for overlays drawn with `MapProxy`.
/// Kept out of `RealWorldMapScreen`'s own state so camera motion does not
/// rebuild the Map content (overlays, annotations, map style) every frame.
@MainActor
@Observable
final class GeographicCameraState {
    private(set) var region: MKCoordinateRegion
    private(set) var heading: Double = 0
    @ObservationIgnored private(set) var networkZoom: Double = 0

    init(region: MKCoordinateRegion) {
        self.region = region
    }

    func update(region: MKCoordinateRegion, heading: Double, networkZoom: Double) {
        self.region = region
        if self.heading != heading { self.heading = heading }
        self.networkZoom = networkZoom
    }
}

/// Zoom-dependent annotation styling, quantised to the values that actually
/// change what MapKit draws.
struct GeographicAnnotationLevel: Equatable {
    let showsRoundels: Bool
    let showsNames: Bool
    let showsFeatureNames: Bool
    let showsAllPiers: Bool
    let markerDiameter: CGFloat

    init(zoom: Double, region: MKCoordinateRegion) {
        showsRoundels = RealWorldStationVisibilityPolicy.showsRoundel(at: zoom)
        showsNames = RealWorldStationVisibilityPolicy.showsName(at: zoom)
        showsFeatureNames = zoom >= 2
        showsAllPiers = region.span.longitudeDelta < 0.12
        // 5, 7, 9 or 11 points: coarse steps keep camera jitter at a
        // boundary from producing a whole Map content update.
        markerDiameter = max(5, min(11, 3 + 2 * (CGFloat(zoom).rounded(.down))))
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

@MainActor
struct RealWorldMapRenderData {
    let graphID: String
    let segments: [RealWorldRenderedSegment]
    let polylines: [RealWorldRenderedPolyline]
    let pathsBySegmentID: [String: RealWorldRenderPath]
    /// One representative per interchange hub, sorted by name.
    private let displayStationGroups: [(representative: TubeStation, members: [TubeStation])]
    private let allSegmentIDs: Set<String>
    private let overlayCache = OverlayCache()

    private final class OverlayCache {
        // Four groups are used per render (affected/unaffected and two coverage
        // groups). Retain a small bounded working set across presentation changes.
        var entries: [(ids: Set<String>, polylines: [RealWorldRenderedPolyline])] = []
    }

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
        allSegmentIDs = Set(renderedSegments.map(\.id))
        polylines = RealWorldPolylineBuilder.polylines(from: renderedSegments)
        pathsBySegmentID = Dictionary(uniqueKeysWithValues: renderedSegments.map { ($0.id, $0.path) })
        displayStationGroups = RealWorldStationDisplay.groups(in: graph)
    }

    /// Matches `RealWorldStationDisplay.stations` without regrouping and
    /// sorting the whole graph on every Map content update.
    func displayStations(selectedStationID: String?) -> [TubeStation] {
        guard let selectedStationID,
              let groupIndex = displayStationGroups.firstIndex(where: { group in
                  group.representative.id != selectedStationID
                      && group.members.contains { $0.id == selectedStationID }
              }) else {
            return displayStationGroups.map(\.representative)
        }
        var stations = displayStationGroups.map(\.representative)
        stations[groupIndex] = displayStationGroups[groupIndex].members.first {
            $0.id == selectedStationID
        } ?? stations[groupIndex]
        return stations.sorted { $0.name < $1.name }
    }

    func polylines(covering segmentIDs: Set<String>) -> [RealWorldRenderedPolyline] {
        guard !segmentIDs.isEmpty else { return [] }
        if segmentIDs == allSegmentIDs { return polylines }
        if let cached = overlayCache.entries.first(where: { $0.ids == segmentIDs }) {
            return cached.polylines
        }
        let result = RealWorldPolylineBuilder.polylines(
            from: segments.filter { segmentIDs.contains($0.id) }
        )
        if overlayCache.entries.count == 8 { overlayCache.entries.removeFirst() }
        overlayCache.entries.append((segmentIDs, result))
        return result
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
    private let fromStationID: String
    private let toStationID: String
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
        fromStationID = segment.fromStationID
        toStationID = segment.toStationID
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

    func coordinate(
        at progress: Double,
        previousStationID: String,
        nextStationID: String
    ) -> CLLocationCoordinate2D? {
        let followsStoredDirection = previousStationID == fromStationID && nextStationID == toStationID
        let runsAgainstStoredDirection = previousStationID == toStationID && nextStationID == fromStationID
        guard followsStoredDirection || runsAgainstStoredDirection else { return nil }
        return coordinate(at: runsAgainstStoredDirection ? 1 - progress : progress)
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
             .suffragette, .weaver, .windrush, .thameslink: 0
        }
    }
}

enum RealWorldStationDisplay {
    static func stations(
        in graph: TubeGraph,
        selectedStationID: String?
    ) -> [TubeStation] {
        hubGroups(in: graph)
            .compactMap { representative(in: $0, selectedStationID: selectedStationID) }
            .sorted { $0.name < $1.name }
    }

    /// The unselected representatives with their hub members, sorted by name.
    static func groups(
        in graph: TubeGraph
    ) -> [(representative: TubeStation, members: [TubeStation])] {
        hubGroups(in: graph)
            .compactMap { group in
                representative(in: group, selectedStationID: nil).map { ($0, group) }
            }
            .sorted { $0.representative.name < $1.representative.name }
    }

    private static func hubGroups(in graph: TubeGraph) -> Dictionary<String, [TubeStation]>.Values {
        Dictionary(grouping: graph.stations) { $0.hubID ?? $0.id }.values
    }

    private static func representative(
        in group: [TubeStation],
        selectedStationID: String?
    ) -> TubeStation? {
        group.first(where: { $0.id == selectedStationID })
            ?? group.sorted {
                if $0.lineIDs.count != $1.lineIDs.count {
                    return $0.lineIDs.count > $1.lineIDs.count
                }
                return $0.id < $1.id
            }.first
    }
}

enum RealWorldStationVisibilityPolicy {
    /// The fitted Beck-to-real-world viewport is approximately 4.1 on an
    /// iPhone. Keeping both thresholds above that value leaves the overview
    /// clear, while separate thresholds reveal roundels before station names.
    static let roundelMinimumZoom = 5.5
    static let nameMinimumZoom = 6.25

    static func showsRoundel(at zoom: Double, isSelected: Bool = false) -> Bool {
        isSelected || zoom >= roundelMinimumZoom
    }

    static func showsName(at zoom: Double, isSelected: Bool = false) -> Bool {
        isSelected || zoom >= nameMinimumZoom
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
