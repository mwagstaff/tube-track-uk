import SwiftUI

enum MapDockMetrics {
    static let controlSize: CGFloat = 44
}

struct MapToolbar: View {
    @Environment(TubeAppState.self) private var appState
    let onReset: () -> Void
    let showsClosestStationRestore: Bool
    let restoreIconPulses: Bool
    let onRestoreClosestStation: () -> Void

    init(
        onReset: @escaping () -> Void,
        showsClosestStationRestore: Bool = false,
        restoreIconPulses: Bool = false,
        onRestoreClosestStation: @escaping () -> Void = {}
    ) {
        self.onReset = onReset
        self.showsClosestStationRestore = showsClosestStationRestore
        self.restoreIconPulses = restoreIconPulses
        self.onRestoreClosestStation = onRestoreClosestStation
    }

    var body: some View {
        @Bindable var state = appState

        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                Spacer(minLength: 4)

                Menu {
                    Picker("Appearance", selection: $state.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Label(mode.actionTitle, systemImage: mode.symbol)
                                .tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: appState.appearanceMode.symbol)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Appearance")
                .accessibilityValue(appState.appearanceMode.title)

                Button(action: onReset) {
                    Image(systemName: "scope")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Return to central London")

                if showsClosestStationRestore {
                    Button(action: onRestoreClosestStation) {
                        Image(systemName: "location.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color.tubeBlue)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .overlay {
                        Circle()
                            .stroke(
                                Color.tubeBlue.opacity(restoreIconPulses ? 0 : 0.55),
                                lineWidth: 2
                            )
                            .scaleEffect(restoreIconPulses ? 1.48 : 0.84)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Show closest station")
                    .accessibilityHint("Restores live departures above the Map tab bar")
                    .transition(.scale(scale: 0.78).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

struct MapActionButtons: View {
    @Environment(TubeAppState.self) private var appState
    @State private var stationSearchPresented = false
    @State private var pendingStationSelection: TubeStation?
    let onReset: (() -> Void)?
    let showsNavigationControls: Bool
    let showsClosestStationRestore: Bool
    let restoreIconPulses: Bool
    let onRestoreClosestStation: () -> Void

    init(
        onReset: (() -> Void)? = nil,
        showsNavigationControls: Bool = false,
        showsClosestStationRestore: Bool = false,
        restoreIconPulses: Bool = false,
        onRestoreClosestStation: @escaping () -> Void = {}
    ) {
        self.onReset = onReset
        self.showsNavigationControls = showsNavigationControls
        self.showsClosestStationRestore = showsClosestStationRestore
        self.restoreIconPulses = restoreIconPulses
        self.onRestoreClosestStation = onRestoreClosestStation
    }

    private var destinationMode: MapPresentationMode {
        appState.mapPresentationMode.toggled
    }

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 6) {
            if showsNavigationControls {
                Menu {
                    Picker("Appearance", selection: $state.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Label(mode.actionTitle, systemImage: mode.symbol)
                                .tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: appState.appearanceMode.symbol)
                }
                .mapDockButtonStyle()
                .accessibilityLabel("Appearance")
                .accessibilityValue(appState.appearanceMode.title)

                if let onReset {
                    Button(action: onReset) {
                        Image(systemName: "scope")
                    }
                    .mapDockButtonStyle()
                    .accessibilityLabel("Return to central London")
                }
            }

            Button {
                withAnimation(.smooth(duration: 0.3)) {
                    appState.toggleDisruptionHighlighting()
                }
            } label: {
                Image(systemName: AppTab.works.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        appState.disruptionDisplayMode == .issues ? .orange : .primary
                    )
            }
            .mapDockButtonStyle()
            .accessibilityLabel(
                appState.disruptionDisplayMode == .issues
                    ? "Show normal line colours"
                    : "Highlight disrupted lines"
            )
            .accessibilityValue(
                appState.disruptionDisplayMode == .issues
                    ? "Disrupted lines highlighted"
                    : "Normal line colours"
            )
            .accessibilityAddTraits(
                appState.disruptionDisplayMode == .issues ? .isSelected : []
            )

            Button {
                appState.mapPresentationMode = destinationMode
            } label: {
                Image(systemName: appState.mapPresentationMode.switchActionSymbol)
            }
            .mapDockButtonStyle()
            .accessibilityLabel(appState.mapPresentationMode.switchActionTitle)

            Button {
                appState.setLiveTrains(!appState.showLiveTrains)
            } label: {
                if appState.isLoadingLiveTrains {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.blue)
                } else {
                    Image(systemName: appState.showLiveTrains ? "tram.fill" : "tram")
                        .foregroundStyle(appState.showLiveTrains ? .blue : .primary)
                }
            }
            .mapDockButtonStyle()
            .accessibilityLabel(
                appState.isLoadingLiveTrains
                    ? "Loading live trains"
                    : appState.showLiveTrains ? "Hide live trains" : "Show live trains"
            )

            Button {
                stationSearchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .mapDockButtonStyle()
            .disabled(appState.graph == nil)
            .accessibilityLabel("Station search")

            if showsClosestStationRestore {
                Button(action: onRestoreClosestStation) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(Color.tubeBlue)
                }
                .mapDockButtonStyle()
                .overlay {
                    Circle()
                        .stroke(
                            Color.tubeBlue.opacity(restoreIconPulses ? 0 : 0.55),
                            lineWidth: 2
                        )
                        .scaleEffect(restoreIconPulses ? 1.48 : 0.84)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("Show closest station")
                .accessibilityHint("Restores live departures above the Map tab bar")
                .transition(.scale(scale: 0.78).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $stationSearchPresented, onDismiss: {
            guard let station = pendingStationSelection else { return }
            pendingStationSelection = nil
            appState.select(station: station)
        }) {
            Group {
                if let graph = appState.graph {
                    StationSearchSheet(
                        graph: graph,
                        selectedStationID: appState.selectedStationID
                    ) { station in
                        pendingStationSelection = station
                    }
                } else {
                    ContentUnavailableView(
                        "Network unavailable",
                        systemImage: "tram.fill",
                        description: Text("The London rail network is still loading.")
                    )
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

private extension View {
    func mapDockButtonStyle() -> some View {
        self
            .font(.headline)
            .frame(width: MapDockMetrics.controlSize, height: MapDockMetrics.controlSize)
            .contentShape(.circle)
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}
