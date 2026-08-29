import SwiftUI

@main
struct TubeTrackUKApp: App {
    @State private var appState = TubeAppState()
    @State private var backgroundImageStore = AppBackgroundImageStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .environment(backgroundImageStore)
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}
