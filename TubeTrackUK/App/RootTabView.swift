import SwiftUI
import UIKit

struct RootTabView: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(AppBackgroundImageStore.self) private var backgroundImageStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backgroundRevealOpacity: Double = 0
    @State private var backgroundRevealTask: Task<Void, Never>?
    @State private var appStartupCompleted = false
    @State private var backgroundRevealShowsStartupChrome = false
    @State private var closestStationPanelHidden = false

    var body: some View {
        @Bindable var state = appState

        ZStack {
            TabView(selection: $state.selectedTab) {
                Group {
                    if appState.selectedTab == .map {
                        UnifiedMapScreen(
                            closestStationPanelHidden: $closestStationPanelHidden
                        )
                    } else {
                        Color.clear
                    }
                }
                .tabItem { Label(AppTab.map.title, systemImage: AppTab.map.symbol) }
                .tag(AppTab.map)

                NearMeScreen()
                    .tabItem { Label(AppTab.nearMe.title, systemImage: AppTab.nearMe.symbol) }
                    .tag(AppTab.nearMe)

                WorksScreen()
                    .tabItem { Label(AppTab.works.title, systemImage: AppTab.works.symbol) }
                    .tag(AppTab.works)

                ProfileScreen()
                    .tabItem { Label(AppTab.profile.title, systemImage: AppTab.profile.symbol) }
                    .tag(AppTab.profile)
            }
            .tint(colorScheme == .dark ? .white : .tubeBlue)
            .toolbarBackground(colorScheme == .dark ? Color.black : Color(.systemBackground), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .background {
                TabBarBackgroundConfigurator(
                    usesSolidBackground: appState.selectedTab == .profile
                )
                .frame(width: 0, height: 0)
            }

            if backgroundRevealOpacity > 0 {
                ZStack {
                    AppBackgroundImage(scrimOpacity: 0.12)

                    if backgroundRevealShowsStartupChrome {
                        AppStartupBackgroundChrome()
                    }
                }
                    .opacity(backgroundRevealOpacity)
                    .allowsHitTesting(!appStartupCompleted)
                    .zIndex(10)
            }
        }
        .onAppear {
            revealBackgroundIfNeeded()
        }
        .task {
            revealBackgroundIfNeeded()
            await appState.start()
            appStartupCompleted = true
            dismissBackgroundReveal()
        }
        .onChange(of: scenePhase) { _, phase in
            appState.setActive(phase == .active)
            if phase == .active {
                if backgroundImageStore.appDidBecomeActive() {
                    appState.selectedTab = .map
                    appState.mapPresentationMode = .beck
                }
                revealBackgroundIfNeeded()
            } else if phase == .background {
                backgroundImageStore.appDidBecomeInactive()
            }
        }
        .onChange(of: backgroundImageStore.mapRevealGeneration) {
            revealBackgroundIfNeeded()
        }
        .onChange(of: appState.selectedTab) {
            revealBackgroundIfNeeded()
        }
        .onChange(of: appState.mapPresentationMode) {
            revealBackgroundIfNeeded()
        }
        .onDisappear {
            backgroundRevealTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            appState.handleMemoryWarning()
        }
    }

    private func revealBackgroundIfNeeded() {
        guard appState.selectedTab == .map,
              appState.mapPresentationMode == .beck,
              backgroundImageStore.selectedImage != nil,
              backgroundImageStore.consumeMapReveal() else { return }

        backgroundRevealTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            backgroundRevealShowsStartupChrome = !appStartupCompleted
            backgroundRevealOpacity = 1
        }

        if appStartupCompleted {
            dismissBackgroundReveal()
        }
    }

    private func dismissBackgroundReveal() {
        guard backgroundRevealOpacity > 0 else { return }

        backgroundRevealTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  appState.selectedTab == .map,
                  appState.mapPresentationMode == .beck else { return }

            if reduceMotion {
                backgroundRevealOpacity = 0
            } else {
                withAnimation(.easeInOut(duration: 1.5)) {
                    backgroundRevealOpacity = 0
                }
            }
        }
    }
}

private struct AppStartupBackgroundChrome: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Text("TubeTrack UK")
                    .font(.headline.weight(.semibold))
                    .tracking(0.2)
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.32), in: Capsule())
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height * 0.70
                    )

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Loading...")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule())
                .position(
                    x: proxy.size.width / 2,
                    y: proxy.size.height
                        - max(proxy.safeAreaInsets.bottom + 24, 48)
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TubeTrack UK")
        .accessibilityValue("Loading")
    }
}

private struct TabBarBackgroundConfigurator: UIViewControllerRepresentable {
    let usesSolidBackground: Bool

    func makeUIViewController(context: Context) -> TabBarAppearanceController {
        TabBarAppearanceController()
    }

    func updateUIViewController(
        _ viewController: TabBarAppearanceController,
        context: Context
    ) {
        viewController.usesSolidBackground = usesSolidBackground
        viewController.applyAppearanceWhenAttached()
    }
}

@MainActor
private final class TabBarAppearanceController: UIViewController {
    var usesSolidBackground = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyAppearance()
    }

    func applyAppearanceWhenAttached() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        guard let tabBar = tabBarController?.tabBar
            ?? view.window?.rootViewController?.descendantTabBarController?.tabBar else {
            return
        }

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        if usesSolidBackground {
            appearance.backgroundColor = .secondarySystemBackground
        } else {
            appearance.backgroundColor = .systemBackground
        }

        tabBar.isTranslucent = false
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }
}

@MainActor
private extension UIViewController {
    var descendantTabBarController: UITabBarController? {
        if let tabBarController = self as? UITabBarController {
            return tabBarController
        }
        for child in children {
            if let tabBarController = child.descendantTabBarController {
                return tabBarController
            }
        }
        if let presentedViewController {
            return presentedViewController.descendantTabBarController
        }
        return nil
    }
}
