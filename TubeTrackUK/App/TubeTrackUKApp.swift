import SwiftUI

@main
struct TubeTrackUKApp: App {
    @State private var appState = TubeAppState()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}

