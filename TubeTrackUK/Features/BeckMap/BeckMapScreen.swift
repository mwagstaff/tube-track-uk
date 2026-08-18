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
               loadedGraphGeneratedAt == graph.generatedAt {
                BeckMapCanvas(
                    document: document,
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
                    "Beck map unavailable",
                    systemImage: "map.fill",
                    description: Text(documentLoadError)
                )
            } else if appState.graph != nil || isLoadingDocument {
                ProgressView("Loading authored Beck map…")
            } else if appState.isLoadingGraph {
                ProgressView("Loading Underground map…")
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
            documentLoadError = nil
            loadedGraphGeneratedAt = nil
            guard let graph = appState.graph else {
                isLoadingDocument = false
                return
            }
            isLoadingDocument = true
            defer { isLoadingDocument = false }
            do {
                document = try BeckMapRepository().load(region: selectedRegion, graph: graph)
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
        return .centralCoreJoin
    }

    private var referenceOverlayVisible: Bool {
        #if DEBUG
        showsReferenceOverlay
        #else
        false
        #endif
    }

    private var regionStatusTitle: String {
        "\(selectedRegion.title) · authored slice"
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
    let presentation: BeckMapPresentationSnapshot
    let referenceOverlayVisible: Bool
    let resetToken: Int
    let onStationTap: (String) -> Void
    let onBackgroundTap: () -> Void

    private let renderedSegments: [RenderedSegment]
    private let artworkBounds: CGRect
    private let debugReferenceImage: UIImage?

    @State private var cameraScale: CGFloat = 0.35
    @State private var cameraOffset = CGSize.zero
    @State private var minimumCameraScale: CGFloat = 0.2
    @State private var maximumCameraScale: CGFloat = 3.8
    @State private var panStartOffset: CGSize?
    @State private var pinchStartScale: CGFloat?
    @State private var pinchMapPoint: CGPoint?

    init(
        document: BeckMapDocument,
        presentation: BeckMapPresentationSnapshot,
        referenceOverlayVisible: Bool,
        resetToken: Int,
        onStationTap: @escaping (String) -> Void,
        onBackgroundTap: @escaping () -> Void
    ) {
        self.document = document
        self.presentation = presentation
        self.referenceOverlayVisible = referenceOverlayVisible
        self.resetToken = resetToken
        self.onStationTap = onStationTap
        self.onBackgroundTap = onBackgroundTap

        let paths = Dictionary(uniqueKeysWithValues: document.paths.map { ($0.id, $0.commands) })
        let renderedSegments: [RenderedSegment] = document.segments.compactMap { segment -> RenderedSegment? in
            guard let commands = paths[segment.pathID] else { return nil }
            return RenderedSegment(
                id: segment.id,
                lineID: segment.lineID,
                path: Self.makePath(commands: commands, translation: segment.translation)
            )
        }
        self.renderedSegments = renderedSegments
        self.artworkBounds = Self.makeArtworkBounds(
            document: document,
            renderedSegments: renderedSegments
        )
        self.debugReferenceImage = Self.loadDebugReference(for: document)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
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
        .accessibilityLabel("Interactive London Underground Beck map")
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
        for segment in renderedSegments {
            let affected = presentation.affectedSegmentIDs.contains(segment.id)
            let selected = presentation.selectedLineID == nil || presentation.selectedLineID == segment.lineID
            let muted = !traceMode && (!selected || (issuesActive && !affected))
            mapContext.stroke(
                segment.path,
                with: .color(muted ? Color(white: 0.72).opacity(0.48) : .tubeLine(segment.lineID)),
                style: StrokeStyle(
                    lineWidth: document.styles.routeStrokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
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
            drawStationMarkers(context: &mapContext)
            drawLabels(context: &mapContext, viewport: size)
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
        for label in document.labels {
            if document.geometryStatus != .authored, cameraScale < 0.72, label.priority < 10 {
                continue
            }
            let screenPosition = screenPoint(label.position)
            let artworkPosition = CGPoint(label.position)
            let metrics = Self.labelMetrics(for: label, styles: document.styles)
            var text = context.resolve(Text(label.text).font(.system(size: metrics.fontSize, weight: .semibold)))
            text.shading = .color(Color(red: 0.04, green: 0.12, blue: 0.25))
            let anchor: UnitPoint
            switch label.alignment {
            case .leading:
                anchor = .leading
            case .centre:
                anchor = .center
            case .trailing:
                anchor = .trailing
            }
            let labelFrame = CGRect(
                x: screenPosition.x + metrics.bounds.minX * cameraScale,
                y: screenPosition.y + metrics.bounds.minY * cameraScale,
                width: metrics.bounds.width * cameraScale,
                height: metrics.bounds.height * cameraScale
            )
            guard viewportRect.contains(labelFrame) else { continue }

            var labelContext = context
            labelContext.concatenate(
                CGAffineTransform(translationX: artworkPosition.x, y: artworkPosition.y)
                    .rotated(by: label.rotationDegrees * .pi / 180)
            )
            labelContext.fill(
                Path(roundedRect: metrics.bounds, cornerRadius: 2),
                with: .color(.white.opacity(0.9))
            )
            labelContext.draw(text, at: .zero, anchor: anchor)
        }
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
            panStartOffset = cameraOffset
        case .changed:
            let start = panStartOffset ?? cameraOffset
            panStartOffset = start
            cameraOffset = CGSize(width: start.width + translation.width, height: start.height + translation.height)
        case .ended:
            panStartOffset = nil
        }
    }

    private func handlePinch(magnification: CGFloat, location: CGPoint, phase: BeckMapGesturePhase) {
        switch phase {
        case .began:
            pinchStartScale = cameraScale
            pinchMapPoint = CGPoint(
                x: (location.x - cameraOffset.width) / cameraScale,
                y: (location.y - cameraOffset.height) / cameraScale
            )
        case .changed:
            guard let startScale = pinchStartScale, let mapPoint = pinchMapPoint else { return }
            let nextScale = min(maximumCameraScale, max(minimumCameraScale, startScale * magnification))
            cameraScale = nextScale
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
        styles: BeckMapStyleRecord
    ) -> LabelMetrics {
        let fontSize = CGFloat(
            label.priority >= 10 ? styles.primaryLabelFontSize : styles.secondaryLabelFontSize
        )
        let padding = CGFloat(styles.labelPadding)
        let lines = label.text.split(separator: "\n", omittingEmptySubsequences: false)
        let longestLine = lines.map(\.count).max() ?? 0
        let width = max(fontSize * 2.8, CGFloat(longestLine) * fontSize * 0.54)
        let height = max(fontSize * 1.44, CGFloat(lines.count) * fontSize * 1.1)
        let originX: CGFloat
        switch label.alignment {
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

    private struct RenderedSegment {
        let id: String
        let lineID: TubeLineID
        let path: Path
    }

    private struct LabelMetrics {
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
