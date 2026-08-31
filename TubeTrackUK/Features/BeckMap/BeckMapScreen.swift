import SwiftUI
import UIKit

private enum BeckMapCameraEasing {
    case smoothStep
    case easeOutQuart

    func value(at progress: Double) -> Double {
        switch self {
        case .smoothStep:
            progress * progress * (3 - 2 * progress)
        case .easeOutQuart:
            1 - pow(1 - progress, 4)
        }
    }
}

struct BeckMapPresentationSnapshot: Equatable, Sendable {
    let selectedLineID: TubeLineID?
    let selectedStationID: String?
    let affectedSegmentIDs: Set<String>
    let affectedStationIDs: Set<String>
    let disruptionDisplayMode: DisruptionDisplayMode
    let networkFilter: MapNetworkStatFilter?
    let networkFeaturedLineIDs: Set<TubeLineID>
    let networkFeaturedSegmentIDs: Set<String>
    let networkSectionLineIDs: Set<TubeLineID>
    let closedLineIDs: Set<TubeLineID>

    var emphasizesIssues: Bool {
        disruptionDisplayMode == .issues
    }

    func mutesSegment(id: String, lineID: TubeLineID, isAffected: Bool) -> Bool {
        MapNetworkRouteStyling.mutesSegment(
            lineID: lineID,
            isAffected: isAffected,
            isFeaturedSection: networkFeaturedSegmentIDs.contains(id),
            selectedFilter: networkFilter,
            featuredLineIDs: networkFeaturedLineIDs,
            sectionLineIDs: networkSectionLineIDs,
            closedLineIDs: closedLineIDs,
            disruptionDisplayMode: disruptionDisplayMode
        )
    }
}

struct BeckMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    let resetToken: Int
    let locationFocusRequest: MapLocationFocusRequest?
    let contentVerticalBias: CGFloat
    let onUserZoomIn: () -> Void
    @State private var document: BeckMapDocument?
    @State private var renderCache: BeckMapCanvas.RenderCache?
    @State private var documentLoadError: String?
    @State private var loadedGraphGeneratedAt: String?
    @State private var isLoadingDocument = false
    @State private var selectedRegion: BeckMapRegion = Self.initialRegion
    #if DEBUG
    @State private var showsReferenceOverlay = ProcessInfo.processInfo.arguments.contains("-DebugBeckReference")
    #endif

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if let graph = appState.graph,
               let document,
               let renderCache,
               loadedGraphGeneratedAt == graph.generatedAt {
                BeckMapCanvas(
                    document: document,
                    renderCache: renderCache,
                    presentation: presentation(document: document, graph: graph),
                    disruptionIDsBySegmentID: projectedDisruptionIDsBySegmentID(
                        document: document,
                        graph: graph
                    ),
                    liveTrains: appState.showLiveTrains && appState.selectedTab == .map
                        ? appState.liveTrains
                        : [],
                    referenceOverlayVisible: referenceOverlayVisible,
                    resetToken: resetToken,
                    locationFocusRequest: locationFocusRequest,
                    contentVerticalBias: contentVerticalBias,
                    onUserZoomIn: onUserZoomIn,
                    stationSelectionGeneration: appState.stationSelectionGeneration,
                    onStationTap: { stationID in
                        guard let station = graph.stationsByID[stationID] else { return }
                        withAnimation(.smooth(duration: 0.35)) {
                            appState.select(station: station)
                        }
                    },
                    onDisruptionTap: { disruptionID in
                        guard let disruption = appState.visibleDisruptions.first(where: {
                            $0.id == disruptionID
                        }) else { return }
                        withAnimation(.smooth(duration: 0.35)) {
                            appState.select(disruption: disruption)
                        }
                    },
                    onBackgroundTap: appState.clearMapSelection
                )
                .id("\(document.identifier):\(graph.generatedAt)")
                .ignoresSafeArea(edges: .top)
            } else if appState.graph != nil, let documentLoadError {
                ContentUnavailableView(
                    "Map unavailable",
                    systemImage: "map.fill",
                    description: Text(documentLoadError)
                )
            } else if appState.graph != nil || isLoadingDocument {
                ProgressView("Loading London rail map…")
            } else if appState.isLoadingGraph {
                ProgressView("Loading London rail map…")
            } else {
                ContentUnavailableView(
                    "Map unavailable",
                    systemImage: "map.fill",
                    description: Text(appState.statusError ?? "The Tube network data could not be loaded.")
                )
            }
        }
        .task(id: documentTaskID) {
            document = nil
            renderCache = nil
            documentLoadError = nil
            loadedGraphGeneratedAt = nil
            guard let graph = appState.graph else {
                isLoadingDocument = false
                return
            }
            isLoadingDocument = true
            defer { isLoadingDocument = false }
            do {
                let loadedDocument = try BeckMapRepository().load(
                    region: selectedRegion,
                    graph: graph
                )
                renderCache = BeckMapCanvas.RenderCache(
                    document: loadedDocument,
                    loadsDebugReference: referenceOverlayVisible
                )
                document = loadedDocument
                loadedGraphGeneratedAt = graph.generatedAt
            } catch {
                documentLoadError = error.localizedDescription
            }
        }
    }

    private var documentTaskID: String {
        "\(appState.graph?.generatedAt ?? "no-graph"):\(selectedRegion.rawValue)"
    }

    private static var initialRegion: BeckMapRegion {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let argumentIndex = arguments.firstIndex(of: "-DebugBeckRegion"),
           arguments.indices.contains(argumentIndex + 1),
           let region = BeckMapRegion(rawValue: arguments[argumentIndex + 1]) {
            return region
        }
        #endif
        return .fullUnderground
    }

    private var referenceOverlayVisible: Bool {
        #if DEBUG
        showsReferenceOverlay
        #else
        false
        #endif
    }

    private func presentation(
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> BeckMapPresentationSnapshot {
        let projector = BeckMapAffectedSegmentProjector(document: document, graph: graph)
        let affectedSegmentIDs: Set<String>
        let networkSummary = appState.mapNetworkStatusSummary
        let networkFilter = appState.selectedMapNetworkStat
        let networkFeaturedLineIDs = networkFilter.map(networkSummary.lineIDs(for:)) ?? []
        var networkFeaturedSegmentIDs: Set<String> = []
        var networkSectionLineIDs: Set<TubeLineID> = []

        if networkFilter == .majorIssues || networkFilter == .disrupted {
            for disruption in appState.visibleDisruptions
                where (networkFilter == .disrupted || disruption.isMajorIssue)
                    && networkFeaturedLineIDs.contains(disruption.lineID) {
                let projectedIDs = projector.projectedSegmentIDs(for: disruption)
                networkFeaturedSegmentIDs.formUnion(projectedIDs)
                if !projectedIDs.isEmpty {
                    networkSectionLineIDs.insert(disruption.lineID)
                }
            }
            affectedSegmentIDs = networkFeaturedSegmentIDs
        } else if appState.hasFocusedMapSection {
            let lineIDs = appState.focusedLineIDs.isEmpty
                ? Set(appState.selectedLineID.map { [$0] } ?? [])
                : appState.focusedLineIDs
            affectedSegmentIDs = Set(lineIDs.flatMap { lineID in
                projector.projectedSegmentIDs(
                    for: appState.focusedSegmentIDs,
                    on: lineID,
                    confidence: appState.focusedResolutionConfidence ?? .inferred
                )
            })
        } else if let disruption = appState.selectedDisruption {
            affectedSegmentIDs = projector.projectedSegmentIDs(for: disruption)
        } else {
            affectedSegmentIDs = Set(appState.highlightedDisruptions.flatMap {
                projector.projectedSegmentIDs(for: $0)
            })
        }

        return BeckMapPresentationSnapshot(
            selectedLineID: appState.selectedLineID,
            selectedStationID: appState.selectedStationID,
            affectedSegmentIDs: affectedSegmentIDs,
            affectedStationIDs: appState.activeAffectedStationIDs,
            disruptionDisplayMode: appState.disruptionDisplayMode,
            networkFilter: networkFilter,
            networkFeaturedLineIDs: networkFeaturedLineIDs,
            networkFeaturedSegmentIDs: networkFeaturedSegmentIDs,
            networkSectionLineIDs: networkSectionLineIDs,
            closedLineIDs: networkSummary.closedLineIDs
        )
    }

    private func projectedDisruptionIDsBySegmentID(
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> [String: [String]] {
        let projector = BeckMapAffectedSegmentProjector(document: document, graph: graph)
        var disruptionIDsBySegmentID: [String: [String]] = [:]
        for disruption in appState.visibleDisruptions {
            for segmentID in projector.projectedSegmentIDs(for: disruption) {
                disruptionIDsBySegmentID[segmentID, default: []].append(disruption.id)
            }
        }
        return disruptionIDsBySegmentID
    }

}

private struct BeckMapCanvas: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var labelTypeScale: CGFloat = 1

    let document: BeckMapDocument
    let renderCache: RenderCache
    let presentation: BeckMapPresentationSnapshot
    let disruptionIDsBySegmentID: [String: [String]]
    let liveTrains: [LiveTubeTrain]
    let referenceOverlayVisible: Bool
    let resetToken: Int
    let locationFocusRequest: MapLocationFocusRequest?
    let contentVerticalBias: CGFloat
    let onUserZoomIn: () -> Void
    let stationSelectionGeneration: Int
    let onStationTap: (String) -> Void
    let onDisruptionTap: (String) -> Void
    let onBackgroundTap: () -> Void

    private var renderedSegments: [RenderedSegment] { renderCache.renderedSegments }
    private var renderedLineGroups: [RenderedLineGroup] { renderCache.renderedLineGroups }
    private var renderedWaterways: [RenderedWaterway] { renderCache.renderedWaterways }
    private var renderedStationMarkers: [RenderedStationMarker] { renderCache.renderedStationMarkers }
    private var renderedLabels: [RenderedLabel] { renderCache.renderedLabels }
    private var artworkBounds: CGRect { renderCache.artworkBounds }
    private var debugReferenceImage: UIImage? { renderCache.debugReferenceImage }

    @State private var cameraScale: CGFloat = 0.35
    @State private var cameraOffset = CGSize.zero
    @State private var minimumCameraScale: CGFloat = 0.2
    @State private var maximumCameraScale: CGFloat = 3.8
    @State private var fittedCameraScale: CGFloat = 0.35
    @State private var panStartOffset: CGSize?
    @State private var pinchStartScale: CGFloat?
    @State private var pinchMapPoint: CGPoint?
    @State private var isPanning = false
    @State private var isPinching = false
    @State private var cameraTransitionTask: Task<Void, Never>?

    init(
        document: BeckMapDocument,
        renderCache: RenderCache,
        presentation: BeckMapPresentationSnapshot,
        disruptionIDsBySegmentID: [String: [String]],
        liveTrains: [LiveTubeTrain],
        referenceOverlayVisible: Bool,
        resetToken: Int,
        locationFocusRequest: MapLocationFocusRequest?,
        contentVerticalBias: CGFloat,
        onUserZoomIn: @escaping () -> Void,
        stationSelectionGeneration: Int,
        onStationTap: @escaping (String) -> Void,
        onDisruptionTap: @escaping (String) -> Void,
        onBackgroundTap: @escaping () -> Void
    ) {
        self.document = document
        self.renderCache = renderCache
        self.presentation = presentation
        self.disruptionIDsBySegmentID = disruptionIDsBySegmentID
        self.liveTrains = liveTrains
        self.referenceOverlayVisible = referenceOverlayVisible
        self.resetToken = resetToken
        self.locationFocusRequest = locationFocusRequest
        self.contentVerticalBias = contentVerticalBias
        self.onUserZoomIn = onUserZoomIn
        self.stationSelectionGeneration = stationSelectionGeneration
        self.onStationTap = onStationTap
        self.onDisruptionTap = onDisruptionTap
        self.onBackgroundTap = onBackgroundTap
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(palette.background)
                    )
                    drawArtwork(context: &context, size: size)
                }
                .allowsHitTesting(false)

                if !liveTrains.isEmpty, !isReferenceOverlayActive {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        GeometryReader { viewport in
                            ZStack {
                                Canvas { context, size in
                                    drawTrains(
                                        context: &context,
                                        size: size,
                                        date: timeline.date
                                    )
                                }

                                if let train = appState.selectedTrain,
                                   let markerPoint = trainScreenPoint(
                                       for: train,
                                       at: timeline.date
                                   ),
                                   CGRect(origin: .zero, size: viewport.size).contains(markerPoint),
                                   let nextStopName = appState.graph?
                                       .stationsByID[train.nextStationID]?.name {
                                    TrainMapCalloutOverlay(
                                        train: train,
                                        nextStopName: nextStopName,
                                        date: timeline.date,
                                        markerPoint: markerPoint,
                                        viewportSize: viewport.size
                                    )
                                }
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                BeckMapGestureSurface(
                    onPan: { translation, phase in
                        handlePan(translation: translation, phase: phase, in: proxy.size)
                    },
                    onPinch: { magnification, location, phase in
                        handlePinch(
                            magnification: magnification,
                            location: location,
                            phase: phase,
                            in: proxy.size
                        )
                    },
                    onTap: selectMapFeature(at:)
                )
                .accessibilityHidden(true)
            }
            .accessibilityRepresentation {
                stationAccessibilityRepresentation
            }
            .task(id: CameraInitializationKey(
                documentID: document.identifier,
                graphGeneratedAt: document.source.graphGeneratedAt,
                width: proxy.size.width,
                height: proxy.size.height,
                referenceOverlayVisible: isReferenceOverlayActive
            )) {
                guard proxy.size.width > 0, proxy.size.height > 0 else { return }
                await Task.yield()
                resetCamera(in: proxy.size)
                if appState.sharedMapViewport != nil {
                    applySharedViewport(in: proxy.size)
                } else if let selectedStationID = presentation.selectedStationID {
                    focus(on: [selectedStationID], in: proxy.size)
                } else if presentation.emphasizesIssues {
                    focus(on: presentation.affectedStationIDs, in: proxy.size)
                } else {
                    publishViewport(in: proxy.size)
                }
            }
            .onChange(of: resetToken) { _, _ in
                guard appState.mapPresentationMode == .beck else { return }
                withAnimation(.smooth(duration: 0.5)) {
                    resetCamera(in: proxy.size)
                }
                publishViewport(in: proxy.size)
            }
            .onChange(of: locationFocusRequest?.id) { _, _ in
                guard appState.mapPresentationMode == .beck,
                      let locationFocusRequest else { return }
                focus(on: locationFocusRequest, in: proxy.size)
            }
            .onChange(of: contentVerticalBias) { oldBias, newBias in
                let delta = newBias - oldBias
                withAnimation(.smooth(duration: 0.32)) {
                    cameraOffset.height -= delta
                }
                updateCameraSnapshot(in: proxy.size)
                publishViewport(in: proxy.size)
            }
            .onChange(of: appState.mapPresentationMode) { _, mode in
                guard mode == .beck else { return }
                applySharedViewport(in: proxy.size)
                if appState.selectedDisruption != nil {
                    focus(on: presentation.affectedStationIDs, in: proxy.size)
                }
            }
            .onChange(of: presentation.affectedStationIDs) { _, stationIDs in
                if presentation.emphasizesIssues {
                    focus(on: stationIDs, in: proxy.size)
                }
            }
            .onChange(of: appState.disruptionSelectionGeneration) { _, _ in
                guard appState.mapPresentationMode == .beck else { return }
                focus(on: presentation.affectedStationIDs, in: proxy.size)
            }
            .onChange(of: stationSelectionGeneration) { _, _ in
                guard let stationID = presentation.selectedStationID else { return }
                focus(on: [stationID], in: proxy.size)
            }
            .onChange(of: appState.trainSelectionGeneration) { _, _ in
                guard appState.mapPresentationMode == .beck,
                      let train = appState.selectedTrain else { return }
                focus(on: train, at: .now, in: proxy.size)
            }
        }
        .onDisappear {
            cameraTransitionTask?.cancel()
        }
    }

    private var stationAccessibilityRepresentation: some View {
        ScrollView {
            LazyVStack {
                if !liveTrains.isEmpty {
                    Section("Estimated live trains") {
                        ForEach(liveTrains) { train in
                            Button(trainAccessibilityLabel(for: train)) {
                                appState.select(train: train)
                            }
                        }
                    }
                }

                ForEach(document.stationMarkers) { marker in
                    Button("\(marker.name), \(marker.lineIDs.map(\.displayName).joined(separator: ", "))") {
                        onStationTap(marker.stationID)
                    }
                }
            }
        }
        .accessibilityLabel("Interactive London rail map")
    }

    private func trainAccessibilityLabel(for train: LiveTubeTrain) -> String {
        let destination = train.destination ?? "unknown destination"
        let nextStop = appState.graph?.stationsByID[train.nextStationID]?.name
            ?? "unknown next stop"
        return "Train to \(destination), next stop \(nextStop)"
    }

    private var isReferenceOverlayActive: Bool {
        referenceOverlayVisible && debugReferenceImage != nil
    }

    private var palette: BeckMapPalette {
        BeckMapPalette.resolve(
            for: colorScheme,
            preservesReferenceAppearance: isReferenceOverlayActive
        )
    }

    private func drawArtwork(context: inout GraphicsContext, size: CGSize) {
        let traceMode = isReferenceOverlayActive
        if traceMode, let debugReferenceImage {
            var referenceContext = context
            referenceContext.concatenate(CGAffineTransform(
                a: cameraScale,
                b: 0,
                c: 0,
                d: cameraScale,
                tx: cameraOffset.width,
                ty: cameraOffset.height
            ))
            let reference = referenceContext.resolve(Image(uiImage: debugReferenceImage))
            referenceContext.draw(
                reference,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: document.artworkSize.width,
                    height: document.artworkSize.height
                )
            )
        }

        var mapContext = context
        mapContext.concatenate(CGAffineTransform(
            a: cameraScale,
            b: 0,
            c: 0,
            d: cameraScale,
            tx: cameraOffset.width,
            ty: cameraOffset.height
        ))
        if traceMode {
            mapContext.opacity = document.debugReference.geometryOpacity
        }

        let issuesActive = !traceMode && presentation.emphasizesIssues
        // Context belongs below the transport network. The waterway geometry
        // is authored as straight octilinear sections; rounded stroke joins
        // soften corners without turning the route itself into a smooth curve.
        for waterway in renderedWaterways {
            mapContext.stroke(
                waterway.path,
                with: .color(palette.waterwayOutline),
                style: StrokeStyle(
                    lineWidth: waterway.strokeWidth + waterway.outlineWidth * 2,
                    lineCap: .butt,
                    lineJoin: .round
                )
            )
            mapContext.stroke(
                waterway.path,
                with: .color(palette.waterwayFill),
                style: StrokeStyle(
                    lineWidth: waterway.strokeWidth,
                    lineCap: .butt,
                    lineJoin: .round
                )
            )
        }

        // Preserve the document's line-layer order, but render each parallel
        // rail line in two passes. Drawing every coloured outer before any
        // paper inset keeps branch joins open instead of allowing a later
        // segment's outer stroke to plug an earlier segment's paper centre.
        for lineGroup in renderedLineGroups {
            let lineSelected = presentation.selectedLineID == nil
                || presentation.selectedLineID == lineGroup.lineID
            var uniformMuted: Bool?
            var hasMixedMuting = false
            for segment in lineGroup.segments {
                let affected = presentation.affectedSegmentIDs.contains(segment.id)
                let muted = !traceMode && (
                    !lineSelected
                        || presentation.mutesSegment(
                            id: segment.id,
                            lineID: segment.lineID,
                            isAffected: affected
                        )
                )
                if let uniformMuted, uniformMuted != muted {
                    hasMixedMuting = true
                    break
                }
                uniformMuted = muted
            }
            if let casing = palette.northernLineCasing,
               let casingWidth = palette.casingWidth(
                   for: lineGroup.lineID,
                   routeWidth: document.styles.routeStrokeWidth
               ) {
                if !hasMixedMuting, uniformMuted == false {
                    mapContext.stroke(
                        lineGroup.combinedPath,
                        with: .color(casing),
                        style: StrokeStyle(
                            lineWidth: casingWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                } else if hasMixedMuting {
                    for segment in lineGroup.segments {
                        let affected = presentation.affectedSegmentIDs.contains(segment.id)
                        let muted = !traceMode && (
                            !lineSelected
                                || presentation.mutesSegment(
                                    id: segment.id,
                                    lineID: segment.lineID,
                                    isAffected: affected
                                )
                        )
                        guard !muted else { continue }
                        mapContext.stroke(
                            segment.path,
                            with: .color(casing),
                            style: StrokeStyle(
                                lineWidth: casingWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                    }
                }
            }

            if !hasMixedMuting, let muted = uniformMuted {
                mapContext.stroke(
                    lineGroup.combinedPath,
                    with: .color(palette.routeColor(for: lineGroup.lineID, muted: muted)),
                    style: StrokeStyle(
                        lineWidth: lineGroup.lineID.usesParallelSchematicStroke
                            ? document.styles.parallelRouteOuterStrokeWidth(for: lineGroup.lineID)
                            : document.styles.routeStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            } else {
                for segment in lineGroup.segments {
                    let affected = presentation.affectedSegmentIDs.contains(segment.id)
                    let muted = !traceMode && (
                        !lineSelected
                            || presentation.mutesSegment(
                                id: segment.id,
                                lineID: segment.lineID,
                                isAffected: affected
                            )
                    )
                    mapContext.stroke(
                        segment.path,
                        with: .color(palette.routeColor(for: segment.lineID, muted: muted)),
                        style: StrokeStyle(
                            lineWidth: lineGroup.lineID.usesParallelSchematicStroke
                                ? document.styles.parallelRouteOuterStrokeWidth(for: lineGroup.lineID)
                                : document.styles.routeStrokeWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
            if lineGroup.lineID.usesParallelSchematicStroke {
                mapContext.stroke(
                    lineGroup.combinedPath,
                    with: .color(palette.paper),
                    style: StrokeStyle(
                        lineWidth: document.styles.parallelRouteInnerStrokeWidth(for: lineGroup.lineID),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }

        // State overlays are a separate topmost pass. Authored routes can share
        // physical artwork spans, so a later normal segment must never conceal
        // an affected segment drawn earlier in document order.
        if issuesActive {
            for segment in renderedSegments where presentation.affectedSegmentIDs.contains(segment.id) {
                mapContext.stroke(
                    segment.path,
                    with: .color(.red.opacity(0.82)),
                    style: StrokeStyle(
                        lineWidth: document.styles.affectedOuterStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                mapContext.stroke(
                    segment.path,
                    with: .color(palette.paper),
                    style: StrokeStyle(
                        lineWidth: document.styles.affectedKnockoutStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                mapContext.stroke(
                    segment.path,
                    with: .color(.tubeLine(segment.lineID)),
                    style: StrokeStyle(
                        lineWidth: document.styles.affectedRouteStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }

        if !traceMode {
            // Labels are screen-space UI, so they remain readable instead of
            // growing with the artwork. Station markers are drawn last to
            // guarantee that a label background can never conceal a station.
            if !isPanning, !isPinching {
                drawLabels(context: &context, viewport: size)
            }
            drawStationMarkers(context: &mapContext)
        }
    }

    private func drawTrains(
        context: inout GraphicsContext,
        size: CGSize,
        date: Date
    ) {
        let visibleBounds = CGRect(origin: .zero, size: size).insetBy(dx: -12, dy: -12)
        var trainIcon = context.resolve(Image(systemName: "tram.fill"))
        trainIcon.shading = .color(.white)

        for train in liveTrains {
            guard let point = trainScreenPoint(for: train, at: date) else { continue }
            guard visibleBounds.contains(point) else { continue }
            let selected = train.id == appState.selectedTrainID
            let diameter: CGFloat = selected ? 24 : 20
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
            let marker = Path(roundedRect: markerRect, cornerRadius: 7)
            context.fill(marker, with: .color(Color.tubeLine(train.lineID)))
            context.stroke(
                marker,
                with: .color(.white),
                lineWidth: selected ? 2.5 : 1.5
            )
            context.draw(trainIcon, in: markerRect.insetBy(dx: 5, dy: 5))
        }
    }

    private func trainScreenPoint(
        for train: LiveTubeTrain,
        at date: Date
    ) -> CGPoint? {
        guard let artworkPoint = trainArtworkPoint(for: train, at: date) else {
            return nil
        }
        return screenPoint(artworkPoint)
    }

    private func trainArtworkPoint(
        for train: LiveTubeTrain,
        at date: Date
    ) -> CGPoint? {
        guard let path = renderCache.trainPathsBySegmentID[train.segmentID],
              let progress = LiveTrainMarkerPolicy.projectedProgress(
                  for: train,
                  at: date,
                  stationBoard: appState.authoritativeStationBoardSnapshot
              ),
              let artworkPoint = path.point(
                  progress: progress,
                  previousStationID: train.previousStationID,
                  nextStationID: train.nextStationID
              ) else { return nil }
        return artworkPoint
    }

    private func drawStationMarkers(context: inout GraphicsContext) {
        let issuesActive = presentation.emphasizesIssues && !presentation.affectedSegmentIDs.isEmpty
        for marker in renderedStationMarkers {
            let affected = issuesActive && presentation.affectedStationIDs.contains(marker.stationID)
            let selected = presentation.selectedStationID == marker.stationID
            let outline = affected ? Color.red : selected ? Color.blue : palette.stationOutline

            if selected {
                let haloRadius = 19 / max(cameraScale, 0.01)
                let haloRect = CGRect(
                    x: marker.anchor.x - haloRadius,
                    y: marker.anchor.y - haloRadius,
                    width: haloRadius * 2,
                    height: haloRadius * 2
                )
                let halo = Path(ellipseIn: haloRect)
                context.fill(halo, with: .color(Color.blue.opacity(0.16)))
                context.stroke(
                    halo,
                    with: .color(Color.blue.opacity(0.9)),
                    lineWidth: 2.5 / max(cameraScale, 0.01)
                )
            }

            for primitive in marker.primitives {
                switch primitive {
                case let .connector(connector, path):
                    context.stroke(
                        path,
                        with: .color(outline),
                        style: StrokeStyle(lineWidth: connector.width + (selected ? 2 : 1.8), lineCap: .round)
                    )
                    context.stroke(
                        path,
                        with: .color(palette.paper),
                        style: StrokeStyle(lineWidth: connector.width - 2.2, lineCap: .round)
                    )
                case let .walkingConnector(connector, path):
                    context.stroke(
                        path,
                        with: .color(outline),
                        style: StrokeStyle(
                            lineWidth: connector.width + (selected ? 1.5 : 0),
                            lineCap: .butt,
                            dash: [8, 5]
                        )
                    )
                case let .circle(circle, path):
                    context.fill(
                        path,
                        with: .color(affected ? Color.red.opacity(0.16) : palette.paper)
                    )
                    context.stroke(
                        path,
                        with: .color(outline),
                        lineWidth: circle.outlineWidth + (selected ? 1.8 : 0)
                    )
                case let .tick(tick, path):
                    context.stroke(
                        path,
                        with: .color(affected ? .red : .tubeLine(tick.lineID)),
                        style: StrokeStyle(lineWidth: tick.width + (selected ? 1.8 : 0), lineCap: .butt)
                    )
                }
            }
        }
    }

    private func drawLabels(context: inout GraphicsContext, viewport: CGSize) {
        if document.geometryStatus != .authored, cameraScale < max(0.48, minimumCameraScale) {
            return
        }
        let viewportRect = StationLabelLayoutEngine.availableViewport(in: viewport)
        let selectedStationID = presentation.selectedStationID
        let visibleLabels = renderedLabels.filter { renderedLabel in
            let label = renderedLabel.label
            return label.represents(stationID: selectedStationID)
                || BeckMapLabelVisibilityPolicy.shows(
                    label.effectiveVisibilityTier,
                    at: cameraScale
                )
        }
        guard !visibleLabels.isEmpty else { return }
        let markerFrames = markerExclusionFrames()
        let markerFramesByStationID = Dictionary(grouping: markerFrames, by: \.stationID)
            .mapValues { blockers in
                blockers.reduce(into: CGRect.null) { bounds, blocker in
                    bounds = bounds.union(blocker.frame)
                }
            }
        let lineBlockers = lineExclusionBlockers(in: viewportRect)
        var resolvedTextByLabelID: [String: GraphicsContext.ResolvedText] = [:]
        var layoutInputs: [StationLabelLayoutInput] = []

        for renderedLabel in visibleLabels {
            let label = renderedLabel.label
            let selected = label.represents(stationID: selectedStationID)
            let screenAnchor = screenPoint(renderedLabel.artworkAnchor)
            let tier = label.effectiveVisibilityTier
            let weight: Font.Weight = tier == .overview ? .semibold : .medium
            let fontSize = BeckMapLabelVisibilityPolicy.fontSize(
                for: tier,
                at: cameraScale
            ) * min(1.6, max(1, labelTypeScale))
            var text = context.resolve(Text(label.text).font(.system(
                size: fontSize,
                weight: weight
            )))
            text.shading = .color(palette.ink)
            let measuredTextSize = text.measure(in: CGSize(
                width: CGFloat.infinity,
                height: CGFloat.infinity
            ))
            let documentPadding = CGFloat(document.styles.labelPadding)
            let boundsByAlignment = Dictionary(uniqueKeysWithValues:
                [BeckMapLabelAlignment.leading, .centre, .trailing].map { alignment in
                    (alignment, BeckMapLabelBounds.backgroundBounds(
                        textSize: measuredTextSize,
                        alignment: alignment,
                        horizontalPadding: documentPadding + palette.labelHorizontalPadding,
                        verticalPadding: documentPadding + palette.labelVerticalPadding
                    ))
                }
            )
            let representedStationIDs = [label.stationID] + (label.associatedStationIDs ?? [])
            let targetMarkerFrame = representedStationIDs.compactMap {
                markerFramesByStationID[$0]
            }.reduce(into: CGRect.null) { frame, markerFrame in
                frame = frame.union(markerFrame)
            }
            resolvedTextByLabelID[label.id] = text
            layoutInputs.append(StationLabelLayoutInput(
                id: label.id,
                priority: label.priority,
                tier: tier,
                selected: selected,
                stationScreenPosition: screenAnchor,
                markerFrame: targetMarkerFrame.isNull
                    ? CGRect(x: screenAnchor.x - 6, y: screenAnchor.y - 6, width: 12, height: 12)
                    : targetMarkerFrame,
                preferredAlignment: label.alignment,
                screenOffset: CGVector(
                    dx: renderedLabel.artworkOffset.dx * cameraScale,
                    dy: renderedLabel.artworkOffset.dy * cameraScale
                ),
                rotation: renderedLabel.rotation,
                boundsByAlignment: boundsByAlignment
            ))
        }

        let placements = StationLabelLayoutEngine.layout(
            inputs: layoutInputs,
            viewport: viewportRect,
            markerBlockers: markerFrames,
            lineBlockers: lineBlockers
        )
        for placement in placements {
            guard let text = resolvedTextByLabelID[placement.labelID] else { continue }

            let anchor: UnitPoint
            switch placement.alignment {
            case .leading:
                anchor = .leading
            case .centre:
                anchor = .center
            case .trailing:
                anchor = .trailing
            }

            var labelContext = context
            labelContext.concatenate(
                placement.rotation.concatenating(CGAffineTransform(
                    translationX: placement.position.x,
                    y: placement.position.y
                ))
            )
            let backgroundPath = Path(
                roundedRect: placement.backgroundBounds,
                cornerRadius: min(
                    palette.labelCornerRadius,
                    placement.backgroundBounds.height / 2
                )
            )
            labelContext.fill(backgroundPath, with: .color(palette.labelSurface))
            if palette.labelBorderWidth > 0 {
                labelContext.stroke(
                    backgroundPath,
                    with: .color(palette.labelBorder),
                    lineWidth: palette.labelBorderWidth
                )
            }
            labelContext.draw(text, at: .zero, anchor: anchor)
        }
    }

    private func markerExclusionFrames() -> [BeckMapLabelBlocker] {
        return document.stationMarkers.flatMap { marker in
            marker.primitives.compactMap { primitive -> BeckMapLabelBlocker? in
                switch primitive {
                case let .circle(circle):
                    let centre = screenPoint(circle.centre)
                    let radius = max(6, circle.radius * cameraScale) + 4
                    return BeckMapLabelBlocker(
                        stationID: marker.stationID,
                        frame: CGRect(
                            x: centre.x - radius,
                            y: centre.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    )
                case let .tick(tick):
                    let start = screenPoint(tick.start)
                    let end = screenPoint(tick.end)
                    return BeckMapLabelBlocker(
                        stationID: marker.stationID,
                        frame: CGRect(
                            x: min(start.x, end.x),
                            y: min(start.y, end.y),
                            width: max(1, abs(end.x - start.x)),
                            height: max(1, abs(end.y - start.y))
                        ).insetBy(dx: -6, dy: -6)
                    )
                case .connector, .walkingConnector:
                    return nil
                }
            }
        }
    }

    private func lineExclusionBlockers(in viewport: CGRect) -> [BeckMapLineBlocker] {
        let issuesActive = presentation.emphasizesIssues
            && !presentation.affectedSegmentIDs.isEmpty
        var blockers = renderedSegments.flatMap { segment in
            let visibleWidth = issuesActive && presentation.affectedSegmentIDs.contains(segment.id)
                ? document.styles.affectedOuterStrokeWidth
                : document.styles.routeStrokeWidth
            let routeClearance = visibleWidth * cameraScale / 2 + 4
            return segment.collisionEdges.compactMap { edge -> BeckMapLineBlocker? in
                let blocker = BeckMapLineBlocker(
                    start: screenPoint(edge.start),
                    end: screenPoint(edge.end),
                    clearance: routeClearance
                )
                return blocker.bounds.intersects(viewport) ? blocker : nil
            }
        }

        for marker in document.stationMarkers {
            for primitive in marker.primitives {
                let start: BeckMapPoint
                let end: BeckMapPoint
                let width: Double
                switch primitive {
                case let .connector(connector):
                    start = connector.start
                    end = connector.end
                    width = connector.width
                case let .walkingConnector(connector):
                    start = connector.start
                    end = connector.end
                    width = connector.width
                case .circle, .tick:
                    continue
                }
                let blocker = BeckMapLineBlocker(
                    start: screenPoint(start),
                    end: screenPoint(end),
                    clearance: width * cameraScale / 2 + 4
                )
                if blocker.bounds.intersects(viewport) {
                    blockers.append(blocker)
                }
            }
        }
        return blockers
    }

    private func resetCamera(in size: CGSize) {
        cameraTransitionTask?.cancel()
        let fittingBounds = isReferenceOverlayActive
            ? CGRect(
                x: 0,
                y: 0,
                width: document.artworkSize.width,
                height: document.artworkSize.height
            )
            : artworkBounds
        let fittedScale = min(
            max(1, size.width - 32) / max(1, fittingBounds.width),
            max(1, size.height - 32) / max(1, fittingBounds.height)
        )
        fittedCameraScale = fittedScale
        minimumCameraScale = max(0.01, fittedScale * 0.82)
        maximumCameraScale = max(3.8, fittedScale * 4)
        cameraScale = fittedScale
        cameraOffset = CGSize(
            width: size.width / 2 - fittingBounds.midX * cameraScale,
            height: size.height / 2 - fittingBounds.midY * cameraScale - contentVerticalBias
        )
        updateCameraSnapshot(in: size)
    }

    private func focus(on stationIDs: Set<String>, in size: CGSize) {
        let markers = document.stationMarkers.filter { stationIDs.contains($0.stationID) }
        guard !markers.isEmpty else { return }
        let xValues = markers.map(\.anchor.x)
        let yValues = markers.map(\.anchor.y)
        guard let minX = xValues.min(), let maxX = xValues.max(),
              let minY = yValues.min(), let maxY = yValues.max() else { return }
        let width = max(120, maxX - minX)
        let height = max(120, maxY - minY)
        let nextScale = min(1.65, max(minimumCameraScale, min((size.width - 70) / width, (size.height - 270) / height)))
        animateCamera(
            toScale: nextScale,
            offset: CGSize(
                width: size.width / 2 - CGFloat((minX + maxX) / 2) * nextScale,
                height: size.height / 2 - CGFloat((minY + maxY) / 2) * nextScale - 28
            ),
            viewportSize: size
        )
    }

    private func focus(on request: MapLocationFocusRequest, in size: CGSize) {
        if let stationID = request.snappedStationID {
            focus(on: [stationID], in: size)
            return
        }
        guard let graph = appState.graph,
              let artworkPoint = SharedMapProjection.artworkPoint(
                for: request.coordinate,
                document: document,
                graph: graph
              ) else { return }
        let nextScale = min(maximumCameraScale, max(minimumCameraScale, 1.65))
        animateCamera(
            toScale: nextScale,
            offset: CGSize(
                width: size.width / 2 - artworkPoint.x * nextScale,
                height: size.height / 2 - artworkPoint.y * nextScale - 28
            ),
            viewportSize: size
        )
    }

    private func focus(on train: LiveTubeTrain, at date: Date, in size: CGSize) {
        guard let artworkPoint = trainArtworkPoint(for: train, at: date) else { return }
        let nextScale = TrainMapFocusPolicy.schematicScale(
            currentScale: cameraScale,
            minimumScale: minimumCameraScale,
            maximumScale: maximumCameraScale
        )
        let anchor = TrainMapFocusPolicy.schematicAnchor(in: size)
        animateCamera(
            toScale: nextScale,
            offset: CGSize(
                width: anchor.x - artworkPoint.x * nextScale,
                height: anchor.y - artworkPoint.y * nextScale
            ),
            viewportSize: size,
            duration: 0.45,
            easing: .easeOutQuart
        )
    }

    private func animateCamera(
        toScale targetScale: CGFloat,
        offset targetOffset: CGSize,
        viewportSize: CGSize,
        duration: TimeInterval = 2,
        easing: BeckMapCameraEasing = .smoothStep
    ) {
        cameraTransitionTask?.cancel()

        if reduceMotion {
            cameraScale = targetScale
            cameraOffset = targetOffset
            updateCameraSnapshot(in: viewportSize)
            publishViewport(in: viewportSize)
            return
        }

        let startScale = cameraScale
        let startOffset = cameraOffset
        let startTime = ProcessInfo.processInfo.systemUptime
        cameraTransitionTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let progress = min(1, max(0, elapsed / duration))
                let easedProgress = easing.value(at: progress)

                cameraScale = startScale + (targetScale - startScale) * CGFloat(easedProgress)
                cameraOffset = CGSize(
                    width: startOffset.width
                        + (targetOffset.width - startOffset.width) * CGFloat(easedProgress),
                    height: startOffset.height
                        + (targetOffset.height - startOffset.height) * CGFloat(easedProgress)
                )
                updateCameraSnapshot(in: viewportSize)

                guard progress < 1 else {
                    publishViewport(in: viewportSize)
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
            }
        }
    }

    private func handlePan(
        translation: CGSize,
        phase: BeckMapGesturePhase,
        in size: CGSize
    ) {
        switch phase {
        case .began:
            cameraTransitionTask?.cancel()
            isPanning = true
            panStartOffset = cameraOffset
        case .changed:
            isPanning = true
            let start = panStartOffset ?? cameraOffset
            panStartOffset = start
            cameraOffset = CGSize(width: start.width + translation.width, height: start.height + translation.height)
            // Panning changes only the offset. The outer map chrome depends on
            // zoom, so publishing this through shared app state every frame
            // needlessly invalidates the whole map screen.
        case .ended:
            isPanning = false
            panStartOffset = nil
            publishViewport(in: size)
        }
    }

    private func handlePinch(
        magnification: CGFloat,
        location: CGPoint,
        phase: BeckMapGesturePhase,
        in size: CGSize
    ) {
        switch phase {
        case .began:
            cameraTransitionTask?.cancel()
            isPinching = true
            pinchStartScale = cameraScale
            pinchMapPoint = CGPoint(
                x: (location.x - cameraOffset.width) / cameraScale,
                y: (location.y - cameraOffset.height) / cameraScale
            )
        case .changed:
            isPinching = true
            guard let startScale = pinchStartScale, let mapPoint = pinchMapPoint else { return }
            let nextScale = min(maximumCameraScale, max(minimumCameraScale, startScale * magnification))
            if nextScale > cameraScale,
               BeckMapOverviewVisibilityPolicy.shouldHideClosestStation(
                   at: nextScale,
                   fittedScale: fittedCameraScale
               ) {
                onUserZoomIn()
            }
            cameraScale = nextScale
            cameraOffset = CGSize(
                width: location.x - mapPoint.x * nextScale,
                height: location.y - mapPoint.y * nextScale
            )
            updateCameraSnapshot(in: size)
        case .ended:
            isPinching = false
            pinchStartScale = nil
            pinchMapPoint = nil
            panStartOffset = nil
            publishViewport(in: size)
        }
    }

    private func applySharedViewport(in size: CGSize) {
        guard let viewport = appState.sharedMapViewport,
              let graph = appState.graph,
              let artworkRect = SharedMapProjection.artworkRect(
                  for: viewport,
                  document: document,
                  graph: graph,
                  size: size
              ),
              let centre = SharedMapProjection.artworkPoint(
                  for: viewport.coordinate,
                  document: document,
                  graph: graph
              ) else {
            updateCameraSnapshot(in: size)
            return
        }
        cameraTransitionTask?.cancel()
        let scaleToFit = min(
            size.width / max(1, artworkRect.width),
            size.height / max(1, artworkRect.height)
        )
        cameraScale = min(
            maximumCameraScale,
            max(minimumCameraScale, scaleToFit)
        )
        cameraOffset = CGSize(
            width: size.width / 2 - centre.x * cameraScale,
            height: size.height / 2 - centre.y * cameraScale
        )
        updateCameraSnapshot(in: size)
    }

    private func publishViewport(in size: CGSize) {
        updateCameraSnapshot(in: size)
        guard appState.mapPresentationMode == .beck,
              let graph = appState.graph else { return }
        let scale = max(0.000_001, cameraScale)
        let artworkRect = CGRect(
            x: (0 - cameraOffset.width) / scale,
            y: (0 - cameraOffset.height) / scale,
            width: size.width / scale,
            height: size.height / scale
        )
        guard let viewport = SharedMapProjection.viewport(
            fromArtworkRect: artworkRect,
            document: document,
            graph: graph,
            size: size
        ) else { return }
        appState.sharedMapViewport = viewport
    }

    private func updateCameraSnapshot(in size: CGSize) {
        appState.beckMapCameraSnapshot = BeckMapCameraSnapshot(
            scale: cameraScale,
            fittedScale: fittedCameraScale,
            offsetX: cameraOffset.width,
            offsetY: cameraOffset.height,
            viewportWidth: size.width,
            viewportHeight: size.height
        )
    }

    private func selectMapFeature(at location: CGPoint) {
        if let train = LiveTrainHitTesting.nearest(
            to: location,
            candidates: liveTrains.compactMap { train in
                guard let point = trainScreenPoint(for: train, at: .now) else { return nil }
                return (train, point)
            }
        ) {
            withAnimation(.smooth(duration: 0.25)) {
                appState.select(train: train)
            }
            return
        }

        let nearest = document.stationMarkers.min {
            distance(screenPoint($0.anchor), location) < distance(screenPoint($1.anchor), location)
        }
        if let nearest,
           distance(screenPoint(nearest.anchor), location) <= max(24, nearest.hitRadius * cameraScale) {
            onStationTap(nearest.stationID)
        } else if let disruptionID = disruptionID(at: location) {
            onDisruptionTap(disruptionID)
        } else {
            onBackgroundTap()
        }
    }

    private func disruptionID(at screenLocation: CGPoint) -> String? {
        let scale = max(0.000_001, cameraScale)
        let artworkLocation = CGPoint(
            x: (screenLocation.x - cameraOffset.width) / scale,
            y: (screenLocation.y - cameraOffset.height) / scale
        )
        let screenHitDistance = max(
            20,
            document.styles.affectedOuterStrokeWidth * scale / 2 + 10
        )
        let hitTargets = renderedSegments.compactMap { segment -> BeckMapLineHitTarget? in
            guard disruptionIDsBySegmentID[segment.id]?.isEmpty == false else { return nil }
            return BeckMapLineHitTarget(
                segmentID: segment.id,
                edges: segment.collisionEdges
            )
        }
        guard let segmentID = BeckMapLineHitTester.nearestSegmentID(
            to: artworkLocation,
            among: hitTargets,
            maximumDistance: screenHitDistance / scale
        ) else { return nil }
        return disruptionIDsBySegmentID[segmentID]?.first
    }

    private func screenPoint(_ point: BeckMapPoint) -> CGPoint {
        CGPoint(
            x: point.x * cameraScale + cameraOffset.width,
            y: point.y * cameraScale + cameraOffset.height
        )
    }

    private func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * cameraScale + cameraOffset.width,
            y: point.y * cameraScale + cameraOffset.height
        )
    }

    private func distance(_ start: CGPoint, _ end: CGPoint) -> CGFloat {
        hypot(start.x - end.x, start.y - end.y)
    }

    private static func makeLinePath(
        from start: BeckMapPoint,
        to end: BeckMapPoint
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(start))
        path.addLine(to: CGPoint(end))
        return path
    }

    private static func makePath(
        commands: [BeckMapPathCommand],
        translation: BeckMapTranslation
    ) -> Path {
        func point(_ value: BeckMapPoint) -> CGPoint {
            CGPoint(x: value.x + translation.x, y: value.y + translation.y)
        }

        var path = Path()
        for command in commands {
            switch command {
            case let .move(to):
                path.move(to: point(to))
            case let .line(to):
                path.addLine(to: point(to))
            case let .cubic(control1, control2, to):
                path.addCurve(to: point(to), control1: point(control1), control2: point(control2))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    private static func makeCollisionEdges(
        commands: [BeckMapPathCommand],
        translation: BeckMapTranslation
    ) -> [BeckMapCollisionEdge] {
        func point(_ value: BeckMapPoint) -> CGPoint {
            CGPoint(x: value.x + translation.x, y: value.y + translation.y)
        }

        func cubicPoint(
            from start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            to end: CGPoint,
            progress: CGFloat
        ) -> CGPoint {
            let inverse = 1 - progress
            let startWeight = inverse * inverse * inverse
            let control1Weight = 3 * inverse * inverse * progress
            let control2Weight = 3 * inverse * progress * progress
            let endWeight = progress * progress * progress
            return CGPoint(
                x: start.x * startWeight
                    + control1.x * control1Weight
                    + control2.x * control2Weight
                    + end.x * endWeight,
                y: start.y * startWeight
                    + control1.y * control1Weight
                    + control2.y * control2Weight
                    + end.y * endWeight
            )
        }

        var edges: [BeckMapCollisionEdge] = []
        var current: CGPoint?
        var subpathStart: CGPoint?
        for command in commands {
            switch command {
            case let .move(to):
                let destination = point(to)
                current = destination
                subpathStart = destination
            case let .line(to):
                let destination = point(to)
                if let current {
                    edges.append(.init(start: current, end: destination))
                }
                current = destination
            case let .cubic(control1, control2, to):
                let destination = point(to)
                guard let start = current else {
                    current = destination
                    continue
                }
                let firstControl = point(control1)
                let secondControl = point(control2)
                let controlLength = hypot(firstControl.x - start.x, firstControl.y - start.y)
                    + hypot(secondControl.x - firstControl.x, secondControl.y - firstControl.y)
                    + hypot(destination.x - secondControl.x, destination.y - secondControl.y)
                let steps = max(4, min(64, Int(ceil(controlLength / 8))))
                var previous = start
                for step in 1 ... steps {
                    let sampled = cubicPoint(
                        from: start,
                        control1: firstControl,
                        control2: secondControl,
                        to: destination,
                        progress: CGFloat(step) / CGFloat(steps)
                    )
                    edges.append(.init(start: previous, end: sampled))
                    previous = sampled
                }
                current = destination
            case .close:
                if let current, let subpathStart, current != subpathStart {
                    edges.append(.init(start: current, end: subpathStart))
                }
                current = subpathStart
            }
        }
        return edges
    }

    private static func loadDebugReference(for document: BeckMapDocument) -> UIImage? {
        #if DEBUG
        let reference = document.debugReference
        let subdirectories: [String?] = [
            "BeckMap/v1",
            "Resources/BeckMap/v1",
            nil,
        ]
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(
                forResource: reference.resourceName,
                withExtension: reference.resourceExtension,
                subdirectory: subdirectory
            ), let image = UIImage(contentsOfFile: url.path) {
                return image
            }
        }
        return UIImage(named: "\(reference.resourceName).\(reference.resourceExtension)")
        #else
        return nil
        #endif
    }

    private static func makeArtworkBounds(
        document: BeckMapDocument,
        renderedSegments: [RenderedSegment],
        renderedWaterways: [RenderedWaterway]
    ) -> CGRect {
        var bounds = renderedSegments.reduce(into: CGRect.null) { partial, segment in
            partial = partial.union(segment.path.boundingRect)
        }

        for waterway in renderedWaterways {
            let expansion = waterway.strokeWidth / 2 + waterway.outlineWidth
            bounds = bounds.union(
                waterway.path.boundingRect.insetBy(dx: -expansion, dy: -expansion)
            )
        }

        for marker in document.stationMarkers {
            for primitive in marker.primitives {
                let primitiveBounds: CGRect
                switch primitive {
                case let .connector(connector):
                    primitiveBounds = CGRect(
                        x: min(connector.start.x, connector.end.x),
                        y: min(connector.start.y, connector.end.y),
                        width: abs(connector.end.x - connector.start.x),
                        height: abs(connector.end.y - connector.start.y)
                    ).insetBy(dx: -connector.width / 2, dy: -connector.width / 2)
                case let .walkingConnector(connector):
                    primitiveBounds = CGRect(
                        x: min(connector.start.x, connector.end.x),
                        y: min(connector.start.y, connector.end.y),
                        width: abs(connector.end.x - connector.start.x),
                        height: abs(connector.end.y - connector.start.y)
                    ).insetBy(dx: -connector.width / 2, dy: -connector.width / 2)
                case let .circle(circle):
                    primitiveBounds = CGRect(
                        x: circle.centre.x - circle.radius,
                        y: circle.centre.y - circle.radius,
                        width: circle.radius * 2,
                        height: circle.radius * 2
                    )
                case let .tick(tick):
                    primitiveBounds = CGRect(
                        x: min(tick.start.x, tick.end.x),
                        y: min(tick.start.y, tick.end.y),
                        width: abs(tick.end.x - tick.start.x),
                        height: abs(tick.end.y - tick.start.y)
                    ).insetBy(dx: -tick.width / 2, dy: -tick.width / 2)
                }
                bounds = bounds.union(primitiveBounds)
            }
        }

        for label in document.labels {
            bounds = bounds.union(Self.labelMetrics(for: label, styles: document.styles).bounds.offsetBy(
                dx: label.position.x,
                dy: label.position.y
            ))
        }

        if bounds.isNull || bounds.isInfinite || bounds.width <= 0 || bounds.height <= 0 {
            bounds = CGRect(
                x: 0,
                y: 0,
                width: max(1, document.artworkSize.width),
                height: max(1, document.artworkSize.height)
            )
        }
        let inset = max(20, document.styles.routeStrokeWidth)
        return bounds.insetBy(dx: -inset, dy: -inset)
    }

    private static func labelMetrics(
        for label: BeckMapLabelRecord,
        styles: BeckMapStyleRecord,
        fontSizeOverride: CGFloat? = nil,
        alignmentOverride: BeckMapLabelAlignment? = nil
    ) -> LabelMetrics {
        let fontSize = fontSizeOverride ?? CGFloat(
            label.priority >= 10 ? styles.primaryLabelFontSize : styles.secondaryLabelFontSize
        )
        let padding = CGFloat(styles.labelPadding)
        let lines = label.text.split(separator: "\n", omittingEmptySubsequences: false)
        let longestLine = lines.map(\.count).max() ?? 0
        let width = max(fontSize * 2.8, CGFloat(longestLine) * fontSize * 0.54)
        let height = max(fontSize * 1.44, CGFloat(lines.count) * fontSize * 1.1)
        let originX: CGFloat
        switch alignmentOverride ?? label.alignment {
        case .leading:
            originX = -padding
        case .centre:
            originX = -width / 2 - padding
        case .trailing:
            originX = -width - padding
        }
        return LabelMetrics(
            fontSize: fontSize,
            bounds: CGRect(
                x: originX,
                y: -height / 2 - padding,
                width: width + padding * 2,
                height: height + padding * 2
            )
        )
    }

    @MainActor
    struct RenderCache {
        let renderedSegments: [RenderedSegment]
        let renderedLineGroups: [RenderedLineGroup]
        let renderedWaterways: [RenderedWaterway]
        let renderedStationMarkers: [RenderedStationMarker]
        let trainPathsBySegmentID: [String: BeckMapTrainPath]
        let renderedLabels: [RenderedLabel]
        let artworkBounds: CGRect
        let debugReferenceImage: UIImage?

        init(document: BeckMapDocument, loadsDebugReference: Bool = false) {
            let paths = Dictionary(uniqueKeysWithValues: document.paths.map {
                ($0.id, $0.commands)
            })
            let renderedSegments = document.segments.compactMap {
                segment -> RenderedSegment? in
                guard let commands = paths[segment.pathID] else { return nil }
                let collisionEdges = BeckMapCanvas.makeCollisionEdges(
                    commands: commands,
                    translation: segment.translation
                )
                return RenderedSegment(
                    id: segment.id,
                    lineID: segment.lineID,
                    path: BeckMapCanvas.makePath(
                        commands: commands,
                        translation: segment.translation
                    ),
                    collisionEdges: collisionEdges,
                    trainPath: BeckMapTrainPath(
                        fromStationID: segment.fromStationID,
                        toStationID: segment.toStationID,
                        pathDirection: segment.pathDirection,
                        edges: collisionEdges
                    )
                )
            }
            self.renderedSegments = renderedSegments
            self.trainPathsBySegmentID = Dictionary(
                uniqueKeysWithValues: renderedSegments.map { ($0.id, $0.trainPath) }
            )

            var seenLineIDs: Set<TubeLineID> = []
            let orderedLineIDs = renderedSegments.compactMap { segment in
                seenLineIDs.insert(segment.lineID).inserted ? segment.lineID : nil
            }
            let segmentsByLineID = Dictionary(grouping: renderedSegments, by: \.lineID)
            self.renderedLineGroups = orderedLineIDs.map { lineID in
                let segments = segmentsByLineID[lineID, default: []]
                var combinedPath = Path()
                for segment in segments {
                    combinedPath.addPath(segment.path)
                }
                return RenderedLineGroup(
                    lineID: lineID,
                    segments: segments,
                    combinedPath: combinedPath
                )
            }

            self.renderedWaterways = (document.waterways ?? []).compactMap { waterway in
                guard let commands = paths[waterway.pathID] else { return nil }
                return RenderedWaterway(
                    id: waterway.id,
                    name: waterway.name,
                    path: BeckMapCanvas.makePath(
                        commands: commands,
                        translation: .zero
                    ),
                    strokeWidth: CGFloat(waterway.strokeWidth),
                    outlineWidth: CGFloat(waterway.outlineWidth)
                )
            }

            self.renderedStationMarkers = document.stationMarkers.map { marker in
                RenderedStationMarker(
                    stationID: marker.stationID,
                    anchor: marker.anchor,
                    primitives: marker.primitives.map { primitive in
                        switch primitive {
                        case let .connector(connector):
                            return .connector(
                                connector,
                                BeckMapCanvas.makeLinePath(
                                    from: connector.start,
                                    to: connector.end
                                )
                            )
                        case let .walkingConnector(connector):
                            return .walkingConnector(
                                connector,
                                BeckMapCanvas.makeLinePath(
                                    from: connector.start,
                                    to: connector.end
                                )
                            )
                        case let .circle(circle):
                            return .circle(
                                circle,
                                Path(ellipseIn: CGRect(
                                    x: circle.centre.x - circle.radius,
                                    y: circle.centre.y - circle.radius,
                                    width: circle.radius * 2,
                                    height: circle.radius * 2
                                ))
                            )
                        case let .tick(tick):
                            return .tick(
                                tick,
                                BeckMapCanvas.makeLinePath(
                                    from: tick.start,
                                    to: tick.end
                                )
                            )
                        }
                    }
                )
            }

            let stationAnchors = Dictionary(
                uniqueKeysWithValues: document.stationMarkers.map {
                    ($0.stationID, CGPoint($0.anchor))
                }
            )
            self.renderedLabels = document.labels.map { label in
                let artworkPosition = CGPoint(label.position)
                let artworkAnchor = stationAnchors[label.stationID] ?? artworkPosition
                return RenderedLabel(
                    label: label,
                    artworkAnchor: artworkAnchor,
                    artworkOffset: CGVector(
                        dx: artworkPosition.x - artworkAnchor.x,
                        dy: artworkPosition.y - artworkAnchor.y
                    ),
                    rotation: CGAffineTransform(
                        rotationAngle: label.rotationDegrees * .pi / 180
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.label.effectiveVisibilityTier != rhs.label.effectiveVisibilityTier {
                    return lhs.label.effectiveVisibilityTier.renderPriority
                        > rhs.label.effectiveVisibilityTier.renderPriority
                }
                if lhs.label.priority != rhs.label.priority {
                    return lhs.label.priority > rhs.label.priority
                }
                return lhs.label.id < rhs.label.id
            }
            self.artworkBounds = BeckMapCanvas.makeArtworkBounds(
                document: document,
                renderedSegments: renderedSegments,
                renderedWaterways: renderedWaterways
            )
            self.debugReferenceImage = loadsDebugReference
                ? BeckMapCanvas.loadDebugReference(for: document)
                : nil
        }
    }

    struct RenderedSegment {
        let id: String
        let lineID: TubeLineID
        let path: Path
        let collisionEdges: [BeckMapCollisionEdge]
        let trainPath: BeckMapTrainPath
    }

    struct RenderedLineGroup {
        let lineID: TubeLineID
        let segments: [RenderedSegment]
        let combinedPath: Path
    }

    struct RenderedWaterway {
        let id: String
        let name: String
        let path: Path
        let strokeWidth: CGFloat
        let outlineWidth: CGFloat
    }

    struct RenderedStationMarker {
        let stationID: String
        let anchor: BeckMapPoint
        let primitives: [RenderedStationPrimitive]
    }

    enum RenderedStationPrimitive {
        case connector(BeckMapLinePrimitive, Path)
        case walkingConnector(BeckMapLinePrimitive, Path)
        case circle(BeckMapCirclePrimitive, Path)
        case tick(BeckMapTickPrimitive, Path)
    }

    struct RenderedLabel {
        let label: BeckMapLabelRecord
        let artworkAnchor: CGPoint
        let artworkOffset: CGVector
        let rotation: CGAffineTransform
    }

    struct LabelMetrics {
        let fontSize: CGFloat
        let bounds: CGRect
    }

    private struct CameraInitializationKey: Hashable {
        let documentID: String
        let graphGeneratedAt: String
        let width: CGFloat
        let height: CGFloat
        let referenceOverlayVisible: Bool
    }
}

struct BeckMapTrainPath {
    let fromStationID: String
    let toStationID: String
    let pathDirection: BeckMapPathDirection

    private let points: [CGPoint]
    private let cumulativeLengths: [CGFloat]
    private let totalLength: CGFloat

    init(
        fromStationID: String,
        toStationID: String,
        pathDirection: BeckMapPathDirection,
        edges: [BeckMapCollisionEdge]
    ) {
        self.fromStationID = fromStationID
        self.toStationID = toStationID
        self.pathDirection = pathDirection

        guard let firstEdge = edges.first else {
            points = []
            cumulativeLengths = []
            totalLength = 0
            return
        }

        let points = [firstEdge.start] + edges.map(\.end)
        var cumulativeLengths: [CGFloat] = [0]
        cumulativeLengths.reserveCapacity(points.count)
        for (start, end) in zip(points, points.dropFirst()) {
            cumulativeLengths.append(
                cumulativeLengths[cumulativeLengths.endIndex - 1]
                    + hypot(end.x - start.x, end.y - start.y)
            )
        }
        self.points = points
        self.cumulativeLengths = cumulativeLengths
        totalLength = cumulativeLengths.last ?? 0
    }

    func point(
        progress: Double,
        previousStationID: String,
        nextStationID: String
    ) -> CGPoint? {
        let logicalProgress: Double
        if previousStationID == fromStationID, nextStationID == toStationID {
            logicalProgress = progress
        } else if previousStationID == toStationID, nextStationID == fromStationID {
            logicalProgress = 1 - progress
        } else {
            return nil
        }

        let pathProgress = pathDirection == .forward
            ? logicalProgress
            : 1 - logicalProgress
        return point(atPathProgress: pathProgress)
    }

    private func point(atPathProgress progress: Double) -> CGPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1, totalLength > 0 else { return first }

        let clampedProgress = min(1, max(0, progress))
        if clampedProgress <= 0 { return first }
        if clampedProgress >= 1 { return points.last }

        let target = totalLength * CGFloat(clampedProgress)
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
        let edgeLength = cumulativeLengths[endIndex] - cumulativeLengths[startIndex]
        guard edgeLength > 0 else { return points[endIndex] }
        let fraction = (target - cumulativeLengths[startIndex]) / edgeLength
        let start = points[startIndex]
        let end = points[endIndex]
        return CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        )
    }
}

struct BeckMapLabelBlocker: Equatable {
    let stationID: String
    let frame: CGRect
}

struct BeckMapCollisionEdge: Equatable {
    let start: CGPoint
    let end: CGPoint
}

struct BeckMapLineHitTarget: Equatable {
    let segmentID: String
    let edges: [BeckMapCollisionEdge]
}

enum BeckMapLineHitTester {
    static func nearestSegmentID(
        to point: CGPoint,
        among targets: [BeckMapLineHitTarget],
        maximumDistance: CGFloat
    ) -> String? {
        guard maximumDistance >= 0, maximumDistance.isFinite else { return nil }
        let maximumSquaredDistance = maximumDistance * maximumDistance
        var nearestSegmentID: String?
        var nearestSquaredDistance = maximumSquaredDistance

        for target in targets {
            for edge in target.edges {
                let candidateSquaredDistance = squaredDistance(from: point, to: edge)
                if candidateSquaredDistance <= nearestSquaredDistance {
                    nearestSegmentID = target.segmentID
                    nearestSquaredDistance = candidateSquaredDistance
                }
            }
        }
        return nearestSegmentID
    }

    private static func squaredDistance(
        from point: CGPoint,
        to edge: BeckMapCollisionEdge
    ) -> CGFloat {
        let deltaX = edge.end.x - edge.start.x
        let deltaY = edge.end.y - edge.start.y
        let squaredLength = deltaX * deltaX + deltaY * deltaY
        guard squaredLength > 0.000_001 else {
            let pointDeltaX = point.x - edge.start.x
            let pointDeltaY = point.y - edge.start.y
            return pointDeltaX * pointDeltaX + pointDeltaY * pointDeltaY
        }

        let progress = min(
            1,
            max(
                0,
                ((point.x - edge.start.x) * deltaX + (point.y - edge.start.y) * deltaY)
                    / squaredLength
            )
        )
        let closestPoint = CGPoint(
            x: edge.start.x + deltaX * progress,
            y: edge.start.y + deltaY * progress
        )
        let pointDeltaX = point.x - closestPoint.x
        let pointDeltaY = point.y - closestPoint.y
        return pointDeltaX * pointDeltaX + pointDeltaY * pointDeltaY
    }
}

struct BeckMapLineBlocker: Equatable {
    let start: CGPoint
    let end: CGPoint
    let clearance: CGFloat

    var bounds: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: max(0.5, abs(end.x - start.x)),
            height: max(0.5, abs(end.y - start.y))
        ).insetBy(dx: -clearance, dy: -clearance)
    }

    func intersects(_ frame: CGRect) -> Bool {
        let rect = frame.insetBy(dx: -clearance, dy: -clearance)
        guard bounds.intersects(frame) else { return false }
        if rect.contains(start) || rect.contains(end) { return true }

        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let boundaries: [(CGFloat, CGFloat)] = [
            (-deltaX, start.x - rect.minX),
            (deltaX, rect.maxX - start.x),
            (-deltaY, start.y - rect.minY),
            (deltaY, rect.maxY - start.y),
        ]
        var minimumProgress: CGFloat = 0
        var maximumProgress: CGFloat = 1
        for (direction, distance) in boundaries {
            if abs(direction) < 0.000_001 {
                if distance < 0 { return false }
                continue
            }
            let progress = distance / direction
            if direction < 0 {
                minimumProgress = max(minimumProgress, progress)
            } else {
                maximumProgress = min(maximumProgress, progress)
            }
            if minimumProgress > maximumProgress { return false }
        }
        return true
    }
}

fileprivate struct BeckMapSpatialIndex<Element> {
    private struct Cell: Hashable {
        let column: Int
        let row: Int
    }

    private let cellSize: CGFloat
    private var elements: [Element] = []
    private var elementIndicesByCell: [Cell: [Int]] = [:]

    init(cellSize: CGFloat = 96) {
        self.cellSize = max(1, cellSize)
    }

    init(
        _ elements: [Element],
        cellSize: CGFloat = 96,
        bounds: (Element) -> CGRect
    ) {
        self.init(cellSize: cellSize)
        for element in elements {
            insert(element, bounds: bounds(element))
        }
    }

    mutating func insert(_ element: Element, bounds: CGRect) {
        guard let cellRange = cellRange(for: bounds) else { return }
        let elementIndex = elements.endIndex
        elements.append(element)
        for column in cellRange.columns {
            for row in cellRange.rows {
                elementIndicesByCell[Cell(column: column, row: row), default: []]
                    .append(elementIndex)
            }
        }
    }

    func containsIntersecting(
        _ frame: CGRect,
        where predicate: (Element) -> Bool
    ) -> Bool {
        guard let cellRange = cellRange(for: frame) else { return false }
        for column in cellRange.columns {
            for row in cellRange.rows {
                let cell = Cell(column: column, row: row)
                for elementIndex in elementIndicesByCell[cell, default: []]
                where predicate(elements[elementIndex]) {
                    return true
                }
            }
        }
        return false
    }

    private func cellRange(
        for rawRect: CGRect
    ) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        let rect = rawRect.standardized
        guard rect.minX.isFinite, rect.maxX.isFinite,
              rect.minY.isFinite, rect.maxY.isFinite else {
            return nil
        }
        let minimumColumn = Int(floor(rect.minX / cellSize))
        let maximumColumn = Int(floor(rect.maxX / cellSize))
        let minimumRow = Int(floor(rect.minY / cellSize))
        let maximumRow = Int(floor(rect.maxY / cellSize))
        return (minimumColumn ... maximumColumn, minimumRow ... maximumRow)
    }
}

enum BeckMapLabelCollisionResolver {
    static func accepts(
        _ frame: CGRect,
        markerBlockers: [BeckMapLabelBlocker],
        lineBlockers: [BeckMapLineBlocker],
        occupied: [CGRect]
    ) -> Bool {
        !markerBlockers.contains(where: { $0.frame.intersects(frame) })
            && !lineBlockers.contains(where: { $0.intersects(frame) })
            && !occupied.contains(where: { $0.intersects(frame) })
    }

    fileprivate static func accepts(
        _ frame: CGRect,
        markerIndex: BeckMapSpatialIndex<BeckMapLabelBlocker>,
        lineIndex: BeckMapSpatialIndex<BeckMapLineBlocker>,
        occupiedIndex: BeckMapSpatialIndex<CGRect>
    ) -> Bool {
        !markerIndex.containsIntersecting(frame) { $0.frame.intersects(frame) }
            && !lineIndex.containsIntersecting(frame) { $0.intersects(frame) }
            && !occupiedIndex.containsIntersecting(frame) { $0.intersects(frame) }
    }
}

enum BeckMapLabelBounds {
    static func backgroundBounds(
        textSize: CGSize,
        alignment: BeckMapLabelAlignment,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat
    ) -> CGRect {
        let originX: CGFloat
        switch alignment {
        case .leading:
            originX = 0
        case .centre:
            originX = -textSize.width / 2
        case .trailing:
            originX = -textSize.width
        }
        let textBounds = CGRect(
            x: originX,
            y: -textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        return textBounds.insetBy(
            dx: -horizontalPadding,
            dy: -verticalPadding
        )
    }
}

struct BeckMapLabelPlacementCandidate: Equatable {
    let position: CGPoint
    let alignment: BeckMapLabelAlignment
}

struct BeckMapLabelPlacementOption: Equatable {
    let alignment: BeckMapLabelAlignment
    let screenOffset: CGVector
}

struct StationLabelLayoutInput {
    let id: String
    let priority: Int
    let tier: BeckMapLabelVisibilityTier
    let selected: Bool
    let stationScreenPosition: CGPoint
    let markerFrame: CGRect
    let preferredAlignment: BeckMapLabelAlignment
    let screenOffset: CGVector
    let rotation: CGAffineTransform
    let boundsByAlignment: [BeckMapLabelAlignment: CGRect]
}

struct StationLabelPlacement {
    let labelID: String
    let position: CGPoint
    let alignment: BeckMapLabelAlignment
    let rotation: CGAffineTransform
    let backgroundBounds: CGRect
    let collisionFrame: CGRect
}

enum StationLabelLayoutEngine {
    static let horizontalViewportInset: CGFloat = 8
    static let maximumTopViewportInset: CGFloat = 96
    static let maximumBottomViewportInset: CGFloat = 88
    static let horizontalLabelClearance: CGFloat = 4
    static let verticalLabelClearance: CGFloat = 3

    static func availableViewport(in size: CGSize) -> CGRect {
        let topInset = min(maximumTopViewportInset, max(8, size.height * 0.11))
        let bottomInset = min(maximumBottomViewportInset, max(8, size.height * 0.1))
        return CGRect(
            x: horizontalViewportInset,
            y: topInset,
            width: max(1, size.width - horizontalViewportInset * 2),
            height: max(1, size.height - topInset - bottomInset)
        )
    }

    static func layout(
        inputs: [StationLabelLayoutInput],
        viewport: CGRect,
        markerBlockers: [BeckMapLabelBlocker],
        lineBlockers: [BeckMapLineBlocker]
    ) -> [StationLabelPlacement] {
        let orderedInputs = inputs.sorted { lhs, rhs in
            if lhs.selected != rhs.selected { return lhs.selected }
            if lhs.tier != rhs.tier {
                return lhs.tier.renderPriority > rhs.tier.renderPriority
            }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.id < rhs.id
        }
        let markerIndex = BeckMapSpatialIndex(markerBlockers, bounds: \.frame)
        let lineIndex = BeckMapSpatialIndex(lineBlockers, bounds: \.bounds)
        var occupiedIndex = BeckMapSpatialIndex<CGRect>()
        var placements: [StationLabelPlacement] = []

        for input in orderedInputs {
            let options = BeckMapLabelPlacementResolver.placementOptions(
                authoredAlignment: input.preferredAlignment,
                screenOffset: input.screenOffset
            )
            var bestPlacement: (score: Int, placement: StationLabelPlacement)?

            for (optionIndex, option) in options.enumerated() {
                guard let backgroundBounds = input.boundsByAlignment[option.alignment] else {
                    continue
                }
                let candidates = BeckMapLabelPlacementResolver.candidates(
                    stationScreenPosition: input.stationScreenPosition,
                    markerFrame: input.markerFrame,
                    labelBounds: backgroundBounds,
                    screenOffset: option.screenOffset,
                    authoredAlignment: option.alignment
                )
                for (candidateIndex, candidate) in candidates.enumerated() {
                    let labelFrame = backgroundBounds
                        .applying(input.rotation)
                        .standardized
                        .offsetBy(dx: candidate.position.x, dy: candidate.position.y)
                    guard viewport.contains(labelFrame) else { continue }
                    let collisionFrame = labelFrame.insetBy(
                        dx: -horizontalLabelClearance,
                        dy: -verticalLabelClearance
                    )
                    guard BeckMapLabelCollisionResolver.accepts(
                        collisionFrame,
                        markerIndex: markerIndex,
                        lineIndex: lineIndex,
                        occupiedIndex: occupiedIndex
                    ) else { continue }

                    let score = optionIndex * 18 + candidateIndex
                    let placement = StationLabelPlacement(
                        labelID: input.id,
                        position: candidate.position,
                        alignment: candidate.alignment,
                        rotation: input.rotation,
                        backgroundBounds: backgroundBounds,
                        collisionFrame: collisionFrame
                    )
                    if bestPlacement.map({ score < $0.score }) ?? true {
                        bestPlacement = (score, placement)
                    }
                }
            }

            guard let placement = bestPlacement?.placement else { continue }
            placements.append(placement)
            occupiedIndex.insert(
                placement.collisionFrame,
                bounds: placement.collisionFrame
            )
        }
        return placements
    }
}

enum BeckMapLabelVisibilityPolicy {
    // The authored full map uses one immutable design space. Absolute projected
    // scale therefore tracks actual station spacing more reliably than a ratio
    // to the device-dependent fit scale.
    static let overviewMinimumCameraScale: CGFloat = 0.1
    static let networkMinimumCameraScale: CGFloat = 0.18
    static let localMinimumCameraScale: CGFloat = 0.3
    static let minorMinimumCameraScale: CGFloat = 0.42

    // Labels enter the layout compactly, then grow as the additional map
    // spacing created by zooming makes room for them. Collision resolution
    // remains authoritative, so denser tiers never obscure higher priorities.
    static let fontGrowthStartCameraScale: CGFloat = 0.3
    static let fullSizeFontCameraScale: CGFloat = 0.95

    static func shows(
        _ tier: BeckMapLabelVisibilityTier,
        at cameraScale: CGFloat
    ) -> Bool {
        switch tier {
        case .overview:
            cameraScale >= overviewMinimumCameraScale
        case .network:
            cameraScale >= networkMinimumCameraScale
        case .local:
            cameraScale >= localMinimumCameraScale
        case .minor:
            cameraScale >= minorMinimumCameraScale
        }
    }

    static func fontSize(
        for tier: BeckMapLabelVisibilityTier,
        at cameraScale: CGFloat
    ) -> CGFloat {
        let range: ClosedRange<CGFloat> = switch tier {
        case .overview:
            12.5 ... 15
        case .network:
            10.5 ... 14
        case .local:
            9.5 ... 14
        case .minor:
            9 ... 13.5
        }

        guard cameraScale > fontGrowthStartCameraScale else {
            return range.lowerBound
        }
        guard cameraScale < fullSizeFontCameraScale else {
            return range.upperBound
        }
        let progress = (cameraScale - fontGrowthStartCameraScale)
            / (fullSizeFontCameraScale - fontGrowthStartCameraScale)
        return range.lowerBound + (range.upperBound - range.lowerBound) * progress
    }
}

enum BeckMapOverviewVisibilityPolicy {
    static let fullyVisibleMaximumZoomRatio: Double = 1.08
    static let hiddenZoomRatio: Double = 1.55
    static let closestStationAutoHideZoomRatio: Double = 1.38

    static func opacity(
        at cameraScale: Double,
        fittedScale: Double,
        reduceMotion: Bool = false
    ) -> Double {
        let zoomRatio = cameraScale / max(0.000_001, fittedScale)
        if reduceMotion {
            return zoomRatio < hiddenZoomRatio ? 1 : 0
        }
        guard zoomRatio > fullyVisibleMaximumZoomRatio else { return 1 }
        guard zoomRatio < hiddenZoomRatio else { return 0 }
        let fadeProgress = (zoomRatio - fullyVisibleMaximumZoomRatio)
            / (hiddenZoomRatio - fullyVisibleMaximumZoomRatio)
        return 1 - fadeProgress
    }

    static func shouldHideClosestStation(
        at cameraScale: Double,
        fittedScale: Double
    ) -> Bool {
        cameraScale / max(0.000_001, fittedScale) >= closestStationAutoHideZoomRatio
    }

    static func shouldShowReset(
        at cameraScale: Double,
        fittedScale: Double
    ) -> Bool {
        cameraScale / max(0.000_001, fittedScale) > fullyVisibleMaximumZoomRatio
    }
}

enum BeckMapLabelPlacementResolver {
    static let preferredGap: CGFloat = 6
    static let maximumGap: CGFloat = 18
    static let maximumTangentialOffset: CGFloat = 30
    private static let outwardAdjustments: [CGFloat] = [0, 6, 12]
    private static let tangentialAdjustments: [CGFloat] = [0, -18, 18, -30, 30]

    static func placementOptions(
        authoredAlignment: BeckMapLabelAlignment,
        screenOffset: CGVector
    ) -> [BeckMapLabelPlacementOption] {
        let verticalMagnitude = max(1, abs(screenOffset.dy))
        let oppositeVerticalOffset = CGVector(
            dx: screenOffset.dx,
            dy: screenOffset.dy < 0 ? verticalMagnitude : -verticalMagnitude
        )

        switch authoredAlignment {
        case .leading:
            return [
                .init(alignment: .leading, screenOffset: screenOffset),
                .init(alignment: .trailing, screenOffset: screenOffset),
                .init(alignment: .centre, screenOffset: screenOffset),
                .init(alignment: .centre, screenOffset: oppositeVerticalOffset),
            ]
        case .trailing:
            return [
                .init(alignment: .trailing, screenOffset: screenOffset),
                .init(alignment: .leading, screenOffset: screenOffset),
                .init(alignment: .centre, screenOffset: screenOffset),
                .init(alignment: .centre, screenOffset: oppositeVerticalOffset),
            ]
        case .centre:
            return [
                .init(alignment: .centre, screenOffset: screenOffset),
                .init(alignment: .centre, screenOffset: oppositeVerticalOffset),
                .init(alignment: .leading, screenOffset: screenOffset),
                .init(alignment: .trailing, screenOffset: screenOffset),
            ]
        }
    }

    static func candidates(
        stationScreenPosition: CGPoint,
        markerFrame: CGRect,
        labelBounds: CGRect,
        screenOffset: CGVector,
        authoredAlignment: BeckMapLabelAlignment
    ) -> [BeckMapLabelPlacementCandidate] {
        let markerFrame = markerFrame.standardized
        let verticalOffset = min(
            maximumTangentialOffset,
            max(-maximumTangentialOffset, screenOffset.dy)
        )
        let horizontalOffset = min(
            maximumTangentialOffset,
            max(-maximumTangentialOffset, screenOffset.dx)
        )
        let verticalDirection: CGFloat = screenOffset.dy < 0 ? -1 : 1

        return outwardAdjustments.flatMap { outwardAdjustment in
            tangentialAdjustments.map { tangentialAdjustment in
                let gap = preferredGap + outwardAdjustment
                let position: CGPoint
                switch authoredAlignment {
                case .leading:
                    position = CGPoint(
                        x: markerFrame.maxX + gap - labelBounds.minX,
                        y: stationScreenPosition.y + verticalOffset + tangentialAdjustment
                    )
                case .trailing:
                    position = CGPoint(
                        x: markerFrame.minX - gap - labelBounds.maxX,
                        y: stationScreenPosition.y + verticalOffset + tangentialAdjustment
                    )
                case .centre where verticalDirection < 0:
                    position = CGPoint(
                        x: stationScreenPosition.x + horizontalOffset + tangentialAdjustment,
                        y: markerFrame.minY - gap - labelBounds.maxY
                    )
                case .centre:
                    position = CGPoint(
                        x: stationScreenPosition.x + horizontalOffset + tangentialAdjustment,
                        y: markerFrame.maxY + gap - labelBounds.minY
                    )
                }
                return BeckMapLabelPlacementCandidate(
                    position: position,
                    alignment: authoredAlignment
                )
            }
        }
    }
}

private extension CGPoint {
    init(_ point: BeckMapPoint) {
        self.init(x: point.x, y: point.y)
    }
}

private enum BeckMapGesturePhase {
    case began
    case changed
    case ended
}

private struct BeckMapGestureSurface: UIViewRepresentable {
    let onPan: (CGSize, BeckMapGesturePhase) -> Void
    let onPinch: (CGFloat, CGPoint, BeckMapGesturePhase) -> Void
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
        var parent: BeckMapGestureSurface

        init(parent: BeckMapGestureSurface) {
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

        private func phase(for state: UIGestureRecognizer.State) -> BeckMapGesturePhase {
            switch state {
            case .began: .began
            case .changed: .changed
            default: .ended
            }
        }
    }
}
