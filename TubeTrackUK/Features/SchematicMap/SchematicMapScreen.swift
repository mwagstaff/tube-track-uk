import SwiftUI

struct SchematicMapScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("statusPanelExpanded") private var statusExpanded = false
    @State private var resetToken = 0
    private let routesOnlyDebugEnabled = ProcessInfo.processInfo.arguments.contains("--schematic-routes-only")

    var body: some View {
        ZStack {
            background

            if let graph = appState.graph {
                SchematicMapView(graph: graph, resetToken: resetToken)
                    .ignoresSafeArea(edges: .top)
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
            if !routesOnlyDebugEnabled {
                MapToolbar { resetToken += 1 }
            }
        }
        .overlay(alignment: .bottom) {
            if !routesOnlyDebugEnabled {
                bottomOverlay
            }
        }
    }

    private var background: some View {
        Group {
            if colorScheme == .dark {
                SchematicMapPalette.darkBackground
            } else {
                ZStack {
                    Color(.systemGroupedBackground)
                    LinearGradient(
                        colors: [.blue.opacity(0.07), .clear, .cyan.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
        .ignoresSafeArea()
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
        .animation(.spring(duration: 0.4, bounce: 0.12), value: appState.showLiveTrains)
        .animation(.spring(duration: 0.4, bounce: 0.12), value: appState.selectedStationID)
        .safeAreaPadding(.bottom, 4)
    }
}
