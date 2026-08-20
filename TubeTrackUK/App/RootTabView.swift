import SwiftUI
import UIKit

struct RootTabView: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var state = appState

        TabView(selection: $state.selectedTab) {
            Group {
                if appState.selectedTab == .map {
                    BeckMapScreen()
                } else {
                    Color.clear
                }
            }
            .tabItem { Label(AppTab.map.title, systemImage: AppTab.map.symbol) }
            .tag(AppTab.map)

            Group {
                if appState.selectedTab == .realWorld {
                    RealWorldMapScreen()
                } else {
                    Color.clear
                }
            }
            .tabItem { Label(AppTab.realWorld.title, systemImage: AppTab.realWorld.symbol) }
            .tag(AppTab.realWorld)

            WorksScreen()
                .tabItem { Label(AppTab.works.title, systemImage: AppTab.works.symbol) }
                .tag(AppTab.works)

            AboutScreen()
                .tabItem { Label(AppTab.about.title, systemImage: AppTab.about.symbol) }
                .tag(AppTab.about)
        }
        .tint(colorScheme == .dark ? .white : .tubeBlue)
        .toolbarBackground(colorScheme == .dark ? Color.black : Color(.systemBackground), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .task {
            await appState.start()
        }
        .onChange(of: scenePhase) { _, phase in
            appState.setActive(phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            appState.handleMemoryWarning()
        }
    }
}
