import SwiftUI

@main
struct TubeTrackUKApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scheduledJourneys = ScheduledJourneyStore()
    @State private var appState = TubeAppState()
    @State private var backgroundImageStore = AppBackgroundImageStore()
    @State private var gameHighScoreStore = TubeGameHighScoreStore()
    @State private var gameCenter = GameCenterService()
    @State private var locationProvider = UserLocationProvider()
    // Falls back to no registration when the build carries no push secret, in
    // which case a tracked board still works — it just stops updating once the
    // app goes away.
    @State private var boardActivity = StationBoardActivityController(
        registrar: LiveActivityPushRegistrar()
    )

    init() {
        AppTypography.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .environment(scheduledJourneys)
                .task { await scheduledJourneys.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await scheduledJourneys.refresh() } }
                }
                .environment(backgroundImageStore)
                .environment(gameHighScoreStore)
                .environment(gameCenter)
                .environment(locationProvider)
                .environment(boardActivity)
                .font(.appBody())
                .preferredColorScheme(appState.preferredColorScheme)
        }
    }
}
