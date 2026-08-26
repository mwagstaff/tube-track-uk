import SwiftUI

enum MapDockMetrics {
    static let controlSize: CGFloat = 44
}

struct MapToolbar: View {
    @Environment(TubeAppState.self) private var appState
    let onReset: () -> Void

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

    private var destinationMode: MapPresentationMode {
        appState.mapPresentationMode.toggled
    }

    var body: some View {
        HStack(spacing: 8) {
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
