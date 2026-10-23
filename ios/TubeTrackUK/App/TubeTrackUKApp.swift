import SwiftUI

@main
struct TubeTrackUKApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var trackedJourneys = TrackedJourneyStore()
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
        LiveActivityDiagnostics.record("app_launch", ["appVersion": AppInstall.appVersion,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString])
        AppTypography.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .environment(scheduledJourneys)
                .environment(trackedJourneys)
                .task { await trackedJourneys.run() }
                .task { await scheduledJourneys.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    LiveActivityDiagnostics.record("scene_phase", ["phase": String(describing: phase)])
                    DepartureActivityBridge.recordDiagnosticSnapshot(reason: "scene_phase")
                    if phase == .active { trackedJourneys.resumeLocation(); Task { await scheduledJourneys.refresh(); await trackedJourneys.refresh() } }
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
