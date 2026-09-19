import SwiftUI

@main
struct TubeTrackUKApp: App {
    @State private var appState = TubeAppState()
    @State private var backgroundImageStore = AppBackgroundImageStore()
    @State private var gameHighScoreStore = TubeGameHighScoreStore()
    @State private var gameCenter = GameCenterService()
    @State private var locationProvider = UserLocationProvider()

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
                .environment(locationProvider)
                .font(.appBody())
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}
