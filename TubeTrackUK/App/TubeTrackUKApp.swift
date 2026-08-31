import SwiftUI

@main
struct TubeTrackUKApp: App {
    @State private var appState = TubeAppState()
    @State private var backgroundImageStore = AppBackgroundImageStore()

    init() {
        AppTypography.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .environment(backgroundImageStore)
                .font(.appBody())
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}
