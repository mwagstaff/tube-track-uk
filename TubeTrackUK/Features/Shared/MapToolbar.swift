import SwiftUI

struct MapToolbar: View {
    @Environment(TubeAppState.self) private var appState
    let onReset: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                TubeTrackMark(compact: true)

                Spacer(minLength: 4)

                Button {
                    withAnimation(.easeInOut(duration: 0.55)) {
                        appState.disruptionDisplayMode = appState.disruptionDisplayMode == .normal ? .issues : .normal
                    }
                } label: {
                    Label("Issues", systemImage: appState.disruptionDisplayMode == .issues ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(appState.disruptionDisplayMode == .issues ? .red : .primary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(appState.disruptionDisplayMode == .issues ? "Show normal map" : "Highlight issues")

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
}

