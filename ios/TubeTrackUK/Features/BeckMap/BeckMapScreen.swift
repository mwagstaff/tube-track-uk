import SwiftUI
import UIKit
import QuartzCore

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
    let mobileCoverageMode: MobileCoverageMode
    let mobileCoverageBySegmentID: [String: MobileCoverageAvailability]
    let mobileCoverageByStationID: [String: MobileCoverageAvailability]
    let stationOnlyCoverageStationIDs: Set<String>
    var highlightsJourney = false

    var emphasizesIssues: Bool {
        disruptionDisplayMode == .issues
    }

    var showsMobileCoverage: Bool {
        mobileCoverageMode.isActive
    }

    func mobileCoverageAvailability(forSegmentID segmentID: String) -> MobileCoverageAvailability {
        mobileCoverageBySegmentID[segmentID] ?? .unknown
    }

    func mobileCoverageAvailability(forStationID stationID: String) -> MobileCoverageAvailability {
        mobileCoverageByStationID[stationID] ?? .unknown
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
    let onInteractionChange: (Bool) -> Void
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
                    onInteractionChange: onInteractionChange,
                    stationSelectionGeneration: appState.stationSelectionGeneration,
                    onStationTap: { stationID, preferredLineID in
                        guard let station = graph.stationsByID[stationID] else { return }
                        withAnimation(.smooth(duration: 0.35)) {
                            appState.select(
                                station: station,
                                preferredDepartureLineID: preferredLineID
                            )
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
                ProgressView("Loading map…")
            } else if appState.isLoadingGraph {
                ProgressView("Loading map…")
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
            let requestedRegion = selectedRegion
            isLoadingDocument = true
            defer { isLoadingDocument = false }
            do {
                let loadedDocument: BeckMapDocument
                if requestedRegion == .fullUnderground,
                   let startupDocument = appState.initialBeckMapDocument {
                    loadedDocument = startupDocument
                } else {
                    loadedDocument = try await Task.detached(priority: .userInitiated) {
                        try BeckMapRepository().load(
                            region: requestedRegion,
                            graph: graph
                        )
                    }.value
                }
                guard !Task.isCancelled else { return }
                let loadsDebugReference = referenceOverlayVisible
                let loadedRenderCache = await Task.detached(priority: .userInitiated) {
                    BeckMapCanvas.RenderCache(
                        document: loadedDocument,
                        loadsDebugReference: loadsDebugReference
                    )
                }.value
                guard !Task.isCancelled else { return }
                renderCache = loadedRenderCache
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

        if let disruptionScope = appState.disruptionHighlightScope {
            for disruption in appState.visibleDisruptions
                where disruptionScope.includes(disruption)
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
            affectedSegmentIDs = Set(appState.mapHighlightedDisruptions.flatMap {
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
            closedLineIDs: networkSummary.closedLineIDs,
            mobileCoverageMode: appState.mobileCoverageMode,
            mobileCoverageBySegmentID: mobileCoverageBySegmentID(graph: graph),
            mobileCoverageByStationID: mobileCoverageByStationID(graph: graph),
            stationOnlyCoverageStationIDs: appState.mobileCoverageMode.isActive
                ? appState.mobileCoverage?.stationOnlyCoverageStationIDs ?? []
                : []
        )
    }

    private func mobileCoverageBySegmentID(
        graph: TubeGraph
    ) -> [String: MobileCoverageAvailability] {
        guard appState.mobileCoverageMode.isActive,
              let coverage = appState.mobileCoverage else { return [:] }
        return Dictionary(uniqueKeysWithValues: graph.segments.map { segment in
            (
                segment.id,
                coverage.availability(for: segment, mode: appState.mobileCoverageMode)
            )
        })
    }

    private func mobileCoverageByStationID(
        graph: TubeGraph
    ) -> [String: MobileCoverageAvailability] {
        guard appState.mobileCoverageMode.isActive,
              let coverage = appState.mobileCoverage else { return [:] }
        return Dictionary(uniqueKeysWithValues: graph.stations.map { station in
            (
                station.id,
                coverage.availability(
                    for: station.id,
                    mode: appState.mobileCoverageMode
                )
            )
        })
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

struct BeckMapCanvas: View {
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
    let onInteractionChange: (Bool) -> Void
    let stationSelectionGeneration: Int
    let onStationTap: (String, TubeLineID?) -> Void
    let onDisruptionTap: (String) -> Void
    let onBackgroundTap: () -> Void

    private var renderedSegments: [RenderedSegment] { renderCache.renderedSegments }
    private var renderedLineGroups: [RenderedLineGroup] { renderCache.renderedLineGroups }
    private var renderedWaterways: [RenderedWaterway] { renderCache.renderedWaterways }
    private var renderedStationMarkers: [RenderedStationMarker] { renderCache.renderedStationMarkers }
    private var renderedLabels: [RenderedLabel] { renderCache.renderedLabels }
    private var artworkBounds: CGRect { renderCache.artworkBounds }
    private var debugReferenceImage: UIImage? { renderCache.debugReferenceImage }

    @State private var camera = BeckMapLayerCamera()
    @State private var renderScale: CGFloat = 0.35
    @State private var renderOffset = CGSize.zero
    @State private var minimumCameraScale: CGFloat = 0.2
    @State private var maximumCameraScale: CGFloat = 3.8
    @State private var fittedCameraScale: CGFloat = 0.35
    @State private var panStartOffset: CGSize?
    @State private var pinchStartScale: CGFloat?
    @State private var pinchMapPoint: CGPoint?
    @State private var isPanning = false
    @State private var isDecelerating = false
    @State private var isPinching = false
    @State private var cameraAnimator = BeckMapCameraAnimator()
    @State private var isAnimatingCamera = false

    private var cameraScale: CGFloat { camera.scale }
    private var cameraOffset: CGSize { camera.offset }

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
        onInteractionChange: @escaping (Bool) -> Void,
        stationSelectionGeneration: Int,
        onStationTap: @escaping (String, TubeLineID?) -> Void,
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
        self.onInteractionChange = onInteractionChange
        self.stationSelectionGeneration = stationSelectionGeneration
        self.onStationTap = onStationTap
        self.onDisruptionTap = onDisruptionTap
        self.onBackgroundTap = onBackgroundTap
    }

    var body: some View {
        GeometryReader { proxy in
            let overscan = BeckMapArtworkCachePolicy.overscan
            let renderScale = self.renderScale
            let renderOffset = self.renderOffset
            let canvasOffset = CGSize(
                width: renderOffset.width + overscan,
                height: renderOffset.height + overscan
            )
            let artworkCanvasSize = CGSize(
                width: proxy.size.width + overscan * 2,
                height: proxy.size.height + overscan * 2
            )
            let artworkCacheKey = BeckMapArtworkCacheKey(
                documentID: document.identifier,
                graphGeneratedAt: document.source.graphGeneratedAt,
                presentation: presentation,
                colorScheme: colorScheme,
                referenceOverlayVisible: isReferenceOverlayActive,
                cameraScale: renderScale,
                cameraOffset: renderOffset,
                canvasSize: artworkCanvasSize
            )

            ZStack(alignment: .topLeading) {
                palette.background

                BeckMapRetainedCanvas(
                    key: artworkCacheKey,
                    camera: camera,
                    renderScale: renderScale,
                    renderOffset: renderOffset,
                    overscan: overscan,
                    canvasSize: artworkCanvasSize,
                    colorScheme: colorScheme,
                    renderer: { context, size in
                        drawArtwork(
                            context: &context,
                            size: size,
                            cameraScale: renderScale,
                            cameraOffset: canvasOffset
                        )
                    }
                )
                .allowsHitTesting(false)

                if !isReferenceOverlayActive {
                    let labelCacheKey = BeckMapLabelCacheKey(
                        documentID: document.identifier,
                        graphGeneratedAt: document.source.graphGeneratedAt,
                        presentation: presentation,
                        colorScheme: colorScheme,
                        cameraScale: renderScale,
                        cameraOffset: renderOffset,
                        canvasSize: artworkCanvasSize,
                        labelTypeScale: labelTypeScale
                    )
                    BeckMapRetainedCanvas(
                        key: labelCacheKey,
                        camera: camera,
                        renderScale: renderScale,
                        renderOffset: renderOffset,
                        overscan: overscan,
                        canvasSize: artworkCanvasSize,
                        colorScheme: colorScheme,
                        renderer: { context, size in
                            drawLabels(
                                context: &context,
                                viewport: size,
                                cameraScale: renderScale,
                                cameraOffset: canvasOffset
                            )
                            var markerContext = context
                            markerContext.concatenate(
                                CGAffineTransform(
                                    a: renderScale,
                                    b: 0,
                                    c: 0,
                                    d: renderScale,
                                    tx: canvasOffset.width,
                                    ty: canvasOffset.height
                                )
                            )
                            drawEmphasizedStationMarkers(
                                context: &markerContext,
                                cameraScale: renderScale
                            )
                        }
                    )
                    .allowsHitTesting(false)
                }

                if !liveTrains.isEmpty, !isReferenceOverlayActive {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        GeometryReader { viewport in
                            let trainCacheKey = BeckMapTrainCacheKey(
                                trains: liveTrains,
                                selectedTrainID: appState.selectedTrainID,
                                closedLineIDs: appState.currentlyClosedLineIDs,
                                renderSecond: Int(timeline.date.timeIntervalSinceReferenceDate),
                                cameraScale: renderScale,
                                cameraOffset: renderOffset,
                                canvasSize: artworkCanvasSize,
                                colorScheme: colorScheme
                            )
                            ZStack {
                                BeckMapRetainedCanvas(
                                    key: trainCacheKey,
                                    camera: camera,
                                    renderScale: renderScale,
                                    renderOffset: renderOffset,
                                    overscan: overscan,
                                    canvasSize: artworkCanvasSize,
                                    colorScheme: colorScheme,
                                    renderer: { context, size in
                                        drawTrains(
                                            context: &context,
                                            size: size,
                                            date: timeline.date,
                                            cameraScale: renderScale,
                                            cameraOffset: canvasOffset
                                        )
                                    }
                                )

                                if !isPanning, !isDecelerating, !isPinching, !isAnimatingCamera,
                                   let train = appState.selectedTrain,
                                   let markerPoint = trainScreenPoint(
                                       for: train,
                                       at: timeline.date
                                   ),
                                   CGRect(origin: .zero, size: viewport.size).contains(markerPoint),
                                   let nextStopName = appState.graph?
                                       .stationsByID[train.nextStationID]?.name {
                                    TrainMapCalloutOverlay(
                                        train: train,
                                        servicePresentation: .resolve(
                                            lineID: train.lineID,
                                            closedLineIDs: appState.currentlyClosedLineIDs
                                        ),
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
                    allowsMomentum: !reduceMotion,
                    onTouchDown: {
                        let wasAnimating = isAnimatingCamera
                        cancelCameraAnimation()
                        return wasAnimating
                    },
                    onInteractionChange: onInteractionChange,
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
                    onTap: { location in
                        selectMapFeature(at: location, viewport: proxy.size)
                    }
                )
                .accessibilityHidden(true)
            }
            .clipped()
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
                if presentation.highlightsJourney {
                    let routeStations = document.segments.filter { presentation.affectedSegmentIDs.contains($0.id) }
                        .flatMap { [$0.fromStationID, $0.toStationID] }
                    focus(on: presentation.affectedStationIDs.union(routeStations), in: proxy.size)
                } else if appState.sharedMapViewport != nil {
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
                resetCamera(in: proxy.size, animated: true)
            }
            .onChange(of: locationFocusRequest?.id) { _, _ in
                guard appState.mapPresentationMode == .beck,
                      let locationFocusRequest else { return }
                focus(on: locationFocusRequest, in: proxy.size)
            }
            .onChange(of: contentVerticalBias) { oldBias, newBias in
                let delta = newBias - oldBias
                animateCamera(
                    toScale: cameraScale,
                    offset: CGSize(width: cameraOffset.width, height: cameraOffset.height - delta),
                    viewportSize: proxy.size,
                    duration: 0.32
                )
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
            .onChange(of: appState.disruptionOverviewFocusGeneration) { _, _ in
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
            cancelCameraAnimation()
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

                ForEach(document.stationMarkers.filter { !presentation.highlightsJourney || presentation.affectedStationIDs.contains($0.stationID) }) { marker in
                    if marker.lineIDs.isEmpty {
                        Button(stationAccessibilityLabel(marker: marker, lineID: nil)) {
                            onStationTap(marker.stationID, nil)
                        }
                    } else {
                        ForEach(marker.lineIDs) { lineID in
                            Button(stationAccessibilityLabel(marker: marker, lineID: lineID)) {
                                onStationTap(marker.stationID, lineID)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Interactive London rail map")
    }

    private func stationAccessibilityLabel(
        marker: BeckMapStationMarkerRecord,
        lineID: TubeLineID?
    ) -> String {
        var parts = [marker.name]
        if presentation.highlightsJourney { parts.append("Journey station") }
        if let lineID {
            parts.append(presentation.highlightsJourney ? lineID.displayName : "\(lineID.displayName) departures")
        }
        guard presentation.showsMobileCoverage else {
            return parts.joined(separator: ", ")
        }
        if presentation.stationOnlyCoverageStationIDs.contains(marker.stationID) {
            parts.append("mobile coverage in station only")
        } else {
            switch presentation.mobileCoverageAvailability(forStationID: marker.stationID) {
            case .available: parts.append("mobile coverage available")
            case .unavailable: parts.append("no verified mobile coverage")
            case .unknown: parts.append("mobile coverage unknown")
            case .outOfScope: break
            }
        }
        return parts.joined(separator: ", ")
    }

    private func trainAccessibilityLabel(for train: LiveTubeTrain) -> String {
        let destination = train.destination ?? "unknown destination"
        let nextStop = appState.graph?.stationsByID[train.nextStationID]?.name
            ?? "unknown next stop"
        let summary = "Train to \(destination), next stop \(nextStop)"
        let presentation = LiveTrainServicePresentation.resolve(
            lineID: train.lineID,
            closedLineIDs: appState.currentlyClosedLineIDs
        )
        guard let note = presentation.informationalNote(for: train.lineID) else {
            return summary
        }
        return "\(summary). \(note)"
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

    private func drawArtwork(
        context: inout GraphicsContext,
        size: CGSize,
        cameraScale: CGFloat,
        cameraOffset: CGSize
    ) {
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
            let uniformMuted = traceMode
                ? false
                : uniformMuting(for: lineGroup)
            let mixedSegments: [(
                segment: RenderedSegment,
                muted: Bool,
                coverage: MobileCoverageAvailability
            )] = uniformMuted == nil
                ? lineGroup.segments.map { segment in
                    let coverage = presentation.mobileCoverageAvailability(
                        forSegmentID: segment.id
                    )
                    return (
                        segment,
                        presentation.showsMobileCoverage
                            ? coverage != .available
                            : presentation.selectedLineID != nil
                                && presentation.selectedLineID != segment.lineID
                                || presentation.mutesSegment(
                                    id: segment.id,
                                    lineID: segment.lineID,
                                    isAffected: presentation.affectedSegmentIDs.contains(segment.id)
                                ),
                        coverage
                    )
                }
                : []
            if let casing = palette.northernLineCasing,
               let casingWidth = palette.casingWidth(
                   for: lineGroup.lineID,
                   routeWidth: document.styles.routeStrokeWidth
               ) {
                if uniformMuted == false {
                    mapContext.stroke(
                        lineGroup.combinedPath,
                        with: .color(casing),
                        style: StrokeStyle(
                            lineWidth: casingWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                } else if uniformMuted == nil {
                    for (segment, muted, _) in mixedSegments {
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

            if let muted = uniformMuted {
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
                for (segment, muted, coverage) in mixedSegments {
                    let lineWidth = lineGroup.lineID.usesParallelSchematicStroke
                        ? document.styles.parallelRouteOuterStrokeWidth(for: lineGroup.lineID)
                        : document.styles.routeStrokeWidth
                    mapContext.stroke(
                        segment.path,
                        with: .color(
                            presentation.showsMobileCoverage
                                ? mobileCoverageRouteColor(
                                    availability: coverage,
                                    lineID: segment.lineID
                                )
                                : palette.routeColor(for: segment.lineID, muted: muted)
                        ),
                        style: mobileCoverageStrokeStyle(
                            availability: presentation.showsMobileCoverage ? coverage : .available,
                            lineWidth: lineWidth
                        )
                    )
                }
            }
            if lineGroup.lineID.usesParallelSchematicStroke {
                if presentation.showsMobileCoverage {
                    for (segment, _, coverage) in mixedSegments {
                        mapContext.stroke(
                            segment.path,
                            with: .color(palette.paper.opacity(coverage == .outOfScope ? 0.35 : 1)),
                            style: mobileCoverageStrokeStyle(
                                availability: coverage,
                                lineWidth: document.styles.parallelRouteInnerStrokeWidth(
                                    for: lineGroup.lineID
                                )
                            )
                        )
                    }
                } else {
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
        }

        // State overlays are a separate topmost pass. Authored routes can share
        // physical artwork spans, so a later normal segment must never conceal
        // an affected segment drawn earlier in document order.
        if issuesActive {
            for segment in renderedSegments where presentation.affectedSegmentIDs.contains(segment.id) {
                mapContext.stroke(
                    segment.path,
                    with: .color(presentation.highlightsJourney ? palette.paper : .red.opacity(0.82)),
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
            drawBaseStationMarkers(context: &mapContext)
        }
    }

    /// Returns a line-wide answer when presentation state cannot vary by
    /// segment. `nil` is reserved for the two focused disruption modes that
    /// genuinely need per-segment styling.
    private func uniformMuting(for lineGroup: RenderedLineGroup) -> Bool? {
        if presentation.showsMobileCoverage {
            return nil
        }
        if let selectedLineID = presentation.selectedLineID,
           selectedLineID != lineGroup.lineID {
            return true
        }

        if let filter = presentation.networkFilter {
            switch filter {
            case .lines:
                return false
            case .goodService, .closed:
                return !presentation.networkFeaturedLineIDs.contains(lineGroup.lineID)
            case .minorDelays, .majorIssues, .disrupted:
                guard presentation.networkFeaturedLineIDs.contains(lineGroup.lineID) else {
                    return true
                }
                guard presentation.networkSectionLineIDs.contains(lineGroup.lineID) else {
                    return false
                }
                return nil
            }
        }

        if presentation.closedLineIDs.contains(lineGroup.lineID) {
            return true
        }
        let hasAffectedSegment = lineGroup.segments.contains {
            presentation.affectedSegmentIDs.contains($0.id)
        }
        guard hasAffectedSegment else {
            return presentation.disruptionDisplayMode.mutesSegment(isAffected: false)
        }
        return nil
    }

    private func mobileCoverageRouteColor(
        availability: MobileCoverageAvailability,
        lineID: TubeLineID
    ) -> Color {
        switch availability {
        case .available:
            palette.routeColor(for: lineID, muted: false)
        case .unavailable:
            Color.secondary.opacity(0.34)
        case .unknown:
            Color.orange.opacity(0.68)
        case .outOfScope:
            Color.secondary.opacity(0.13)
        }
    }

    private func mobileCoverageStrokeStyle(
        availability: MobileCoverageAvailability,
        lineWidth: CGFloat
    ) -> StrokeStyle {
        StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: availability == .unknown ? [10, 7] : []
        )
    }

    private func drawTrains(
        context: inout GraphicsContext,
        size: CGSize,
        date: Date,
        cameraScale: CGFloat,
        cameraOffset: CGSize
    ) {
        let visibleBounds = CGRect(origin: .zero, size: size).insetBy(dx: -12, dy: -12)

        for train in liveTrains {
            guard let point = trainScreenPoint(
                for: train,
                at: date,
                cameraScale: cameraScale,
                cameraOffset: cameraOffset
            ) else { continue }
            guard visibleBounds.contains(point) else { continue }
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
                closedLineIDs: appState.currentlyClosedLineIDs
            )
            LiveTrainMarkerRenderer.draw(
                presentation: servicePresentation,
                lineID: train.lineID,
                context: &context,
                in: markerRect
            )
        }
    }

    private func trainScreenPoint(
        for train: LiveTubeTrain,
        at date: Date,
        cameraScale: CGFloat,
        cameraOffset: CGSize
    ) -> CGPoint? {
        guard let artworkPoint = trainArtworkPoint(for: train, at: date) else {
            return nil
        }
        return CGPoint(
            x: artworkPoint.x * cameraScale + cameraOffset.width,
            y: artworkPoint.y * cameraScale + cameraOffset.height
        )
    }

    private func trainScreenPoint(
        for train: LiveTubeTrain,
        at date: Date
    ) -> CGPoint? {
        trainScreenPoint(
            for: train,
            at: date,
            cameraScale: cameraScale,
            cameraOffset: cameraOffset
        )
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

    private func drawBaseStationMarkers(context: inout GraphicsContext) {
        if presentation.showsMobileCoverage {
            for marker in renderedStationMarkers {
                drawCoverageStationMarker(marker, context: &context)
            }
            return
        }

        let batches = renderCache.stationMarkerBatches

        // Most stations share the same handful of styles. Drawing a combined
        // path per style keeps the normal map to a few dozen Canvas operations
        // instead of issuing one or two operations for every authored primitive.
        // Selected and affected stations are redrawn individually below.
        for batch in batches.connectorOutlines {
            context.stroke(
                batch.path,
                with: .color(palette.stationOutline),
                style: StrokeStyle(lineWidth: batch.lineWidth, lineCap: .round)
            )
        }
        for batch in batches.connectorInners {
            context.stroke(
                batch.path,
                with: .color(palette.paper),
                style: StrokeStyle(lineWidth: batch.lineWidth, lineCap: .round)
            )
        }
        for batch in batches.walkingConnectors {
            context.stroke(
                batch.path,
                with: .color(palette.stationOutline),
                style: StrokeStyle(
                    lineWidth: batch.lineWidth,
                    lineCap: .butt,
                    dash: [8, 5]
                )
            )
        }
        context.fill(batches.circles, with: .color(palette.paper))
        for batch in batches.circleOutlines {
            context.stroke(
                batch.path,
                with: .color(palette.stationOutline),
                lineWidth: batch.lineWidth
            )
        }
        for batch in batches.ticks {
            guard let lineID = batch.lineID else { continue }
            context.stroke(
                batch.path,
                with: .color(.tubeLine(lineID)),
                style: StrokeStyle(lineWidth: batch.lineWidth, lineCap: .butt)
            )
        }
    }

    private func drawCoverageStationMarker(
        _ marker: RenderedStationMarker,
        context: inout GraphicsContext
    ) {
        let availability = presentation.mobileCoverageAvailability(
            forStationID: marker.stationID
        )
        let opacity: Double = switch availability {
        case .available: 1
        case .unavailable: 0.34
        case .unknown: 0.68
        case .outOfScope: 0.15
        }
        let outline: Color = switch availability {
        case .available: palette.stationOutline
        case .unavailable, .outOfScope: .secondary
        case .unknown: .orange
        }
        var markerContext = context
        markerContext.opacity = opacity

        for primitive in marker.primitives {
            switch primitive {
            case let .connector(connector, path):
                markerContext.stroke(
                    path,
                    with: .color(outline),
                    style: StrokeStyle(lineWidth: connector.width, lineCap: .round)
                )
                markerContext.stroke(
                    path,
                    with: .color(palette.paper),
                    style: StrokeStyle(lineWidth: max(1, connector.width - 2.2), lineCap: .round)
                )
            case let .walkingConnector(connector, path):
                markerContext.stroke(
                    path,
                    with: .color(outline),
                    style: StrokeStyle(
                        lineWidth: connector.width,
                        lineCap: .butt,
                        dash: [8, 5]
                    )
                )
            case let .circle(circle, path):
                markerContext.fill(path, with: .color(palette.paper))
                markerContext.stroke(
                    path,
                    with: .color(outline),
                    style: StrokeStyle(
                        lineWidth: circle.outlineWidth,
                        dash: availability == .unknown ? [4, 3] : []
                    )
                )
            case let .tick(tick, path):
                markerContext.stroke(
                    path,
                    with: .color(
                        availability == .available ? .tubeLine(tick.lineID) : outline
                    ),
                    style: StrokeStyle(
                        lineWidth: tick.width,
                        lineCap: .butt,
                        dash: availability == .unknown ? [4, 3] : []
                    )
                )
            }
        }
    }

    private func drawEmphasizedStationMarkers(
        context: inout GraphicsContext,
        cameraScale: CGFloat
    ) {
        let issuesActive = presentation.emphasizesIssues && (!presentation.affectedSegmentIDs.isEmpty || presentation.highlightsJourney)

        for marker in renderedStationMarkers {
            let affected = issuesActive && presentation.affectedStationIDs.contains(marker.stationID)
            let selected = presentation.selectedStationID == marker.stationID
            let stationOnly = presentation.showsMobileCoverage
                && presentation.stationOnlyCoverageStationIDs.contains(marker.stationID)
            guard affected || selected || stationOnly else { continue }
            let highlightColor: Color = presentation.highlightsJourney ? .blue : .red
            let outline = affected ? highlightColor : selected ? Color.blue : palette.stationOutline

            if selected || (affected && presentation.highlightsJourney) {
                let haloRadius = (presentation.highlightsJourney ? 7.0 : 19.0) / max(cameraScale, 0.01)
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
                        with: .color(affected ? highlightColor.opacity(0.16) : palette.paper)
                    )
                    context.stroke(
                        path,
                        with: .color(outline),
                        lineWidth: circle.outlineWidth + (selected ? 1.8 : 0)
                    )
                case let .tick(tick, path):
                    context.stroke(
                        path,
                        with: .color(affected ? highlightColor : .tubeLine(tick.lineID)),
                        style: StrokeStyle(lineWidth: tick.width + (selected ? 1.8 : 0), lineCap: .butt)
                    )
                }
            }

            if stationOnly {
                drawStationOnlyCoverageBadge(
                    at: CGPoint(marker.anchor),
                    context: &context,
                    cameraScale: cameraScale
                )
            }
        }
    }

    private func drawStationOnlyCoverageBadge(
        at anchor: CGPoint,
        context: inout GraphicsContext,
        cameraScale: CGFloat
    ) {
        let scale = max(cameraScale, 0.01)
        let radius = 7 / scale
        let centre = CGPoint(
            x: anchor.x + 10 / scale,
            y: anchor.y - 10 / scale
        )
        let badge = Path(ellipseIn: CGRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.fill(badge, with: .color(.green))
        context.stroke(badge, with: .color(.white), lineWidth: 1.5 / scale)

        let barWidth = 1.4 / scale
        let gap = 1.4 / scale
        let baseY = centre.y + 3 / scale
        for index in 0..<3 {
            let height = CGFloat(index + 1) * 2.2 / scale
            let x = centre.x - (barWidth * 1.5 + gap) + CGFloat(index) * (barWidth + gap)
            let bar = Path(roundedRect: CGRect(
                x: x,
                y: baseY - height,
                width: barWidth,
                height: height
            ), cornerRadius: barWidth / 2)
            context.fill(bar, with: .color(.white))
        }
    }

    private func isJourneyLabel(_ label: BeckMapLabelRecord) -> Bool {
        presentation.highlightsJourney && presentation.affectedStationIDs.contains {
            label.represents(stationID: $0)
        }
    }

    private func drawLabels(
        context: inout GraphicsContext,
        viewport: CGSize,
        cameraScale labelCameraScale: CGFloat? = nil,
        cameraOffset labelCameraOffset: CGSize? = nil
    ) {
        let cameraScale = labelCameraScale ?? self.cameraScale
        let cameraOffset = labelCameraOffset ?? self.cameraOffset
        if document.geometryStatus != .authored, cameraScale < max(0.48, minimumCameraScale) {
            return
        }
        let viewportRect = presentation.highlightsJourney
            ? CGRect(origin: .zero, size: viewport).insetBy(
                dx: BeckMapArtworkCachePolicy.overscan + 8,
                dy: BeckMapArtworkCachePolicy.overscan + 8
            )
            : BeckMapArtworkCachePolicy.labelViewport(in: viewport)
        let selectedStationID = presentation.selectedStationID
        let visibleLabels = renderedLabels.filter { renderedLabel in
            let label = renderedLabel.label
            if presentation.highlightsJourney && cameraScale < 0.65 { return isJourneyLabel(label) }
            return label.represents(stationID: selectedStationID)
                || isJourneyLabel(label)
                || BeckMapLabelVisibilityPolicy.shows(
                    label.effectiveVisibilityTier,
                    at: cameraScale
                )
        }
        guard !visibleLabels.isEmpty else { return }
        let markerFrames = markerExclusionFrames(
            cameraScale: cameraScale,
            cameraOffset: cameraOffset
        )
        let markerFramesByStationID = Dictionary(grouping: markerFrames, by: \.stationID)
            .mapValues { blockers in
                blockers.reduce(into: CGRect.null) { bounds, blocker in
                    bounds = bounds.union(blocker.frame)
                }
            }
        let lineBlockers = lineExclusionBlockers(
            in: viewportRect,
            cameraScale: cameraScale,
            cameraOffset: cameraOffset
        )
        var resolvedTextByLabelID: [String: GraphicsContext.ResolvedText] = [:]
        var layoutInputs: [StationLabelLayoutInput] = []

        for renderedLabel in visibleLabels {
            let label = renderedLabel.label
            let selected = label.represents(stationID: selectedStationID) || isJourneyLabel(label)
            let screenAnchor = screenPoint(
                renderedLabel.artworkAnchor,
                cameraScale: cameraScale,
                cameraOffset: cameraOffset
            )
            let tier = label.effectiveVisibilityTier
            let weight: AppFontWeight = selected || tier == .overview ? .semibold : .medium
            let fontSize = BeckMapLabelVisibilityPolicy.fontSize(
                for: tier,
                at: cameraScale
            ) * min(1.6, max(1, labelTypeScale))
            var text = context.resolve(
                Text(label.text).font(
                    AppTypography.fixedBody(size: fontSize, weight: weight)
                )
            )
            text.shading = .color(
                selected ? .white : mobileCoverageLabelColor(for: label.stationID)
            )
            let measuredTextSize = text.measure(in: CGSize(
                width: CGFloat.infinity,
                height: CGFloat.infinity
            ))
            let documentPadding = CGFloat(document.styles.labelPadding)
            let horizontalPadding = selected
                ? max(7, palette.labelHorizontalPadding)
                : palette.labelHorizontalPadding
            let verticalPadding = selected
                ? max(4, palette.labelVerticalPadding)
                : palette.labelVerticalPadding
            let boundsByAlignment = Dictionary(uniqueKeysWithValues:
                [BeckMapLabelAlignment.leading, .centre, .trailing].map { alignment in
                    (alignment, BeckMapLabelBounds.backgroundBounds(
                        textSize: measuredTextSize,
                        alignment: alignment,
                        horizontalPadding: documentPadding + horizontalPadding,
                        verticalPadding: documentPadding + verticalPadding
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
            markerBlockers: presentation.highlightsJourney
                ? markerFrames.filter { presentation.affectedStationIDs.contains($0.stationID) } : markerFrames,
            lineBlockers: presentation.highlightsJourney ? [] : lineBlockers
        )
        let selectedLabelIDs = Set(visibleLabels.compactMap { renderedLabel in
            (renderedLabel.label.represents(stationID: selectedStationID) || isJourneyLabel(renderedLabel.label))
                ? renderedLabel.label.id
                : nil
        })
        for placement in placements {
            guard let text = resolvedTextByLabelID[placement.labelID] else { continue }
            let selected = selectedLabelIDs.contains(placement.labelID)

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
                cornerRadius: selected
                    ? placement.backgroundBounds.height / 2
                    : min(
                        palette.labelCornerRadius,
                        placement.backgroundBounds.height / 2
                    )
            )
            labelContext.fill(
                backgroundPath,
                with: .color(selected ? Color.tubeBlue : palette.labelSurface)
            )
            if selected {
                labelContext.stroke(
                    backgroundPath,
                    with: .color(Color.white.opacity(0.9)),
                    lineWidth: 1.25
                )
            } else if palette.labelBorderWidth > 0 {
                labelContext.stroke(
                    backgroundPath,
                    with: .color(palette.labelBorder),
                    lineWidth: palette.labelBorderWidth
                )
            }
            labelContext.draw(text, at: .zero, anchor: anchor)
        }
    }

    private func mobileCoverageLabelColor(for stationID: String) -> Color {
        guard presentation.showsMobileCoverage else { return palette.ink }
        switch presentation.mobileCoverageAvailability(forStationID: stationID) {
        case .available:
            return palette.ink
        case .unavailable:
            return Color.secondary.opacity(0.48)
        case .unknown:
            return Color.orange.opacity(0.78)
        case .outOfScope:
            return Color.secondary.opacity(0.2)
        }
    }

    private func markerExclusionFrames(
        cameraScale: CGFloat? = nil,
        cameraOffset: CGSize? = nil
    ) -> [BeckMapLabelBlocker] {
        let cameraScale = cameraScale ?? self.cameraScale
        let cameraOffset = cameraOffset ?? self.cameraOffset
        return document.stationMarkers.flatMap { marker in
            marker.primitives.compactMap { primitive -> BeckMapLabelBlocker? in
                switch primitive {
                case let .circle(circle):
                    let centre = screenPoint(
                        circle.centre,
                        cameraScale: cameraScale,
                        cameraOffset: cameraOffset
                    )
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
                    let start = screenPoint(
                        tick.start,
                        cameraScale: cameraScale,
                        cameraOffset: cameraOffset
                    )
                    let end = screenPoint(
                        tick.end,
                        cameraScale: cameraScale,
                        cameraOffset: cameraOffset
                    )
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

    private func lineExclusionBlockers(
        in viewport: CGRect,
        cameraScale: CGFloat? = nil,
        cameraOffset: CGSize? = nil
    ) -> [BeckMapLineBlocker] {
        let cameraScale = cameraScale ?? self.cameraScale
        let cameraOffset = cameraOffset ?? self.cameraOffset
        let issuesActive = presentation.emphasizesIssues
            && !presentation.affectedSegmentIDs.isEmpty
        var blockers = renderedSegments.flatMap { segment in
            let visibleWidth = issuesActive && presentation.affectedSegmentIDs.contains(segment.id)
                ? document.styles.affectedOuterStrokeWidth
                : document.styles.routeStrokeWidth
            let routeClearance = visibleWidth * cameraScale / 2 + 4
            return segment.collisionEdges.compactMap { edge -> BeckMapLineBlocker? in
                let blocker = BeckMapLineBlocker(
                    start: screenPoint(
                        edge.start,
                        cameraScale: cameraScale,
                        cameraOffset: cameraOffset
                    ),
                    end: screenPoint(
                        edge.end,
                        cameraScale: cameraScale,
                        cameraOffset: cameraOffset
                    ),
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
                    start: screenPoint(
                        start,
                        cameraScale: cameraScale,
                        cameraOffset: cameraOffset
                    ),
                    end: screenPoint(
                        end,
                        cameraScale: cameraScale,
                        cameraOffset: cameraOffset
                    ),
                    clearance: width * cameraScale / 2 + 4
                )
                if blocker.bounds.intersects(viewport) {
                    blockers.append(blocker)
                }
            }
        }
        return blockers
    }

    private func resetCamera(in size: CGSize, animated: Bool = false) {
        cancelCameraAnimation()
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
        let offset = CGSize(
            width: size.width / 2 - fittingBounds.midX * fittedScale,
            height: size.height / 2 - fittingBounds.midY * fittedScale - contentVerticalBias
        )
        if animated {
            animateCamera(toScale: fittedScale, offset: offset, viewportSize: size, duration: 0.5)
        } else {
            camera.update(scale: fittedScale, offset: offset)
            refreshRenderedCamera()
            updateCameraSnapshot(in: size)
        }
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
        cancelCameraAnimation()

        if reduceMotion {
            camera.update(scale: targetScale, offset: targetOffset)
            refreshRenderedCamera()
            publishViewport(in: viewportSize)
            return
        }

        let startScale = cameraScale
        let startOffset = cameraOffset
        isAnimatingCamera = true
        cameraAnimator.animate(
            duration: duration,
            easing: { easing.value(at: $0) },
            update: { progress in
                camera.update(
                    scale: startScale + (targetScale - startScale) * CGFloat(progress),
                    offset: CGSize(
                        width: startOffset.width
                            + (targetOffset.width - startOffset.width) * CGFloat(progress),
                        height: startOffset.height
                            + (targetOffset.height - startOffset.height) * CGFloat(progress)
                    )
                )
                rebaseArtworkIfNeeded(in: viewportSize)
            },
            completion: {
                isAnimatingCamera = false
                refreshRenderedCamera()
                publishViewport(in: viewportSize)
            }
        )
    }

    private func cancelCameraAnimation() {
        cameraAnimator.cancel()
        if isAnimatingCamera { isAnimatingCamera = false }
    }

    private func refreshRenderedCamera() {
        renderScale = cameraScale
        renderOffset = cameraOffset
    }

    private func rebaseArtworkIfNeeded(in size: CGSize) {
        if BeckMapArtworkCachePolicy.shouldRebase(
            cameraScale: cameraScale, cameraOffset: cameraOffset,
            renderScale: renderScale, renderOffset: renderOffset,
            viewportSize: size
        ) {
            refreshRenderedCamera()
        }
    }

    private func handlePan(
        translation: CGSize,
        phase: BeckMapGesturePhase,
        in size: CGSize
    ) {
        switch phase {
        case .began:
            cancelCameraAnimation()
            isPanning = true
            isDecelerating = false
            panStartOffset = cameraOffset
        case .changed:
            guard !isPinching else { return }
            let start = panStartOffset ?? cameraOffset
            camera.update(scale: cameraScale, offset: CGSize(
                width: start.width + translation.width,
                height: start.height + translation.height
            ))
            rebaseArtworkIfNeeded(in: size)
            // Panning changes only the offset. The outer map chrome depends on
            // zoom, so publishing this through shared app state every frame
            // needlessly invalidates the whole map screen.
        case .decelerating:
            if !isDecelerating {
                isPanning = false
                isDecelerating = true
            }
            camera.update(scale: cameraScale, offset: CGSize(
                width: cameraOffset.width + translation.width,
                height: cameraOffset.height + translation.height
            ))
            rebaseArtworkIfNeeded(in: size)
        case .interrupted:
            isPanning = false
            isDecelerating = false
            panStartOffset = nil
        case .ended:
            isPanning = false
            isDecelerating = false
            panStartOffset = nil
            // Offset-only motion keeps the existing labels and pixels. Reusing
            // the buffer also avoids a final label shuffle when momentum stops.
            // A touch may also have caught a zoom animation between rebases.
            if renderScale != cameraScale { refreshRenderedCamera() }
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
            cancelCameraAnimation()
            isPanning = false
            isDecelerating = false
            panStartOffset = nil
            isPinching = true
            pinchStartScale = cameraScale
            pinchMapPoint = CGPoint(
                x: (location.x - cameraOffset.width) / cameraScale,
                y: (location.y - cameraOffset.height) / cameraScale
            )
        case .changed:
            guard let startScale = pinchStartScale, let mapPoint = pinchMapPoint else { return }
            let nextScale = min(maximumCameraScale, max(minimumCameraScale, startScale * magnification))
            if nextScale > cameraScale,
               !BeckMapOverviewVisibilityPolicy.shouldHideClosestStation(
                   at: cameraScale,
                   fittedScale: fittedCameraScale
               ),
               BeckMapOverviewVisibilityPolicy.shouldHideClosestStation(
                   at: nextScale,
                   fittedScale: fittedCameraScale
               ) {
                onUserZoomIn()
            }
            camera.update(scale: nextScale, offset: CGSize(
                width: location.x - mapPoint.x * nextScale,
                height: location.y - mapPoint.y * nextScale
            ))
            rebaseArtworkIfNeeded(in: size)
        case .interrupted:
            isPinching = false
            pinchStartScale = nil
            pinchMapPoint = nil
        case .decelerating:
            break
        case .ended:
            isPinching = false
            pinchStartScale = nil
            pinchMapPoint = nil
            panStartOffset = nil
            refreshRenderedCamera()
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
        cancelCameraAnimation()
        let scaleToFit = min(
            size.width / max(1, artworkRect.width),
            size.height / max(1, artworkRect.height)
        )
        let nextScale = min(
            maximumCameraScale,
            max(minimumCameraScale, scaleToFit)
        )
        camera.update(scale: nextScale, offset: CGSize(
            width: size.width / 2 - centre.x * nextScale,
            height: size.height / 2 - centre.y * nextScale
        ))
        refreshRenderedCamera()
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

    private func selectMapFeature(at location: CGPoint, viewport: CGSize) {
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

        if let selection = BeckMapStationTapResolver.resolve(
            screenPoint: location,
            cameraScale: cameraScale,
            cameraOffset: cameraOffset,
            document: document,
            renderedSegments: renderedSegments,
            graph: appState.graph
        ) {
            onStationTap(
                selection.stationID,
                selection.preferredLineID
            )
        } else if let labelID = stationLabelID(at: location, in: viewport),
                  let stationID = renderedLabels.first(where: {
            $0.label.id == labelID
        })?.label.stationID {
            onStationTap(stationID, nil)
        } else if let disruptionID = disruptionID(at: location) {
            onDisruptionTap(disruptionID)
        } else {
            onBackgroundTap()
        }
    }

    private func stationLabelID(at location: CGPoint, in viewport: CGSize) -> String? {
        let overscan = BeckMapArtworkCachePolicy.overscan
        let transform = BeckMapLayerTransform.transform(
            cameraScale: cameraScale, cameraOffset: cameraOffset,
            renderScale: renderScale, renderOffset: renderOffset,
            overscan: overscan
        )
        // Hit-test the same buffered label layout that is actually on screen,
        // including when a tap interrupts momentum between cache rebases.
        return StationLabelHitTester.labelID(
            at: location.applying(transform.inverted()),
            placements: stationLabelPlacements(
                in: CGSize(width: viewport.width + overscan * 2, height: viewport.height + overscan * 2),
                cameraScale: renderScale,
                cameraOffset: CGSize(width: renderOffset.width + overscan, height: renderOffset.height + overscan)
            ),
            minimumHitSize: 44 / max(0.000_001, cameraScale / renderScale)
        )
    }

    private func stationLabelPlacements(
        in viewport: CGSize,
        cameraScale: CGFloat,
        cameraOffset: CGSize
    ) -> [StationLabelPlacement] {
        if document.geometryStatus != .authored,
           cameraScale < max(0.48, minimumCameraScale) {
            return []
        }

        let selectedStationID = presentation.selectedStationID
        let visibleLabels = renderedLabels.filter { renderedLabel in
            let label = renderedLabel.label
            if presentation.highlightsJourney && cameraScale < 0.65 { return isJourneyLabel(label) }
            return label.represents(stationID: selectedStationID)
                || isJourneyLabel(label)
                || BeckMapLabelVisibilityPolicy.shows(
                    label.effectiveVisibilityTier,
                    at: cameraScale
                )
        }
        guard !visibleLabels.isEmpty else { return [] }

        let viewportRect = presentation.highlightsJourney
            ? CGRect(origin: .zero, size: viewport).insetBy(
                dx: BeckMapArtworkCachePolicy.overscan + 8,
                dy: BeckMapArtworkCachePolicy.overscan + 8
            )
            : BeckMapArtworkCachePolicy.labelViewport(in: viewport)
        let markerFrames = markerExclusionFrames(cameraScale: cameraScale, cameraOffset: cameraOffset)
        let markerFramesByStationID = Dictionary(grouping: markerFrames, by: \.stationID)
            .mapValues { blockers in
                blockers.reduce(into: CGRect.null) { bounds, blocker in
                    bounds = bounds.union(blocker.frame)
                }
            }
        let documentPadding = CGFloat(document.styles.labelPadding)
        let layoutInputs = visibleLabels.map { renderedLabel in
            let label = renderedLabel.label
            let selected = label.represents(stationID: selectedStationID) || isJourneyLabel(label)
            let tier = label.effectiveVisibilityTier
            let weight: AppFontWeight = selected || tier == .overview ? .semibold : .medium
            let fontSize = BeckMapLabelVisibilityPolicy.fontSize(
                for: tier,
                at: cameraScale
            ) * min(1.6, max(1, labelTypeScale))
            let measuredTextSize = BeckMapLabelTextMeasurer.size(
                for: label.text,
                font: AppTypography.fixedBodyUIFont(size: fontSize, weight: weight)
            )
            let horizontalPadding = selected
                ? max(7, palette.labelHorizontalPadding)
                : palette.labelHorizontalPadding
            let verticalPadding = selected
                ? max(4, palette.labelVerticalPadding)
                : palette.labelVerticalPadding
            let boundsByAlignment = Dictionary(uniqueKeysWithValues:
                [BeckMapLabelAlignment.leading, .centre, .trailing].map { alignment in
                    (alignment, BeckMapLabelBounds.backgroundBounds(
                        textSize: measuredTextSize,
                        alignment: alignment,
                        horizontalPadding: documentPadding + horizontalPadding,
                        verticalPadding: documentPadding + verticalPadding
                    ))
                }
            )
            let representedStationIDs = [label.stationID] + (label.associatedStationIDs ?? [])
            let targetMarkerFrame = representedStationIDs.compactMap {
                markerFramesByStationID[$0]
            }.reduce(into: CGRect.null) { frame, markerFrame in
                frame = frame.union(markerFrame)
            }
            let screenAnchor = screenPoint(
                renderedLabel.artworkAnchor,
                cameraScale: cameraScale,
                cameraOffset: cameraOffset
            )
            return StationLabelLayoutInput(
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
            )
        }

        return StationLabelLayoutEngine.layout(
            inputs: layoutInputs,
            viewport: viewportRect,
            markerBlockers: presentation.highlightsJourney
                ? markerFrames.filter { presentation.affectedStationIDs.contains($0.stationID) } : markerFrames,
            lineBlockers: presentation.highlightsJourney ? [] : lineExclusionBlockers(
                in: viewportRect, cameraScale: cameraScale, cameraOffset: cameraOffset
            )
        )
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
        screenPoint(
            point,
            cameraScale: cameraScale,
            cameraOffset: cameraOffset
        )
    }

    private func screenPoint(
        _ point: BeckMapPoint,
        cameraScale: CGFloat,
        cameraOffset: CGSize
    ) -> CGPoint {
        CGPoint(
            x: point.x * cameraScale + cameraOffset.width,
            y: point.y * cameraScale + cameraOffset.height
        )
    }

    private func screenPoint(_ point: CGPoint) -> CGPoint {
        screenPoint(
            point,
            cameraScale: cameraScale,
            cameraOffset: cameraOffset
        )
    }

    private func screenPoint(
        _ point: CGPoint,
        cameraScale: CGFloat,
        cameraOffset: CGSize
    ) -> CGPoint {
        CGPoint(
            x: point.x * cameraScale + cameraOffset.width,
            y: point.y * cameraScale + cameraOffset.height
        )
    }

    private func distance(_ start: CGPoint, _ end: CGPoint) -> CGFloat {
        hypot(start.x - end.x, start.y - end.y)
    }

    nonisolated private static func makeLinePath(
        from start: BeckMapPoint,
        to end: BeckMapPoint
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(start))
        path.addLine(to: CGPoint(end))
        return path
    }

    nonisolated private static func makePath(
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

    nonisolated private static func makeCollisionEdges(
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

    nonisolated private static func loadDebugReference(for document: BeckMapDocument) -> UIImage? {
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

    nonisolated private static func makeArtworkBounds(
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

    nonisolated private static func labelMetrics(
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

    struct RenderCache: Sendable {
        let renderedSegments: [RenderedSegment]
        let renderedLineGroups: [RenderedLineGroup]
        let renderedWaterways: [RenderedWaterway]
        let renderedStationMarkers: [RenderedStationMarker]
        let stationMarkerBatches: RenderedStationMarkerBatches
        let trainPathsBySegmentID: [String: BeckMapTrainPath]
        let renderedLabels: [RenderedLabel]
        let artworkBounds: CGRect
        let debugReferenceImage: UIImage?

        nonisolated init(document: BeckMapDocument, loadsDebugReference: Bool = false) {
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
                    fromStationID: segment.fromStationID,
                    toStationID: segment.toStationID,
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

            let renderedStationMarkers = document.stationMarkers.map { marker in
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
            self.renderedStationMarkers = renderedStationMarkers
            self.stationMarkerBatches = RenderedStationMarkerBatches(
                markers: renderedStationMarkers
            )

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
        let fromStationID: String
        let toStationID: String
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

    struct RenderedMarkerStrokeBatch {
        let path: Path
        let lineWidth: CGFloat
        let lineID: TubeLineID?
    }

    struct RenderedStationMarkerBatches {
        let connectorOutlines: [RenderedMarkerStrokeBatch]
        let connectorInners: [RenderedMarkerStrokeBatch]
        let walkingConnectors: [RenderedMarkerStrokeBatch]
        let circles: Path
        let circleOutlines: [RenderedMarkerStrokeBatch]
        let ticks: [RenderedMarkerStrokeBatch]

        var normalDrawOperationCount: Int {
            connectorOutlines.count
                + connectorInners.count
                + walkingConnectors.count
                + (circles.isEmpty ? 0 : 1)
                + circleOutlines.count
                + ticks.count
        }

        init(markers: [RenderedStationMarker]) {
            struct TickStyle: Hashable {
                let lineID: TubeLineID
                let width: Double
            }

            var connectorOutlinePaths: [Double: Path] = [:]
            var connectorInnerPaths: [Double: Path] = [:]
            var walkingConnectorPaths: [Double: Path] = [:]
            var circlePath = Path()
            var circleOutlinePaths: [Double: Path] = [:]
            var tickPaths: [TickStyle: Path] = [:]

            for marker in markers {
                for primitive in marker.primitives {
                    switch primitive {
                    case let .connector(connector, path):
                        connectorOutlinePaths[connector.width + 1.8, default: Path()]
                            .addPath(path)
                        connectorInnerPaths[connector.width - 2.2, default: Path()]
                            .addPath(path)
                    case let .walkingConnector(connector, path):
                        walkingConnectorPaths[connector.width, default: Path()]
                            .addPath(path)
                    case let .circle(circle, path):
                        circlePath.addPath(path)
                        circleOutlinePaths[circle.outlineWidth, default: Path()]
                            .addPath(path)
                    case let .tick(tick, path):
                        tickPaths[TickStyle(lineID: tick.lineID, width: tick.width), default: Path()]
                            .addPath(path)
                    }
                }
            }

            connectorOutlines = Self.strokeBatches(connectorOutlinePaths)
            connectorInners = Self.strokeBatches(connectorInnerPaths)
            walkingConnectors = Self.strokeBatches(walkingConnectorPaths)
            circles = circlePath
            circleOutlines = Self.strokeBatches(circleOutlinePaths)
            ticks = tickPaths.keys.sorted {
                if $0.lineID.rawValue != $1.lineID.rawValue {
                    return $0.lineID.rawValue < $1.lineID.rawValue
                }
                return $0.width < $1.width
            }.compactMap { style in
                guard let path = tickPaths[style] else { return nil }
                return RenderedMarkerStrokeBatch(
                    path: path,
                    lineWidth: style.width,
                    lineID: style.lineID
                )
            }
        }

        private static func strokeBatches(
            _ pathsByWidth: [Double: Path]
        ) -> [RenderedMarkerStrokeBatch] {
            pathsByWidth.keys.sorted().compactMap { width in
                guard let path = pathsByWidth[width] else { return nil }
                return RenderedMarkerStrokeBatch(
                    path: path,
                    lineWidth: width,
                    lineID: nil
                )
            }
        }
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

struct BeckMapStationTapSelection: Equatable {
    let stationID: String
    let preferredLineID: TubeLineID?
}

enum BeckMapStationTapResolver {
    static func resolve(
        screenPoint: CGPoint,
        cameraScale: CGFloat,
        cameraOffset: CGSize,
        document: BeckMapDocument,
        renderedSegments: [BeckMapCanvas.RenderedSegment],
        graph: TubeGraph?,
        minimumScreenHitRadius: CGFloat = 24
    ) -> BeckMapStationTapSelection? {
        guard cameraScale.isFinite,
              cameraScale > 0,
              cameraOffset.width.isFinite,
              cameraOffset.height.isFinite,
              screenPoint.x.isFinite,
              screenPoint.y.isFinite,
              minimumScreenHitRadius.isFinite,
              minimumScreenHitRadius >= 0 else {
            return nil
        }

        let artworkPoint = CGPoint(
            x: (screenPoint.x - cameraOffset.width) / cameraScale,
            y: (screenPoint.y - cameraOffset.height) / cameraScale
        )
        guard let marker = BeckMapStationMarkerHitTester.nearestMarker(
            to: artworkPoint,
            among: document.stationMarkers,
            minimumHitRadius: minimumScreenHitRadius / cameraScale
        ) else {
            return nil
        }

        let colocatedStationIDs: Set<String>
        if let graph,
           let station = graph.stationsByID[marker.stationID] {
            colocatedStationIDs = Set(graph.stations(inSamePlaceAs: station).map(\.id))
        } else {
            colocatedStationIDs = [marker.stationID]
        }
        return BeckMapStationTapSelection(
            stationID: marker.stationID,
            preferredLineID: BeckMapStationLineResolver.preferredLineID(
                for: marker,
                tappedAt: artworkPoint,
                colocatedStationIDs: colocatedStationIDs,
                segments: renderedSegments
            )
        )
    }
}

enum BeckMapStationMarkerHitTester {
    static func nearestMarker(
        to point: CGPoint,
        among markers: [BeckMapStationMarkerRecord],
        minimumHitRadius: CGFloat
    ) -> BeckMapStationMarkerRecord? {
        guard minimumHitRadius >= 0, minimumHitRadius.isFinite else { return nil }

        return markers.compactMap { marker -> Candidate? in
            let circleCentres = marker.primitives.compactMap { primitive -> CGPoint? in
                guard case let .circle(circle) = primitive else { return nil }
                return CGPoint(circle.centre)
            }
            let hitPoints = circleCentres.isEmpty
                ? [CGPoint(marker.anchor)]
                : circleCentres
            guard let distance = hitPoints.map({ hypot($0.x - point.x, $0.y - point.y) }).min(),
                  distance <= max(minimumHitRadius, marker.hitRadius) else {
                return nil
            }
            let anchor = CGPoint(marker.anchor)
            return Candidate(
                marker: marker,
                distance: distance,
                anchorDistance: hypot(anchor.x - point.x, anchor.y - point.y)
            )
        }
        .min { left, right in
            if left.distance != right.distance {
                return left.distance < right.distance
            }
            if left.anchorDistance != right.anchorDistance {
                return left.anchorDistance < right.anchorDistance
            }
            return left.marker.stationID < right.marker.stationID
        }?
        .marker
    }

    private struct Candidate {
        let marker: BeckMapStationMarkerRecord
        let distance: CGFloat
        let anchorDistance: CGFloat
    }
}

enum BeckMapStationLineResolver {
    static func preferredLineID(
        for marker: BeckMapStationMarkerRecord,
        tappedAt point: CGPoint,
        colocatedStationIDs: Set<String>,
        segments: [BeckMapCanvas.RenderedSegment]
    ) -> TubeLineID? {
        guard marker.lineIDs.count > 1 else { return marker.lineIDs.first }
        let markerLineIDs = Set(marker.lineIDs)
        let circleCentres = marker.primitives.compactMap { primitive -> CGPoint? in
            guard case let .circle(circle) = primitive else { return nil }
            return CGPoint(circle.centre)
        }
        let roundelPoint = circleCentres.min {
            squaredDistance(from: point, to: $0) < squaredDistance(from: point, to: $1)
        } ?? point
        // Interchange artwork can move a visible roundel away from the route's
        // authored station port, so compare with the complete rendered path.
        let connectedSegments = segments.filter { segment in
            markerLineIDs.contains(segment.lineID)
                && (colocatedStationIDs.contains(segment.fromStationID)
                    || colocatedStationIDs.contains(segment.toStationID))
        }

        var nearestLineID: TubeLineID?
        var nearestSquaredDistance = CGFloat.greatestFiniteMagnitude
        for lineID in marker.lineIDs {
            for segment in connectedSegments where segment.lineID == lineID {
                for edge in segment.collisionEdges {
                    let candidateDistance = squaredDistance(from: roundelPoint, to: edge)
                    if candidateDistance < nearestSquaredDistance {
                        nearestLineID = lineID
                        nearestSquaredDistance = candidateDistance
                    }
                }
            }
        }
        return nearestLineID ?? marker.lineIDs.first
    }

    private static func squaredDistance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        let deltaX = start.x - end.x
        let deltaY = start.y - end.y
        return deltaX * deltaX + deltaY * deltaY
    }

    private static func squaredDistance(
        from point: CGPoint,
        to edge: BeckMapCollisionEdge
    ) -> CGFloat {
        let deltaX = edge.end.x - edge.start.x
        let deltaY = edge.end.y - edge.start.y
        let squaredLength = deltaX * deltaX + deltaY * deltaY
        guard squaredLength > 0.000_001 else {
            return squaredDistance(from: point, to: edge.start)
        }
        let progress = min(
            1,
            max(
                0,
                ((point.x - edge.start.x) * deltaX + (point.y - edge.start.y) * deltaY)
                    / squaredLength
            )
        )
        return squaredDistance(
            from: point,
            to: CGPoint(
                x: edge.start.x + deltaX * progress,
                y: edge.start.y + deltaY * progress
            )
        )
    }
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

enum BeckMapLabelTextMeasurer {
    static func size(for text: String, font: UIFont) -> CGSize {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }
}

enum StationLabelHitTester {
    static func labelID(
        at point: CGPoint,
        placements: [StationLabelPlacement],
        minimumHitSize: CGFloat
    ) -> String? {
        placements
            .compactMap { placement -> (id: String, distance: CGFloat)? in
                let localPoint = CGPoint(
                    x: point.x - placement.position.x,
                    y: point.y - placement.position.y
                ).applying(placement.rotation.inverted())
                let horizontalExpansion = max(
                    0,
                    (minimumHitSize - placement.backgroundBounds.width) / 2
                )
                let verticalExpansion = max(
                    0,
                    (minimumHitSize - placement.backgroundBounds.height) / 2
                )
                let hitBounds = placement.backgroundBounds.insetBy(
                    dx: -horizontalExpansion,
                    dy: -verticalExpansion
                )
                guard hitBounds.contains(localPoint) else { return nil }
                return (
                    placement.labelID,
                    hypot(
                        localPoint.x - placement.backgroundBounds.midX,
                        localPoint.y - placement.backgroundBounds.midY
                    )
                )
            }
            .min(by: { $0.distance < $1.distance })?
            .id
    }
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
            var bestPlacement: StationLabelPlacement?

            // Options and their candidates are already ordered by preference:
            // each option used to add 18 to the score and has 15 candidates.
            // The first valid candidate is therefore the same winning placement
            // as an exhaustive search, without checking every remaining option.
            placementSearch: for option in options {
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
                for candidate in candidates {
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

                    bestPlacement = StationLabelPlacement(
                        labelID: input.id,
                        position: candidate.position,
                        alignment: candidate.alignment,
                        rotation: input.rotation,
                        backgroundBounds: backgroundBounds,
                        collisionFrame: collisionFrame
                    )
                    break placementSearch
                }
            }

            guard let placement = bestPlacement else { continue }
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

enum BeckMapArtworkCachePolicy {
    /// Extra rendered content around the viewport prevents exposed edges while
    /// Core Animation translates or scales the cached Canvas during interaction.
    static let overscan: CGFloat = 240

    static func labelViewport(in canvasSize: CGSize) -> CGRect {
        CGRect(origin: .zero, size: canvasSize).insetBy(dx: 8, dy: 8)
    }

    static func shouldRebase(
        cameraScale: CGFloat,
        cameraOffset: CGSize,
        renderScale: CGFloat,
        renderOffset: CGSize,
        viewportSize: CGSize
    ) -> Bool {
        let transform = BeckMapLayerTransform.transform(
            cameraScale: cameraScale, cameraOffset: cameraOffset,
            renderScale: renderScale, renderOffset: renderOffset, overscan: overscan
        )
        let coverage = CGRect(
            x: 0, y: 0,
            width: viewportSize.width + overscan * 2,
            height: viewportSize.height + overscan * 2
        ).applying(transform)
        // Account for both zoom and focal-point translation, including a pinch
        // near an edge. Leave time for the next buffer to render before exposure.
        let requiredCoverage = CGRect(origin: .zero, size: viewportSize).insetBy(dx: -48, dy: -48)
        return !coverage.contains(requiredCoverage) || cameraScale / max(0.000_001, renderScale) >= 1.75
    }

}

enum BeckMapMomentumPolicy {
    static let minimumVelocity: CGFloat = 110
    static let maximumProjectedDistance: CGFloat = 480
    static let stoppingVelocity: CGFloat = 14
    static let maximumDuration: TimeInterval = 2.2

    private static let decelerationRate = UIScrollView.DecelerationRate.normal.rawValue

    static func initialVelocity(from gestureVelocity: CGPoint) -> CGPoint? {
        var velocity = gestureVelocity
        let speed = hypot(velocity.x, velocity.y)
        guard speed >= minimumVelocity else { return nil }

        let projectedDistance = projectedDistance(for: velocity)
        if projectedDistance > maximumProjectedDistance {
            let scale = maximumProjectedDistance / projectedDistance
            velocity.x *= scale
            velocity.y *= scale
        }
        return velocity
    }

    static func projectedDistance(for velocity: CGPoint) -> CGFloat {
        let decayPerSecond = -1_000 * log(decelerationRate)
        return hypot(velocity.x, velocity.y) / max(0.001, decayPerSecond)
    }

    static func attenuatedVelocity(
        _ velocity: CGPoint,
        over frameDuration: TimeInterval
    ) -> CGPoint {
        let attenuation = pow(decelerationRate, frameDuration * 1_000)
        return CGPoint(
            x: velocity.x * attenuation,
            y: velocity.y * attenuation
        )
    }

    static func translation(
        from velocity: CGPoint,
        to nextVelocity: CGPoint,
        over frameDuration: TimeInterval
    ) -> CGSize {
        CGSize(
            width: (velocity.x + nextVelocity.x) * 0.5 * frameDuration,
            height: (velocity.y + nextVelocity.y) * 0.5 * frameDuration
        )
    }

    static func shouldStop(velocity: CGPoint, elapsed: TimeInterval) -> Bool {
        hypot(velocity.x, velocity.y) < stoppingVelocity || elapsed >= maximumDuration
    }
}

private struct BeckMapArtworkCacheKey: Equatable {
    let documentID: String
    let graphGeneratedAt: String
    let presentation: BeckMapPresentationSnapshot
    let colorScheme: ColorScheme
    let referenceOverlayVisible: Bool
    let cameraScale: CGFloat
    let cameraOffset: CGSize
    let canvasSize: CGSize
}

private struct BeckMapLabelCacheKey: Equatable {
    let documentID: String
    let graphGeneratedAt: String
    let presentation: BeckMapPresentationSnapshot
    let colorScheme: ColorScheme
    let cameraScale: CGFloat
    let cameraOffset: CGSize
    let canvasSize: CGSize
    let labelTypeScale: CGFloat
}

private struct BeckMapTrainCacheKey: Equatable {
    let trains: [LiveTubeTrain]
    let selectedTrainID: String?
    let closedLineIDs: Set<TubeLineID>
    let renderSecond: Int
    let cameraScale: CGFloat
    let cameraOffset: CGSize
    let canvasSize: CGSize
    let colorScheme: ColorScheme
}
