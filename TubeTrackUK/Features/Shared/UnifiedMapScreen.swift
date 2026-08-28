import SwiftUI

struct UnifiedMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("statusPanelExpanded") private var statusExpanded = false
    @AppStorage("closestStationPanelHidden") private var closestStationPanelHidden = false
    @State private var layoutProgress: CGFloat = 0
    @State private var morphGeometry: MapMorphGeometry?
    @State private var geometryGraphID: String?
    @State private var resetToken = 0
    @State private var transitionTask: Task<Void, Never>?
    @State private var restorePulseTask: Task<Void, Never>?
    @State private var restoreIconPulses = false

    var body: some View {
        ZStack {
            BeckMapScreen(
                resetToken: resetToken,
                contentVerticalBias: closestStationPanelHidden ? 0 : 84
            )
                .opacity(beckRendererOpacity)
                .allowsHitTesting(appState.mapPresentationMode == .beck)

            RealWorldMapScreen(resetToken: resetToken)
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
            VStack(spacing: 6) {
                MapToolbar { resetToken += 1 }
                    .tint(.tubeBlue)

                HStack {
                    if closestStationPanelHidden {
                        closestStationRestoreButton
                            .transition(.scale(scale: 0.78).combined(with: .opacity))
                    }

                    Spacer()
                    Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                        Text("© OpenStreetMap contributors")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .foregroundStyle(.primary)
                    .opacity(realWorldChromeOpacity)
                    .allowsHitTesting(appState.mapPresentationMode == .realWorld)
                    .accessibilityHidden(appState.mapPresentationMode != .realWorld)
                }
                .padding(.horizontal, 12)
            }
        }
        .overlay(alignment: .bottom) {
            bottomOverlay
        }
        .onAppear {
            layoutProgress = appState.mapPresentationMode == .realWorld ? 1 : 0
            if closestStationPanelHidden {
                triggerRestoreIconPulse()
            }
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
            restorePulseTask?.cancel()
        }
        .onChange(of: closestStationPanelHidden) { _, hidden in
            if hidden {
                triggerRestoreIconPulse()
            } else {
                restorePulseTask?.cancel()
                restoreIconPulses = false
            }
        }
        .task(id: appState.graph?.generatedAt) {
            guard let graph = appState.graph else {
                morphGeometry = nil
                geometryGraphID = nil
                return
            }
            do {
                let document = try BeckMapRepository().load(
                    region: .fullUnderground,
                    graph: graph
                )
                morphGeometry = MapMorphGeometry(document: document, graph: graph)
                geometryGraphID = graph.generatedAt
            } catch {
                // Both maps remain usable if the enhancement layer cannot load.
                morphGeometry = nil
                geometryGraphID = nil
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

    private var closestStationRestoreButton: some View {
        Button {
            setClosestStationPanel(hidden: false)
        } label: {
            Image(systemName: "location.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.tubeBlue)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .overlay {
            Circle()
                .stroke(Color.tubeBlue.opacity(restoreIconPulses ? 0 : 0.55), lineWidth: 2)
                .scaleEffect(restoreIconPulses ? 1.48 : 0.84)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Show closest station")
        .accessibilityHint("Restores live departures above the Map tab bar")
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

    private func triggerRestoreIconPulse() {
        restorePulseTask?.cancel()
        restoreIconPulses = false
        guard !reduceMotion else { return }
        restorePulseTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, closestStationPanelHidden else { return }
            withAnimation(.easeOut(duration: 0.62).repeatCount(3, autoreverses: false)) {
                restoreIconPulses = true
            }
        }
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
            } else if let work = appState.selectedEngineeringWork {
                PlannedWorkDetailCard(work: work)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let disruption = appState.selectedDisruption {
                DisruptionDetailCard(disruption: disruption)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let lineID = appState.selectedLineID {
                LineDetailCard(lineID: lineID)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if statusExpanded {
                LiveStatusPanel(expanded: $statusExpanded)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                MapStatusDock(expanded: $statusExpanded)
            }

            if !closestStationPanelHidden {
                ClosestStationMapSection {
                    setClosestStationPanel(hidden: true)
                }
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: appState.showLiveTrains)
        .animation(.smooth(duration: 0.35), value: appState.selectedStationID)
        .animation(.smooth(duration: 0.32), value: closestStationPanelHidden)
        .safeAreaPadding(.bottom, 4)
    }
}
