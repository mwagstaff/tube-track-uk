import SwiftUI

@main
struct TubeTrackUKApp: App {
    @State private var appState = TubeAppState()
    @State private var backgroundImageStore = AppBackgroundImageStore()
    @State private var gameHighScoreStore = TubeGameHighScoreStore()
    @State private var gameCenter = GameCenterService()

    init() {
        AppTypography.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .environment(backgroundImageStore)
                .environment(gameHighScoreStore)
                .environment(gameCenter)
                .font(.appBody())
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}
