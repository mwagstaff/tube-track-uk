import SwiftUI

struct MapToolbar: View {
    @Environment(TubeAppState.self) private var appState
    @State private var stationSearchPresented = false
    @State private var pendingStationSelection: TubeStation?
    let onReset: () -> Void

    var body: some View {
        @Bindable var state = appState

        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                Spacer(minLength: 4)

                Button {
                    stationSearchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .disabled(appState.graph == nil)
                .accessibilityLabel("Search stations")

                Menu {
                    Picker("Appearance", selection: $state.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol)
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

                Button {
                    appState.setLiveTrains(!appState.showLiveTrains)
                } label: {
                    Image(systemName: appState.showLiveTrains ? "tram.fill" : "tram")
                        .foregroundStyle(appState.showLiveTrains ? .blue : .primary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(appState.showLiveTrains ? "Hide live trains" : "Show live trains")

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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

struct DisruptionHighlightMenu: View {
    @Environment(TubeAppState.self) private var appState

    var body: some View {
        Menu {
            Section("Highlight") {
                ForEach(DisruptionCategory.allCases) { category in
                    Toggle(isOn: categoryBinding(for: category)) {
                        Label(category.title, systemImage: category.symbol)
                    }
                }
            }
        } label: {
            Image(
                systemName: appState.disruptionDisplayMode == .issues
                    ? "exclamationmark.triangle.fill"
                    : "exclamationmark.triangle"
            )
            .font(.headline)
            .foregroundStyle(
                appState.disruptionDisplayMode == .issues ? .red : .primary
            )
            .frame(width: 56, height: 56)
            .contentShape(.rect)
        } primaryAction: {
            withAnimation(.smooth(duration: 0.25)) {
                appState.toggleDisruptionHighlighting()
            }
        }
        .buttonStyle(.glass)
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel(
            appState.disruptionDisplayMode == .issues
                ? "Hide disruption highlights"
                : "Show disruption highlights"
        )
        .accessibilityValue(highlightAccessibilityValue)
        .accessibilityHint("Touch and hold for disruption category filters")
    }

    private func categoryBinding(for category: DisruptionCategory) -> Binding<Bool> {
        Binding(
            get: { appState.highlightedDisruptionCategories.contains(category) },
            set: { appState.setDisruptionCategory(category, highlighted: $0) }
        )
    }

    private var highlightAccessibilityValue: String {
        guard appState.disruptionDisplayMode == .issues else { return "Off" }
        let titles = DisruptionCategory.allCases
            .filter { appState.highlightedDisruptionCategories.contains($0) }
            .map(\.title)
        return titles.isEmpty ? "No categories selected" : titles.joined(separator: ", ")
    }
}
