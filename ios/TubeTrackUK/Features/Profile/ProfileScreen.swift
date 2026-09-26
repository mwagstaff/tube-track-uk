import SwiftUI

private enum ProfileDestination: Hashable {
    case about
    case preferences
}

struct ProfileScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(AppBackgroundImageStore.self) private var backgroundImageStore
    @Environment(TubeGameHighScoreStore.self) private var gameHighScoreStore
    @State private var presentedDestination: ProfilePresentation?
    @State private var returnsToMapAfterGame = false
    @Binding var showsImageBackground: Bool
    @State private var navigationPath: [ProfileDestination] = []

    var body: some View {
        ZStack {
            if showsImageBackground {
                AppBackgroundImage(scrimOpacity: 0.34)
            }

            NavigationStack(path: $navigationPath) {
                List {
                    Section {
                        NavigationLink(value: ProfileDestination.preferences) {
                            Label("Preferences", systemImage: "slider.horizontal.3")
                        }
                        NavigationLink(value: ProfileDestination.about) {
                            Label("About", systemImage: "info.circle")
                        }
                    }

                    Section {
                        Button {
                            guard let graph = appState.graph else { return }
                            appState.setGameActive(true)
                            presentedDestination = .trackMan(graph)
                        } label: {
                            Label {
                                Text("Play Track-Man")
                            } icon: {
                                TrackManGlyph().frame(width: 22, height: 22)
                            }
                        }
                        .disabled(appState.graph == nil)
                        .accessibilityValue("Local best, \(gameHighScoreStore.bestScore) points")

                        Button {
                            presentedDestination = .backgroundPhoto
                        } label: {
                            Label("Image of the day", systemImage: "photo")
                        }
                        .disabled(backgroundImageStore.selectedImage == nil)
                    }

                    #if DEBUG
                    Section {
                        Button {
                            backgroundImageStore.advanceToNextImage()
                        } label: {
                            Label("Show next image", systemImage: "photo.on.rectangle.angled")
                        }
                    } header: {
                        Text("Background image debugging")
                    }
                    #endif
                }
                .navigationTitle("Profile")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: ProfileDestination.self) { destination in
                    switch destination {
                    case .about:
                        AboutScreen()
                    case .preferences:
                        PreferencesScreen()
                    }
                }
            }
        }
        .fullScreenCover(item: $presentedDestination, onDismiss: {
            appState.setGameActive(false)
            if returnsToMapAfterGame {
                returnsToMapAfterGame = false
                appState.selectedTab = .map
            }
        }) { destination in
            switch destination {
            case .backgroundPhoto: AppBackgroundImageViewer()
            case let .trackMan(graph):
                TubeGameScreen(
                    graph: graph,
                    onClose: { presentedDestination = nil },
                    onReturnToMap: {
                        returnsToMapAfterGame = true
                        presentedDestination = nil
                    }
                )
            }
        }
        .onAppear {
            updateImageBackgroundState()
        }
        .onChange(of: navigationPath) {
            updateImageBackgroundState()
        }
        .onDisappear {
            showsImageBackground = false
        }
    }

    private func updateImageBackgroundState() {
        showsImageBackground = navigationPath.last == .about
    }
}

private enum ProfilePresentation: Identifiable {
    case backgroundPhoto
    case trackMan(TubeGraph)

    var id: Int {
        switch self {
        case .backgroundPhoto: 0
        case .trackMan: 1
        }
    }
}

struct PreferencesScreen: View {
    @Environment(TubeAppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        @Bindable var cable = appState.cableCar
        @Bindable var river = appState.river
        Form {
            Section {
                Toggle("Show closest station", isOn: $state.showsClosestStation)
                    .tint(.blue)
            } header: {
                Text("Map")
            } footer: {
                Text("Show the closest station when you open the map or tap Current location. Touch the map to hide the card.")
            }
            Section("Map layers") {
                Toggle("Show Cable Car", isOn: $cable.isEnabled)
                    .tint(.red)
                Toggle("Show River Bus piers", isOn: $river.isEnabled)
                    .tint(.blue)
                if river.isEnabled {
                    Toggle("Show estimated boats", isOn: $river.showsBoats)
                        .tint(.blue)
                    Picker("River Bus services", selection: $river.selectedLineId) {
                        Text("All services").tag(nil as String?)
                        ForEach(river.network.lines) { line in
                            Text(line.name).tag(Optional(line.id))
                        }
                    }
                }
            }
            Section("Appearance") {
                Picker("Appearance", selection: $state.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Preferences") {
    NavigationStack { PreferencesScreen() }
        .environment(TubeAppState())
}

#Preview("Preferences · Large text") {
    NavigationStack { PreferencesScreen() }
        .environment(TubeAppState())
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}
