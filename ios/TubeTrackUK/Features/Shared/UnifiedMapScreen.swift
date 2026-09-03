import CoreLocation
import SwiftUI

struct UnifiedMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var statusExpanded = false
    @Binding var closestStationPanelHidden: Bool
    @State private var layoutProgress: CGFloat = 0
    @State private var morphGeometry: MapMorphGeometry?
    @State private var geometryGraphID: String?
    @State private var resetToken = 0
    @State private var locationFocusGeneration = 0
    @State private var locationFocusRequest: MapLocationFocusRequest?
    @State private var transitionTask: Task<Void, Never>?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var actionNotice: MapActionNotice?
    @State private var zoomedDisruptionsExpanded = false
    @State private var presentedDisruption: ResolvedDisruption?
    @State private var realWorldResetAvailable = false
    @State private var realWorldOverviewOpacity = 1.0
    @State private var showsExploreHint = true
    @State private var exploreHintOpacity = 1.0

    var body: some View {
        ZStack {
            BeckMapScreen(
                resetToken: resetToken,
                locationFocusRequest: locationFocusRequest,
                contentVerticalBias: 36,
                onUserZoomIn: {
                    guard !closestStationPanelHidden else { return }
                    setClosestStationPanel(hidden: true)
                }
            )
                .opacity(beckRendererOpacity)
                .allowsHitTesting(appState.mapPresentationMode == .beck)

            RealWorldMapScreen(
                resetToken: resetToken,
                locationFocusRequest: locationFocusRequest,
                onResetAvailabilityChange: { realWorldResetAvailable = $0 },
                onOverviewOpacityChange: { realWorldOverviewOpacity = $0 }
            )
                .opacity(realWorldRendererOpacity)
                .allowsHitTesting(appState.mapPresentationMode == .realWorld)

            if let graph = appState.graph,
               let morphGeometry,
               geometryGraphID == graph.generatedAt {
                MapMorphTransitionLayer(
                    geometry: morphGeometry,
                    graph: graph,
                    layoutProgress: layoutProgress
                )
                .zIndex(1)
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                MapOverviewHeader(
                    disruptionsExpanded: $statusExpanded,
                    zoomedDisruptionsExpanded: $zoomedDisruptionsExpanded,
                    overviewOpacity: overviewOpacity,
                    compactForZoom: compactOverviewForZoom,
                    onSelectDisruption: {
                        setClosestStationPanel(hidden: true)
                    }
                )
                .opacity(activeMapChromeOpacity)
                .allowsHitTesting(activeMapChromeOpacity > 0.1)
                .zIndex(4)
            }
        }
        .overlay(alignment: .bottom) {
            bottomOverlay
        }
        .overlay(alignment: .bottom) {
            compactOpenStreetMapAttribution
        }
        .overlay(alignment: .top) {
            actionToast
        }
        .onAppear {
            layoutProgress = appState.mapPresentationMode == .realWorld ? 1 : 0
        }
        .onChange(of: appState.mapPresentationMode) { _, mode in
            transitionTask?.cancel()
            let target: CGFloat = mode == .realWorld ? 1 : 0
            if reduceMotion {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { layoutProgress = target }
            } else {
                // Give the newly active renderer one run-loop turn to adopt the
                // shared viewport before its geometry starts becoming visible.
                transitionTask = Task { @MainActor in
                    await Task.yield()
                    guard !Task.isCancelled,
                          appState.mapPresentationMode == mode else { return }
                    withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.5)) {
                        layoutProgress = target
                    }
                }
            }
        }
        .onDisappear {
            transitionTask?.cancel()
            toastDismissTask?.cancel()
        }
        .onChange(of: compactOverviewForZoom) { _, compact in
            if !compact {
                zoomedDisruptionsExpanded = false
            }
        }
        .onChange(of: appState.disruptionSelectionGeneration) { _, _ in
            guard appState.selectedDisruption != nil else { return }
            setClosestStationPanel(hidden: true)
        }
        .onChange(of: appState.stationSelectionGeneration) { _, _ in
            guard appState.selectedStation != nil else { return }
            statusExpanded = false
            zoomedDisruptionsExpanded = false
        }
        .onChange(of: appState.selectedTrainID) { _, trainID in
            guard trainID != nil else { return }
            setClosestStationPanel(hidden: true)
        }
        .sheet(item: $presentedDisruption) { disruption in
            DisruptionDetailSheet(disruption: disruption)
        }
        .task(id: appState.graph?.generatedAt) {
            guard let graph = appState.graph else {
                morphGeometry = nil
                geometryGraphID = nil
                return
            }
            do {
                let document: BeckMapDocument
                if let startupDocument = appState.initialBeckMapDocument {
                    document = startupDocument
                } else {
                    document = try await Task.detached(priority: .utility) {
                        try BeckMapRepository().load(
                            region: .fullUnderground,
                            graph: graph
                        )
                    }.value
                }
                guard !Task.isCancelled else { return }
                let geometry = await Task.detached(priority: .utility) {
                    MapMorphGeometry(document: document, graph: graph)
                }.value
                guard !Task.isCancelled else { return }
                morphGeometry = geometry
                geometryGraphID = graph.generatedAt
            } catch {
                // Both maps remain usable if the enhancement layer cannot load.
                morphGeometry = nil
                geometryGraphID = nil
            }
        }
        .task {
            showsExploreHint = true
            exploreHintOpacity = 1

            do {
                try await Task.sleep(for: .seconds(3.5))
                withAnimation(.linear(duration: 3.5)) {
                    exploreHintOpacity = 0
                }
                try await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                showsExploreHint = false
            } catch {
                // The view disappeared before the hint finished fading.
            }
        }
    }

    private var beckRendererOpacity: Double {
        reduceMotion ? (appState.mapPresentationMode == .beck ? 1 : 0)
            : Double(max(0, min(1, 1 - layoutProgress * 1.65)))
    }

    private var realWorldRendererOpacity: Double {
        reduceMotion ? (appState.mapPresentationMode == .realWorld ? 1 : 0)
            : Double(max(0, min(1, (layoutProgress - 0.38) * 1.62)))
    }

    private var realWorldChromeOpacity: Double {
        reduceMotion ? (appState.mapPresentationMode == .realWorld ? 1 : 0)
            : Double(max(0, min(1, (layoutProgress - 0.58) * 2.4)))
    }

    private var overviewOpacity: Double {
        switch appState.mapPresentationMode {
        case .beck:
            guard let camera = appState.beckMapCameraSnapshot else { return 1 }
            return BeckMapOverviewVisibilityPolicy.opacity(
                at: camera.scale,
                fittedScale: camera.fittedScale,
                reduceMotion: reduceMotion
            )
        case .realWorld:
            return realWorldOverviewOpacity
        }
    }

    private var compactOverviewForZoom: Bool {
        appState.mapPresentationMode == .beck && overviewOpacity <= 0.5
    }

    private var activeMapChromeOpacity: Double {
        appState.mapPresentationMode == .beck ? beckRendererOpacity : realWorldChromeOpacity
    }

    private var showsMapReset: Bool {
        switch appState.mapPresentationMode {
        case .beck:
            guard let camera = appState.beckMapCameraSnapshot else { return false }
            return BeckMapOverviewVisibilityPolicy.shouldShowReset(
                at: camera.scale,
                fittedScale: camera.fittedScale
            )
        case .realWorld:
            return realWorldResetAvailable
        }
    }

    private var hasMapSelection: Bool {
        appState.selectedStation != nil
            || appState.selectedEngineeringWork != nil
            || appState.selectedDisruption != nil
            || appState.selectedTrain != nil
            || appState.selectedLineID != nil
    }

    private func setClosestStationPanel(hidden: Bool) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                closestStationPanelHidden = hidden
            }
        } else {
            withAnimation(.smooth(duration: hidden ? 0.24 : 0.32)) {
                closestStationPanelHidden = hidden
            }
        }
    }

    private func resetMapView() {
        realWorldResetAvailable = false
        zoomedDisruptionsExpanded = false
        setClosestStationPanel(hidden: false)
        appState.clearMapSelection()
        appState.selectedMapNetworkStat = nil
        appState.disruptionDisplayMode = .normal
        resetToken += 1
    }

    private var bottomOverlay: some View {
        GeometryReader { proxy in
            bottomOverlayContent(availableSize: proxy.size)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    @ViewBuilder
    private var compactOpenStreetMapAttribution: some View {
        if appState.mapPresentationMode == .realWorld {
            OpenStreetMapAttribution()
                .opacity((1 - overviewOpacity) * realWorldChromeOpacity)
                .allowsHitTesting(overviewOpacity < 0.88)
                .accessibilityHidden(overviewOpacity >= 0.88)
                .padding(.horizontal, 12)
                .safeAreaPadding(.bottom, 6)
                .zIndex(3)
        }
    }

    private func bottomOverlayContent(availableSize: CGSize) -> some View {
        let contentColumnWidth = MapDockMetrics.contentColumnWidth(
            for: availableSize.width
        )

        return VStack(spacing: 9) {
            if appState.selectedDisruption == nil,
               let work = appState.selectedEngineeringWork {
                PlannedWorkDetailCard(work: work)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if appState.selectedDisruption == nil,
                      let lineID = appState.selectedLineID {
                LineDetailCard(lineID: lineID)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showsExploreHint,
               !hasMapSelection,
               !statusExpanded,
               overviewOpacity > 0.01 {
                MapExploreHint()
                    .opacity(overviewOpacity * exploreHintOpacity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            HStack(alignment: .bottom, spacing: MapDockMetrics.columnSpacing) {
                VStack(spacing: 9) {
                    if let station = appState.selectedStation {
                        StationDetailCard(
                            station: station,
                            onShowDisruption: showDisruptionDetails(_:)
                        )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let disruption = appState.selectedDisruption {
                        DisruptionDetailCard(
                            disruption: disruption,
                            onClose: resetMapView,
                            onShowDetails: showDisruptionDetails(_:)
                        )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if appState.mapPresentationMode == .realWorld,
                       overviewOpacity > 0.01 {
                        OpenStreetMapAttribution()
                            .padding(.top, exploreStatsSpacing(for: availableSize.height))
                            .opacity(overviewOpacity * realWorldChromeOpacity)
                            .allowsHitTesting(overviewOpacity > 0.12)
                            .accessibilityHidden(overviewOpacity <= 0.12)
                    }

                    if !hasMapSelection, !statusExpanded, overviewOpacity > 0.01 {
                        MapNetworkStatsCard(onAction: showActionNotice(_:))
                            .padding(
                                .top,
                                appState.mapPresentationMode == .realWorld
                                    ? 0
                                    : exploreStatsSpacing(for: availableSize.height)
                            )
                            .opacity(overviewOpacity)
                            .allowsHitTesting(overviewOpacity > 0.12)
                            .accessibilityHidden(overviewOpacity <= 0.12)
                            .transition(.opacity)
                    }

                    if appState.selectedDisruption == nil,
                       appState.selectedTrain == nil,
                       !closestStationPanelHidden,
                       supportingContentOpacity > 0.01 {
                        ClosestStationMapSection()
                        .opacity(supportingContentOpacity)
                        .allowsHitTesting(supportingContentOpacity > 0.12)
                        .accessibilityHidden(supportingContentOpacity <= 0.12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if appState.showLiveTrains {
                        TrainFilterBar()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if !appState.isViewingLiveStatus {
                        returnToTodayLink
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(width: contentColumnWidth)

                MapActionButtons(
                    showsReset: showsMapReset,
                    onReset: resetMapView,
                    onFocusUserLocation: focusMap(on:),
                    onAction: showActionNotice(_:)
                )
                .fixedSize()
            }
            .padding(.horizontal, MapDockMetrics.horizontalPadding)
        }
        .animation(.smooth(duration: 0.35), value: appState.showLiveTrains)
        .animation(.smooth(duration: 0.25), value: appState.selectedTrainID)
        .animation(.smooth(duration: 0.35), value: appState.selectedStationID)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.32),
            value: appState.selectedDisruptionID
        )
        .animation(.smooth(duration: 0.32), value: closestStationPanelHidden)
        .safeAreaPadding(.bottom, 4)
    }

    private var returnToTodayLink: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) {
                appState.setDisruptionDateSelection(.today)
            }
        } label: {
            Label("Back to today", systemImage: "calendar.badge.clock")
                .font(.appCaption(.semibold))
                .foregroundStyle(Color.tubeBlue)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(minHeight: 44)
        .accessibilityLabel("Return to today")
        .accessibilityHint("Shows current service status")
    }

    private func exploreStatsSpacing(for availableHeight: CGFloat) -> CGFloat {
        if availableHeight >= 850 { return 16 }
        if availableHeight >= 700 { return 12 }
        return 8
    }

    private var supportingContentOpacity: Double {
        appState.mapPresentationMode == .realWorld ? overviewOpacity : 1
    }

    private func focusMap(on location: CLLocation) {
        guard let graph = appState.graph else { return }
        locationFocusGeneration += 1
        guard let request = MapLocationFocusPolicy.request(
            for: location,
            in: graph,
            id: locationFocusGeneration
        ) else { return }
        locationFocusRequest = request
        setClosestStationPanel(hidden: true)
    }

    @ViewBuilder
    private var actionToast: some View {
        if let actionNotice {
            Label(actionNotice.message, systemImage: actionNotice.symbol)
                .font(.appSubheadline(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .glassEffect(.regular.tint(Color.tubeBlue), in: .capsule)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                .padding(.top, actionToastTopPadding)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.94))
                )
                .id(actionNotice.id)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
        }
    }

    private var actionToastTopPadding: CGFloat {
        if statusExpanded { return 352 }
        return compactOverviewForZoom ? 92 : 174
    }

    private func showActionNotice(_ notice: MapActionNotice) {
        toastDismissTask?.cancel()

        withAnimation(
            reduceMotion
                ? nil
                : .timingCurve(0.16, 1, 0.3, 1, duration: 0.22)
        ) {
            actionNotice = notice
        }

        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, actionNotice?.id == notice.id else { return }
            withAnimation(
                reduceMotion
                    ? nil
                    : .timingCurve(0.7, 0, 0.84, 1, duration: 0.16)
            ) {
                actionNotice = nil
            }
        }
    }

    private func showDisruptionDetails(_ disruption: ResolvedDisruption) {
        presentedDisruption = disruption
    }

}

private struct OpenStreetMapAttribution: View {
    var body: some View {
        Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
            Text("© OpenStreetMap contributors")
                .font(.appCaption2(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
        }
        .foregroundStyle(.primary)
    }
}
