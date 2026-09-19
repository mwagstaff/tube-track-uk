import SwiftUI
import UIKit

enum AppStartupTiming {
    /// Total first-launch presentation budget, including the fade from interstitial image to the Map.
    static let maximumInterstitialDuration: TimeInterval = 1.8
    static let interstitialFadeDuration: TimeInterval = 0.5
    static let revealDeadline: TimeInterval =
        maximumInterstitialDuration - interstitialFadeDuration
}

enum AppStartupPresentation {
    // SwiftUI runs onAppear after the view has already been presented. Keep an
    // opaque interstitial in the initial value graph so the Map can never be
    // the first rendered frame while the photograph is decoded off-main.
    static let isInitiallyPresented = true
    static let initialOpacity: Double = 1
    static let initiallyShowsChrome = true
}

struct RootTabView: View {
    @Environment(GameCenterService.self) private var gameCenter
    @Environment(TubeAppState.self) private var appState
    @Environment(AppBackgroundImageStore.self) private var backgroundImageStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backgroundRevealPresented =
        AppStartupPresentation.isInitiallyPresented
    @State private var backgroundRevealOpacity =
        AppStartupPresentation.initialOpacity
    @State private var backgroundRevealTask: Task<Void, Never>?
    @State private var startupDeadlineTask: Task<Void, Never>?
    @State private var appStartupCompleted = false
    @State private var backgroundRevealShowsStartupChrome =
        AppStartupPresentation.initiallyShowsChrome
    @State private var closestStationPanelHidden = false
    @State private var mapNavigationActive = false
    @State private var mapNavigation = MapTabNavigationState()
    @State private var profileShowsImageBackground = false

    var body: some View {
        @Bindable var state = appState

        ZStack {
            VStack(spacing: 0) {
                if appState.isOffline,
                   appState.selectedTab != .map,
                   appState.selectedTab != .journeys {
                    OfflineStatusBanner(
                        updatedAt: offlineBannerShowsWorks
                            ? appState.worksUpdatedAt : appState.statusUpdatedAt,
                        isWorks: offlineBannerShowsWorks
                    )
                }

                TabView(selection: $state.selectedTab) {
                    Group {
                        if appState.selectedTab == .map {
                            NavigationStack {
                                UnifiedMapScreen(
                                    closestStationPanelHidden: $closestStationPanelHidden,
                                    mapNavigationActive: $mapNavigationActive,
                                    onShowDisruptions: {
                                        mapNavigation.showDisruptions()
                                    }
                                )
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(
                                    isPresented: $mapNavigation.showsDisruptions
                                ) {
                                    MapDisruptionsScreen()
                                        .toolbar(.visible, for: .navigationBar)
                                }
                            }
                        } else {
                            Color.clear
                        }
                    }
                    .tabItem { Label(AppTab.map.title, systemImage: AppTab.map.symbol) }
                    .tag(AppTab.map)

                    NearMeScreen()
                        .tabItem { Label(AppTab.nearMe.title, systemImage: AppTab.nearMe.symbol) }
                        .tag(AppTab.nearMe)

                    JourneysScreen()
                        .tabItem { Label(AppTab.journeys.title, systemImage: AppTab.journeys.symbol) }
                        .tag(AppTab.journeys)

                    ProfileScreen(showsImageBackground: $profileShowsImageBackground)
                        .tabItem { Label(AppTab.profile.title, systemImage: AppTab.profile.symbol) }
                        .tag(AppTab.profile)
                }
                .tint(colorScheme == .dark ? .white : .tubeBlue)
                .toolbarBackground(Color(uiColor: tabBarBackgroundColor), for: .tabBar)
                .toolbarBackground(tabBarBackgroundIsTransparent ? .hidden : .visible, for: .tabBar)
                .background {
                    TabBarBackgroundConfigurator(
                        backgroundColor: tabBarBackgroundColor,
                        backgroundIsTransparent: tabBarBackgroundIsTransparent,
                        screenFurnitureVisible: !mapNavigationActive,
                        reduceMotion: reduceMotion,
                        onMapTabSelected: {
                            mapNavigation.handleTabSelection(.map)
                        }
                    )
                    .frame(width: 0, height: 0)
                }
            }

            if backgroundRevealPresented {
                ZStack {
                    AppBackgroundImage(
                        scrimOpacity: 0.12,
                        placeholder: .launch
                    )

                    if backgroundRevealShowsStartupChrome {
                        AppStartupBackgroundChrome()
                    }
                }
                    .opacity(backgroundRevealOpacity)
                    .allowsHitTesting(!appStartupCompleted)
                    .zIndex(10)
            }
        }
        .sheet(isPresented: $state.showsWorks) {
            WorksScreen()
        }
        .onAppear {
            revealBackgroundIfNeeded()
        }
        .task {
            revealBackgroundIfNeeded()
            scheduleStartupDeadline()
            await appState.start()
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
        .onChange(of: appState.isOffline, initial: true) { _, offline in
            gameCenter.setOffline(offline)
        }
        .onChange(of: backgroundImageStore.mapRevealGeneration) {
            revealBackgroundIfNeeded()
        }
        .onChange(of: backgroundImageStore.imageLoadGeneration) {
            if appStartupCompleted {
                // The startup deadline may beat image decoding on a slower
                // device. Do not cover an already visible map when it finishes.
                _ = backgroundImageStore.consumeMapReveal()
            } else {
                revealBackgroundIfNeeded()
            }
        }
        .onChange(of: appState.selectedTab) {
            if appState.selectedTab == .map {
                mapNavigation.handleTabSelection(.map)
            } else {
                mapNavigationActive = false
            }
            revealBackgroundIfNeeded()
        }
        .onChange(of: appState.mapPresentationMode) {
            revealBackgroundIfNeeded()
        }
        .onChange(of: appState.stationSelectionGeneration) {
            guard appState.selectedStationID != nil else { return }
            closestStationPanelHidden = true
        }
        .onDisappear {
            backgroundRevealTask?.cancel()
            startupDeadlineTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            appState.handleMemoryWarning()
        }
    }

    private var offlineBannerShowsWorks: Bool {
        !appState.isViewingLiveStatus
    }

    private var tabBarBackgroundColor: UIColor {
        if tabBarBackgroundIsTransparent {
            return .clear
        }

        return switch appState.selectedTab {
        case .journeys:
            .systemGroupedBackground
        case .profile:
            .secondarySystemBackground
        case .map, .nearMe:
            .systemBackground
        }
    }

    private var tabBarBackgroundIsTransparent: Bool {
        appState.selectedTab == .map
            || appState.selectedTab == .journeys
            || (appState.selectedTab == .profile && profileShowsImageBackground)
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
            backgroundRevealPresented = true
            backgroundRevealOpacity = 1
        }

        if appStartupCompleted {
            dismissBackgroundReveal()
        }
    }

    private func dismissBackgroundReveal() {
        guard backgroundRevealPresented else { return }

        backgroundRevealTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            if reduceMotion {
                backgroundRevealOpacity = 0
                backgroundRevealPresented = false
            } else {
                let duration = backgroundRevealShowsStartupChrome
                    ? AppStartupTiming.interstitialFadeDuration
                    : 1.5
                withAnimation(.easeInOut(duration: duration)) {
                    backgroundRevealOpacity = 0
                }
                do {
                    try await Task.sleep(for: .seconds(duration))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                backgroundRevealPresented = false
            }
        }
    }

    private func scheduleStartupDeadline() {
        startupDeadlineTask?.cancel()
        startupDeadlineTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(AppStartupTiming.revealDeadline))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            completeAppStartup()
        }
    }

    private func completeAppStartup() {
        guard !appStartupCompleted else { return }
        appStartupCompleted = true
        startupDeadlineTask?.cancel()
        startupDeadlineTask = nil
        dismissBackgroundReveal()
    }
}

struct MapTabNavigationState: Equatable {
    var showsDisruptions = false

    mutating func showDisruptions() {
        showsDisruptions = true
    }

    mutating func returnToMap() {
        showsDisruptions = false
    }

    mutating func handleTabSelection(_ tab: AppTab) {
        guard tab == .map else { return }
        returnToMap()
    }
}

private struct AppStartupBackgroundChrome: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Text("TubeTrack UK")
                    .font(.appHeadline(.semibold))
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
                .font(.appCaption(.medium))
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
    let backgroundColor: UIColor
    let backgroundIsTransparent: Bool
    let screenFurnitureVisible: Bool
    let reduceMotion: Bool
    let onMapTabSelected: () -> Void

    func makeUIViewController(context: Context) -> TabBarAppearanceController {
        TabBarAppearanceController()
    }

    func updateUIViewController(
        _ viewController: TabBarAppearanceController,
        context: Context
    ) {
        viewController.backgroundColor = backgroundColor
        viewController.backgroundIsTransparent = backgroundIsTransparent
        viewController.screenFurnitureVisible = screenFurnitureVisible
        viewController.reduceMotion = reduceMotion
        viewController.onMapTabSelected = onMapTabSelected
        viewController.applyAppearanceWhenAttached()
    }

    static func dismantleUIViewController(
        _ viewController: TabBarAppearanceController,
        coordinator: Void
    ) {
        viewController.stopObservingSelection()
    }
}

@MainActor
private final class TabBarAppearanceController: UIViewController, UITabBarControllerDelegate {
    var backgroundColor = UIColor.systemBackground
    var backgroundIsTransparent = false
    var screenFurnitureVisible = true
    var reduceMotion = false
    var onMapTabSelected: () -> Void = {}
    private weak var configuredTabBar: UITabBar?
    private weak var observedTabBarController: UITabBarController?
    private var forwardingDelegate: (any UITabBarControllerDelegate)?

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
        guard let resolvedTabBarController = tabBarController
            ?? view.window?.rootViewController?.descendantTabBarController else {
            return
        }
        let tabBar = resolvedTabBarController.tabBar
        observeSelection(on: resolvedTabBarController)

        let appearance = UITabBarAppearance()
        if backgroundIsTransparent {
            appearance.configureWithTransparentBackground()
        } else {
            appearance.configureWithOpaqueBackground()
        }
        appearance.backgroundColor = backgroundColor
        if backgroundIsTransparent {
            appearance.shadowColor = .clear
        }

        tabBar.isTranslucent = backgroundIsTransparent
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance

        let targetAlpha = screenFurnitureVisible ? 1.0 : 0.0
        tabBar.isUserInteractionEnabled = screenFurnitureVisible

        guard configuredTabBar === tabBar,
              abs(tabBar.alpha - targetAlpha) > 0.001,
              !reduceMotion else {
            tabBar.alpha = targetAlpha
            configuredTabBar = tabBar
            return
        }

        UIView.animate(
            withDuration: screenFurnitureVisible ? 0.2 : 0.12,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            tabBar.alpha = targetAlpha
        }
        configuredTabBar = tabBar
    }

    func stopObservingSelection() {
        guard let observedTabBarController,
              observedTabBarController.delegate === self else { return }
        observedTabBarController.delegate = forwardingDelegate
        self.observedTabBarController = nil
        forwardingDelegate = nil
    }

    private func observeSelection(on tabBarController: UITabBarController) {
        guard observedTabBarController !== tabBarController
                || tabBarController.delegate !== self else { return }

        stopObservingSelection()
        forwardingDelegate = tabBarController.delegate
        observedTabBarController = tabBarController
        tabBarController.delegate = self
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        shouldSelect viewController: UIViewController
    ) -> Bool {
        forwardingDelegate?.tabBarController?(
            tabBarController,
            shouldSelect: viewController
        ) ?? true
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelect viewController: UIViewController
    ) {
        forwardingDelegate?.tabBarController?(
            tabBarController,
            didSelect: viewController
        )
        guard tabBarController.viewControllers?.first === viewController else { return }
        onMapTabSelected()
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
