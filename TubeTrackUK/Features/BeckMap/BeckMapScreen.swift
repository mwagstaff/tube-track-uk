import SwiftUI
import UIKit

struct BeckMapPresentationSnapshot: Equatable, Sendable {
    let selectedLineID: TubeLineID?
    let selectedStationID: String?
    let affectedSegmentIDs: Set<String>
    let affectedStationIDs: Set<String>
    let emphasizesIssues: Bool
}

struct BeckMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    @AppStorage("statusPanelExpanded") private var statusExpanded = false
    @State private var document: BeckMapDocument?
    @State private var renderCache: BeckMapCanvas.RenderCache?
    @State private var documentLoadError: String?
    @State private var loadedGraphGeneratedAt: String?
    @State private var isLoadingDocument = false
    @State private var resetToken = 0
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
                    referenceOverlayVisible: referenceOverlayVisible,
                    resetToken: resetToken,
                    onStationTap: { stationID in
                        guard let station = graph.stationsByID[stationID] else { return }
                        withAnimation(.smooth(duration: 0.35)) {
                            appState.select(station: station)
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
        .overlay(alignment: .top) {
            VStack(spacing: 7) {
                MapToolbar { resetToken += 1 }
                    .tint(.tubeBlue)

                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(BeckMapRegion.allCases) { region in
                            Button {
                                selectedRegion = region
                            } label: {
                                Text(region.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(region == selectedRegion ? Color.white : Color.tubeBlue)
                                    .background(
                                        region == selectedRegion ? Color.tubeBlue : Color.white,
                                        in: .capsule
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(Color.tubeBlue.opacity(region == selectedRegion ? 0 : 0.28))
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(region == selectedRegion ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Authored map region")

                HStack {
                    #if DEBUG
                    Button {
                        withAnimation(.smooth(duration: 0.3)) {
                            showsReferenceOverlay.toggle()
                        }
                    } label: {
                        Label(
                            showsReferenceOverlay ? "Hide trace" : "Trace",
                            systemImage: "square.2.layers.3d"
                        )
                        .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.tubeBlue)
                    .accessibilityHint("Overlays the official reference crop for geometry comparison")
                    #endif

                    Spacer()
                    Label(regionStatusTitle, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption2.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: .capsule)
                        .accessibilityLabel(selectedRegion.accessibilityDescription)
                }
                .padding(.horizontal, 12)
            }
        }
        .overlay(alignment: .bottom) {
            bottomOverlay
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
                renderCache = BeckMapCanvas.RenderCache(document: loadedDocument)
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

    private var regionStatusTitle: String {
        selectedRegion == .fullUnderground
            ? "Full London rail map"
            : "\(selectedRegion.title) · authored slice"
    }

    private func presentation(
        document: BeckMapDocument,
        graph: TubeGraph
    ) -> BeckMapPresentationSnapshot {
        let projector = BeckMapAffectedSegmentProjector(document: document, graph: graph)
        let affectedSegmentIDs: Set<String>

        if appState.hasFocusedMapSection {
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
            affectedSegmentIDs = Set(appState.disruptions.flatMap {
                projector.projectedSegmentIDs(for: $0)
            })
        }

        return BeckMapPresentationSnapshot(
            selectedLineID: appState.selectedLineID,
            selectedStationID: appState.selectedStationID,
            affectedSegmentIDs: affectedSegmentIDs,
            affectedStationIDs: appState.activeAffectedStationIDs,
            emphasizesIssues: appState.disruptionDisplayMode == .issues
        )
    }

    private var bottomOverlay: some View {
        VStack(spacing: 9) {
            if appState.showLiveTrains {
                TrainFilterBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let station = appState.selectedStation {
                StationDetailCard(station: station)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let lineID = appState.selectedLineID, appState.selectedDisruptionID == nil {
                LineDetailCard(lineID: lineID)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if statusExpanded {
                LiveStatusPanel(expanded: $statusExpanded)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                LiveStatusDock(expanded: $statusExpanded)
                    .padding(.horizontal, 12)
            }
        }
        .animation(.smooth(duration: 0.35), value: appState.showLiveTrains)
        .animation(.smooth(duration: 0.35), value: appState.selectedStationID)
        .safeAreaPadding(.bottom, 4)
    }
}

private struct BeckMapCanvas: View {
    let document: BeckMapDocument
    let renderCache: RenderCache
    let presentation: BeckMapPresentationSnapshot
    let referenceOverlayVisible: Bool
    let resetToken: Int
    let onStationTap: (String) -> Void
    let onBackgroundTap: () -> Void

    private var renderedSegments: [RenderedSegment] { renderCache.renderedSegments }
    private var renderedLineGroups: [RenderedLineGroup] { renderCache.renderedLineGroups }
    private var renderedLabels: [RenderedLabel] { renderCache.renderedLabels }
    private var artworkBounds: CGRect { renderCache.artworkBounds }
    private var debugReferenceImage: UIImage? { renderCache.debugReferenceImage }

    @State private var cameraScale: CGFloat = 0.35
    @State private var cameraOffset = CGSize.zero
    @State private var minimumCameraScale: CGFloat = 0.2
    @State private var maximumCameraScale: CGFloat = 3.8
    @State private var panStartOffset: CGSize?
    @State private var pinchStartScale: CGFloat?
    @State private var pinchMapPoint: CGPoint?
    @State private var isPanning = false
    @State private var isPinching = false

    init(
        document: BeckMapDocument,
        renderCache: RenderCache,
        presentation: BeckMapPresentationSnapshot,
        referenceOverlayVisible: Bool,
        resetToken: Int,
        onStationTap: @escaping (String) -> Void,
        onBackgroundTap: @escaping () -> Void
    ) {
        self.document = document
        self.renderCache = renderCache
        self.presentation = presentation
        self.referenceOverlayVisible = referenceOverlayVisible
        self.resetToken = resetToken
        self.onStationTap = onStationTap
        self.onBackgroundTap = onBackgroundTap
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                    drawArtwork(context: &context, size: size)
                }
                .allowsHitTesting(false)

                BeckMapGestureSurface(
                    onPan: handlePan,
                    onPinch: handlePinch,
                    onTap: selectStation(at:)
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
                if presentation.emphasizesIssues {
                    focus(on: presentation.affectedStationIDs, in: proxy.size)
                }
            }
            .onChange(of: resetToken) { _, _ in
                withAnimation(.smooth(duration: 0.5)) {
                    resetCamera(in: proxy.size)
                }
            }
            .onChange(of: presentation.affectedStationIDs) { _, stationIDs in
                if presentation.emphasizesIssues {
                    focus(on: stationIDs, in: proxy.size)
                }
            }
            .onChange(of: presentation.emphasizesIssues) { _, emphasizesIssues in
                if emphasizesIssues {
                    focus(on: presentation.affectedStationIDs, in: proxy.size)
                }
            }
        }
    }

    private var stationAccessibilityRepresentation: some View {
        ScrollView {
            LazyVStack {
                ForEach(document.stationMarkers) { marker in
                    Button("\(marker.name), \(marker.lineIDs.map(\.displayName).joined(separator: ", "))") {
                        onStationTap(marker.stationID)
                    }
                }
            }
        }
        .accessibilityLabel("Interactive London rail map")
    }

    private var isReferenceOverlayActive: Bool {
        referenceOverlayVisible && debugReferenceImage != nil
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

        let issuesActive = !traceMode
            && presentation.emphasizesIssues
            && !presentation.affectedSegmentIDs.isEmpty
        // Preserve the document's line-layer order, but render each parallel
        // rail line in two passes. Drawing every coloured outer before any
        // white inset keeps branch joins open instead of allowing a later
        // segment's outer stroke to plug an earlier segment's white centre.
        for lineGroup in renderedLineGroups {
            for segment in lineGroup.segments {
                let affected = presentation.affectedSegmentIDs.contains(segment.id)
                let selected = presentation.selectedLineID == nil
                    || presentation.selectedLineID == segment.lineID
                let muted = !traceMode && (!selected || (issuesActive && !affected))
                mapContext.stroke(
                    segment.path,
                    with: .color(
                        muted
                            ? Color(white: 0.72).opacity(0.48)
                            : .tubeLine(segment.lineID)
                    ),
                    style: StrokeStyle(
                        lineWidth: lineGroup.lineID.usesParallelSchematicStroke
                            ? document.styles.parallelRouteOuterStrokeWidth
                            : document.styles.routeStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
            if lineGroup.lineID.usesParallelSchematicStroke {
                for segment in lineGroup.segments {
                    mapContext.stroke(
                        segment.path,
                        with: .color(.white),
                        style: StrokeStyle(
                            lineWidth: document.styles.parallelRouteInnerStrokeWidth,
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
                    with: .color(.red.opacity(0.82)),
                    style: StrokeStyle(
                        lineWidth: document.styles.affectedOuterStrokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                mapContext.stroke(
                    segment.path,
                    with: .color(.white),
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

    private func drawStationMarkers(context: inout GraphicsContext) {
        let issuesActive = presentation.emphasizesIssues && !presentation.affectedSegmentIDs.isEmpty
        for marker in document.stationMarkers {
            let affected = issuesActive && presentation.affectedStationIDs.contains(marker.stationID)
            let selected = presentation.selectedStationID == marker.stationID
            let outline = affected ? Color.red : selected ? Color.blue : Color(red: 0.08, green: 0.09, blue: 0.10)

            for primitive in marker.primitives {
                switch primitive {
                case let .connector(connector):
                    var path = Path()
                    path.move(to: CGPoint(connector.start))
                    path.addLine(to: CGPoint(connector.end))
                    context.stroke(
                        path,
                        with: .color(outline),
                        style: StrokeStyle(lineWidth: connector.width + (selected ? 2 : 1.8), lineCap: .round)
                    )
                    context.stroke(
                        path,
                        with: .color(.white),
                        style: StrokeStyle(lineWidth: connector.width - 2.2, lineCap: .round)
                    )
                case let .walkingConnector(connector):
                    var path = Path()
                    path.move(to: CGPoint(connector.start))
                    path.addLine(to: CGPoint(connector.end))
                    context.stroke(
                        path,
                        with: .color(outline),
                        style: StrokeStyle(
                            lineWidth: connector.width + (selected ? 1.5 : 0),
                            lineCap: .butt,
                            dash: [8, 5]
                        )
                    )
                case let .circle(circle):
                    let rect = CGRect(
                        x: circle.centre.x - circle.radius,
                        y: circle.centre.y - circle.radius,
                        width: circle.radius * 2,
                        height: circle.radius * 2
                    )
                    let path = Path(ellipseIn: rect)
                    context.fill(path, with: .color(affected ? Color.red.opacity(0.16) : .white))
                    context.stroke(
                        path,
                        with: .color(outline),
                        lineWidth: circle.outlineWidth + (selected ? 1.8 : 0)
                    )
                case let .tick(tick):
                    var path = Path()
                    path.move(to: CGPoint(tick.start))
                    path.addLine(to: CGPoint(tick.end))
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
        let viewportRect = CGRect(origin: .zero, size: viewport).insetBy(dx: 4, dy: 4)
        let zoomRatio = cameraScale / max(0.001, minimumCameraScale)
        let showsSecondaryLabels = document.geometryStatus != .authored
            ? cameraScale >= 0.72
            : zoomRatio >= 2.15
        let selectedStationID = presentation.selectedStationID
        let visibleLabels = renderedLabels.filter { renderedLabel in
            let label = renderedLabel.label
            return label.priority >= 10
                || showsSecondaryLabels
                || label.stationID == selectedStationID
        }
        let labels: [RenderedLabel]
        if let selectedStationID {
            labels = visibleLabels.filter { $0.label.stationID == selectedStationID }
                + visibleLabels.filter { $0.label.stationID != selectedStationID }
        } else {
            labels = visibleLabels
        }
        let markerFrames = markerExclusionFrames()
        let lineBlockers = lineExclusionBlockers(in: viewportRect)
        let markerIndex = BeckMapSpatialIndex(markerFrames, bounds: \.frame)
        let lineIndex = BeckMapSpatialIndex(lineBlockers, bounds: \.bounds)
        var occupiedIndex = BeckMapSpatialIndex<CGRect>()

        for renderedLabel in labels {
            let label = renderedLabel.label
            let screenAnchor = screenPoint(renderedLabel.artworkAnchor)
            var placement: (
                candidate: BeckMapLabelPlacementCandidate,
                metrics: LabelMetrics,
                frame: CGRect
            )?
            for candidateOffset in renderedLabel.candidateOffsets {
                let candidate = BeckMapLabelPlacementCandidate(
                    position: CGPoint(
                        x: screenAnchor.x + candidateOffset.position.x,
                        y: screenAnchor.y + candidateOffset.position.y
                    ),
                    alignment: candidateOffset.alignment
                )
                let metrics = renderedLabel.metrics[candidate.alignment]
                let labelFrame = metrics.bounds
                    .applying(renderedLabel.rotation)
                    .standardized
                    .offsetBy(dx: candidate.position.x, dy: candidate.position.y)
                guard viewportRect.intersects(labelFrame) else { continue }
                let collisionFrame = labelFrame.insetBy(dx: -3, dy: -2)
                guard BeckMapLabelCollisionResolver.accepts(
                    collisionFrame,
                    markerIndex: markerIndex,
                    lineIndex: lineIndex,
                    occupiedIndex: occupiedIndex
                ) else { continue }
                placement = (candidate, metrics, collisionFrame)
                break
            }
            guard let placement else { continue }

            let weight: Font.Weight = label.priority >= 10 ? .semibold : .medium
            var text = context.resolve(Text(label.text).font(.system(
                size: placement.metrics.fontSize,
                weight: weight
            )))
            text.shading = .color(Color(red: 0.04, green: 0.12, blue: 0.25))
            let anchor: UnitPoint
            switch placement.candidate.alignment {
            case .leading:
                anchor = .leading
            case .centre:
                anchor = .center
            case .trailing:
                anchor = .trailing
            }

            var labelContext = context
            labelContext.concatenate(
                renderedLabel.rotation.concatenating(CGAffineTransform(
                    translationX: placement.candidate.position.x,
                    y: placement.candidate.position.y
                ))
            )
            labelContext.fill(
                Path(roundedRect: placement.metrics.bounds, cornerRadius: 2),
                with: .color(.white.opacity(0.86))
            )
            labelContext.draw(text, at: .zero, anchor: anchor)
            occupiedIndex.insert(placement.frame, bounds: placement.frame)
        }
    }

    private func markerExclusionFrames() -> [BeckMapLabelBlocker] {
        document.stationMarkers.flatMap { marker in
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
        minimumCameraScale = max(0.01, fittedScale * 0.82)
        maximumCameraScale = max(3.8, fittedScale * 4)
        cameraScale = fittedScale
        cameraOffset = CGSize(
            width: size.width / 2 - fittingBounds.midX * cameraScale,
            height: size.height / 2 - fittingBounds.midY * cameraScale
        )
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
        withAnimation(.smooth(duration: 0.55)) {
            cameraScale = nextScale
            cameraOffset = CGSize(
                width: size.width / 2 - CGFloat((minX + maxX) / 2) * nextScale,
                height: size.height / 2 - CGFloat((minY + maxY) / 2) * nextScale - 28
            )
        }
    }

    private func handlePan(translation: CGSize, phase: BeckMapGesturePhase) {
        switch phase {
        case .began:
            isPanning = true
            panStartOffset = cameraOffset
        case .changed:
            isPanning = true
            let start = panStartOffset ?? cameraOffset
            panStartOffset = start
            cameraOffset = CGSize(width: start.width + translation.width, height: start.height + translation.height)
        case .ended:
            isPanning = false
            panStartOffset = nil
        }
    }

    private func handlePinch(magnification: CGFloat, location: CGPoint, phase: BeckMapGesturePhase) {
        switch phase {
        case .began:
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
            cameraScale = nextScale
            cameraOffset = CGSize(
                width: location.x - mapPoint.x * nextScale,
                height: location.y - mapPoint.y * nextScale
            )
        case .ended:
            isPinching = false
            pinchStartScale = nil
            pinchMapPoint = nil
            panStartOffset = nil
        }
    }

    private func selectStation(at location: CGPoint) {
        let nearest = document.stationMarkers.min {
            distance(screenPoint($0.anchor), location) < distance(screenPoint($1.anchor), location)
        }
        if let nearest,
           distance(screenPoint(nearest.anchor), location) <= max(24, nearest.hitRadius * cameraScale) {
            onStationTap(nearest.stationID)
        } else {
            onBackgroundTap()
        }
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
        renderedSegments: [RenderedSegment]
    ) -> CGRect {
        var bounds = renderedSegments.reduce(into: CGRect.null) { partial, segment in
            partial = partial.union(segment.path.boundingRect)
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
        let renderedLabels: [RenderedLabel]
        let artworkBounds: CGRect
        let debugReferenceImage: UIImage?

        init(document: BeckMapDocument) {
            let paths = Dictionary(uniqueKeysWithValues: document.paths.map {
                ($0.id, $0.commands)
            })
            let renderedSegments = document.segments.compactMap {
                segment -> RenderedSegment? in
                guard let commands = paths[segment.pathID] else { return nil }
                return RenderedSegment(
                    id: segment.id,
                    lineID: segment.lineID,
                    path: BeckMapCanvas.makePath(
                        commands: commands,
                        translation: segment.translation
                    ),
                    collisionEdges: BeckMapCanvas.makeCollisionEdges(
                        commands: commands,
                        translation: segment.translation
                    )
                )
            }
            self.renderedSegments = renderedSegments

            var seenLineIDs: Set<TubeLineID> = []
            let orderedLineIDs = renderedSegments.compactMap { segment in
                seenLineIDs.insert(segment.lineID).inserted ? segment.lineID : nil
            }
            let segmentsByLineID = Dictionary(grouping: renderedSegments, by: \.lineID)
            self.renderedLineGroups = orderedLineIDs.map { lineID in
                RenderedLineGroup(
                    lineID: lineID,
                    segments: segmentsByLineID[lineID, default: []]
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
                let candidateOffsets: [BeckMapLabelPlacementCandidate]
                if let stationAnchor = stationAnchors[label.stationID] {
                    candidateOffsets = BeckMapLabelPlacementResolver.candidates(
                        stationScreenPosition: .zero,
                        artworkOffset: CGVector(
                            dx: artworkPosition.x - stationAnchor.x,
                            dy: artworkPosition.y - stationAnchor.y
                        )
                    )
                } else {
                    candidateOffsets = [
                        .init(position: .zero, alignment: label.alignment),
                    ]
                }
                let fontSize: CGFloat = label.priority >= 10 ? 16 : 14
                return RenderedLabel(
                    label: label,
                    artworkAnchor: artworkAnchor,
                    candidateOffsets: candidateOffsets,
                    rotation: CGAffineTransform(
                        rotationAngle: label.rotationDegrees * .pi / 180
                    ),
                    metrics: LabelMetricsByAlignment(
                        leading: BeckMapCanvas.labelMetrics(
                            for: label,
                            styles: document.styles,
                            fontSizeOverride: fontSize,
                            alignmentOverride: .leading
                        ),
                        centre: BeckMapCanvas.labelMetrics(
                            for: label,
                            styles: document.styles,
                            fontSizeOverride: fontSize,
                            alignmentOverride: .centre
                        ),
                        trailing: BeckMapCanvas.labelMetrics(
                            for: label,
                            styles: document.styles,
                            fontSizeOverride: fontSize,
                            alignmentOverride: .trailing
                        )
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.label.priority != rhs.label.priority {
                    return lhs.label.priority > rhs.label.priority
                }
                return lhs.label.id < rhs.label.id
            }
            self.artworkBounds = BeckMapCanvas.makeArtworkBounds(
                document: document,
                renderedSegments: renderedSegments
            )
            self.debugReferenceImage = BeckMapCanvas.loadDebugReference(for: document)
        }
    }

    struct RenderedSegment {
        let id: String
        let lineID: TubeLineID
        let path: Path
        let collisionEdges: [BeckMapCollisionEdge]
    }

    struct RenderedLineGroup {
        let lineID: TubeLineID
        let segments: [RenderedSegment]
    }

    struct RenderedLabel {
        let label: BeckMapLabelRecord
        let artworkAnchor: CGPoint
        let candidateOffsets: [BeckMapLabelPlacementCandidate]
        let rotation: CGAffineTransform
        let metrics: LabelMetricsByAlignment
    }

    struct LabelMetricsByAlignment {
        let leading: LabelMetrics
        let centre: LabelMetrics
        let trailing: LabelMetrics

        subscript(alignment: BeckMapLabelAlignment) -> LabelMetrics {
            switch alignment {
            case .leading: leading
            case .centre: centre
            case .trailing: trailing
            }
        }
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

struct BeckMapLabelBlocker: Equatable {
    let stationID: String
    let frame: CGRect
}

struct BeckMapCollisionEdge: Equatable {
    let start: CGPoint
    let end: CGPoint
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

struct BeckMapLabelPlacementCandidate: Equatable {
    let position: CGPoint
    let alignment: BeckMapLabelAlignment
}

enum BeckMapLabelPlacementResolver {
    static let preferredTether: CGFloat = 30
    static let maximumTether: CGFloat = 68
    private static let tetherDistances: [CGFloat] = [30, 38, 46, 56, 68]
    private static let angleOffsets: [CGFloat] = [
        0,
        .pi / 4,
        -.pi / 4,
        .pi / 2,
        -.pi / 2,
        .pi * 3 / 4,
        -.pi * 3 / 4,
        .pi,
    ]

    static func candidates(
        stationScreenPosition: CGPoint,
        artworkOffset: CGVector
    ) -> [BeckMapLabelPlacementCandidate] {
        let distance = hypot(artworkOffset.dx, artworkOffset.dy)
        let baseAngle = distance > 0.001 ? atan2(artworkOffset.dy, artworkOffset.dx) : 0
        return tetherDistances.flatMap { tether in
            angleOffsets.map { angleOffset in
                let angle = baseAngle + angleOffset
                let direction = CGVector(dx: cos(angle), dy: sin(angle))
                let alignment: BeckMapLabelAlignment
                if direction.dx > 0.25 {
                    alignment = .leading
                } else if direction.dx < -0.25 {
                    alignment = .trailing
                } else {
                    alignment = .centre
                }
                return BeckMapLabelPlacementCandidate(
                    position: CGPoint(
                        x: stationScreenPosition.x + direction.dx * tether,
                        y: stationScreenPosition.y + direction.dy * tether
                    ),
                    alignment: alignment
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
