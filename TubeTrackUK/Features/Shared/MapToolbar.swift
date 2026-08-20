import SwiftUI

struct MapToolbar: View {
    @Environment(TubeAppState.self) private var appState
    let onReset: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                Spacer(minLength: 4)

                Menu {
                    Toggle(isOn: highlightingBinding) {
                        Label("Highlight disruptions", systemImage: "eye")
                    }

                    Divider()

                    Section("Highlight") {
                        ForEach(DisruptionCategory.allCases) { category in
                            Toggle(isOn: categoryBinding(for: category)) {
                                Label(category.title, systemImage: category.symbol)
                            }
                        }
                    }
                } label: {
                    Image(systemName: appState.disruptionDisplayMode == .issues ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(appState.disruptionDisplayMode == .issues ? .red : .primary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .menuActionDismissBehavior(.disabled)
                .accessibilityLabel("Disruption highlight filters")
                .accessibilityValue(highlightAccessibilityValue)

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
    }

    private var highlightingBinding: Binding<Bool> {
        Binding(
            get: { appState.disruptionDisplayMode == .issues },
            set: { appState.disruptionDisplayMode = $0 ? .issues : .normal }
        )
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
