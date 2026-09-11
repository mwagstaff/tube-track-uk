import CoreLocation
import SwiftUI

enum MapDockMetrics {
    static let controlSize: CGFloat = 44
    static let columnSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 12

    static func contentColumnWidth(for availableWidth: CGFloat) -> CGFloat {
        max(
            0,
            availableWidth
                - (horizontalPadding * 2)
                - columnSpacing
                - controlSize
        )
    }
}

struct MapActionNotice: Equatable, Identifiable, Sendable {
    let id = UUID()
    let message: String
    let symbol: String
}

struct MapHeaderControls: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(AppBackgroundImageStore.self) private var backgroundImageStore
    @Environment(TubeGameHighScoreStore.self) private var gameHighScoreStore
    @State private var presentedDestination: MapHeaderDestination?

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 8) {
            Button {
                presentedDestination = .backgroundPhoto
            } label: {
                Image(systemName: "photo")
            }
            .mapDockButtonStyle()
            .disabled(backgroundImageStore.selectedImage == nil)
            .accessibilityLabel("View background photo")
            .accessibilityValue(backgroundImageAccessibilityValue)
            .accessibilityHint("Opens the current photo full screen")

            Button {
                guard let graph = appState.graph else { return }
                appState.setGameActive(true)
                presentedDestination = .trackMan(graph)
            } label: {
                TrackManGlyph()
            }
            .mapDockButtonStyle()
            .disabled(appState.graph == nil)
            .accessibilityLabel("Play Track-Man")
            .accessibilityValue(trackManAccessibilityValue)
            .accessibilityHint("Opens a 60-second game on the Tube network")

            Menu {
                Picker("Appearance", selection: $state.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Label(mode.actionTitle, systemImage: mode.symbol)
                            .tag(mode)
                    }
                }
            } label: {
                Image(systemName: appState.appearanceMode.symbol)
            }
            .mapDockButtonStyle()
            .accessibilityLabel("Appearance")
            .accessibilityValue(appState.appearanceMode.title)
        }
        .fullScreenCover(item: $presentedDestination, onDismiss: {
            appState.setGameActive(false)
        }) { destination in
            switch destination {
            case .backgroundPhoto:
                AppBackgroundImageViewer()
            case let .trackMan(graph):
                TubeGameScreen(graph: graph)
            }
        }
    }

    private var trackManAccessibilityValue: String {
        let score = gameHighScoreStore.bestScore
        return "Local best, \(score) point\(score == 1 ? "" : "s")"
    }

    private var backgroundImageAccessibilityValue: String {
        guard let attribution = backgroundImageStore.selectedImageAttribution else {
            return backgroundImageStore.selectedImage == nil
                ? "No photo available"
                : "Current background photograph"
        }
        return "Image courtesy of \(attribution.artistName), \(attribution.sourceName)"
    }
}

private enum MapHeaderDestination: Identifiable {
    case backgroundPhoto
    case trackMan(TubeGraph)

    var id: Int {
        switch self {
        case .backgroundPhoto: 0
        case .trackMan: 1
        }
    }
}

struct MapActionButtons: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stationSearchPresented = false
    @State private var pendingStationSelection: TubeStation?
    @State private var locationProvider = UserLocationProvider()
    @State private var locationErrorPresented = false
    @State private var resetRingExpanded = false
    let showsReset: Bool
    let onReset: () -> Void
    let onFocusUserLocation: (CLLocation) -> Void
    let onAction: (MapActionNotice) -> Void

    init(
        showsReset: Bool = false,
        onReset: @escaping () -> Void = {},
        onFocusUserLocation: @escaping (CLLocation) -> Void = { _ in },
        onAction: @escaping (MapActionNotice) -> Void = { _ in }
    ) {
        self.showsReset = showsReset
        self.onReset = onReset
        self.onFocusUserLocation = onFocusUserLocation
        self.onAction = onAction
    }

    private var destinationMode: MapPresentationMode {
        appState.mapPresentationMode.toggled
    }

    private var worksScope: MapDisruptionHighlightScope? {
        appState.disruptionHighlightScope
    }

    private var worksSelected: Bool {
        worksScope != nil
    }

    private var worksTint: Color {
        switch worksScope {
        case .major: .red
        case .minor: .orange
        case .all, nil: .clear
        }
    }

    private var nextWorksScope: MapDisruptionHighlightScope? {
        guard let worksScope else { return .all }
        return worksScope.next
    }

    private var nextWorksNoticeMessage: String {
        nextWorksScope?.noticeMessage ?? "Showing all lines"
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                let destinationMode = appState.mobileCoverageMode.next
                onAction(MapActionNotice(
                    message: destinationMode.noticeMessage,
                    symbol: "cellularbars"
                ))
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    appState.cycleMobileCoverageMode()
                }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "cellularbars")
                        .font(.appSubheadline(.semibold))

                    if appState.mobileCoverageMode == .undergroundOnly {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(mobileCoverageSelected ? mobileCoverageTint : .primary)
                            .frame(width: 13, height: 13)
                            .background(
                                mobileCoverageSelected ? Color.white : Color(.systemBackground),
                                in: .circle
                            )
                            .offset(x: 4, y: 4)
                    }
                }
                .foregroundStyle(mobileCoverageSelected ? .white : .primary)
            }
            .mapDockButtonStyle(
                isSelected: mobileCoverageSelected,
                tint: mobileCoverageTint
            )
            .disabled(appState.mobileCoverage == nil)
            .accessibilityLabel("Cycle mobile coverage")
            .accessibilityValue(appState.mobileCoverageMode.title)
            .accessibilityHint(appState.mobileCoverageMode.next.noticeMessage)
            .accessibilityAddTraits(mobileCoverageSelected ? .isSelected : [])

            Button {
                onAction(MapActionNotice(
                    message: nextWorksNoticeMessage,
                    symbol: AppTab.works.symbol
                ))
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    appState.setDisruptionHighlightScope(nextWorksScope)
                }
            } label: {
                Image(systemName: AppTab.works.symbol)
                    .font(.appSubheadline(.semibold))
                    .foregroundStyle(worksSelected ? .white : .primary)
            }
            .mapDockButtonStyle(
                isSelected: worksSelected && worksScope != .all,
                tint: worksTint
            )
            .background {
                if worksScope == .all {
                    Circle()
                        .fill(allDisruptionsFill)
                }
            }
            .accessibilityLabel("Cycle disruption highlights")
            .accessibilityValue(worksAccessibilityValue)
            .accessibilityHint(nextWorksNoticeMessage)
            .accessibilityAddTraits(worksSelected ? .isSelected : [])

            Button {
                onAction(MapActionNotice(
                    message: "Zooming to current location",
                    symbol: "location.fill"
                ))
                locationProvider.requestLocation()
                if locationProvider.needsSettingsPermission
                    || locationProvider.errorMessage != nil {
                    locationErrorPresented = true
                }
            } label: {
                if locationProvider.isRequesting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.tubeBlue)
                } else {
                    Image(systemName: "location.fill")
                        .foregroundStyle(Color.tubeBlue)
                }
            }
            .mapDockButtonStyle()
            .disabled(appState.graph == nil || locationProvider.isRequesting)
            .accessibilityLabel(
                locationProvider.isRequesting
                    ? "Finding current location"
                    : "Zoom to current location"
            )

            Button {
                onAction(MapActionNotice(
                    message: destinationMode.toggleNoticeMessage,
                    symbol: destinationMode.symbol
                ))
                appState.mapPresentationMode = destinationMode
            } label: {
                Image(systemName: appState.mapPresentationMode.switchActionSymbol)
            }
            .mapDockButtonStyle()
            .accessibilityLabel(appState.mapPresentationMode.switchActionTitle)
            .requiresNetwork(appState.isOffline && destinationMode == .realWorld)

            Button {
                let showsLiveTrains = !appState.showLiveTrains
                onAction(MapActionNotice(
                    message: showsLiveTrains ? "Showing live trains" : "Hiding live trains",
                    symbol: showsLiveTrains ? "tram.fill" : "tram"
                ))
                appState.setLiveTrains(showsLiveTrains)
            } label: {
                if appState.isLoadingLiveTrains && !appState.isOffline {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.blue)
                } else {
                    Image(systemName: appState.showLiveTrains ? "tram.fill" : "tram")
                        .foregroundStyle(appState.showLiveTrains ? .blue : .primary)
                }
            }
            .mapDockButtonStyle()
            .accessibilityLabel(
                appState.isLoadingLiveTrains && !appState.isOffline
                    ? "Loading live trains"
                    : appState.showLiveTrains ? "Hide live trains" : "Show live trains"
            )
            .requiresNetwork(appState.isOffline)

            Button {
                onAction(MapActionNotice(
                    message: "Opening station search",
                    symbol: "magnifyingglass"
                ))
                stationSearchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .mapDockButtonStyle()
            .disabled(appState.graph == nil)
            .accessibilityLabel("Station search")

            if showsReset {
                Button {
                    onAction(MapActionNotice(
                        message: "Resetting zoom",
                        symbol: "scope"
                    ))
                    onReset()
                } label: {
                    Image(systemName: "scope")
                        .foregroundStyle(.white)
                }
                .mapDockButtonStyle(isSelected: true, tint: Color.tubeBlue)
                .shadow(color: Color.tubeBlue.opacity(0.28), radius: 8)
                .overlay {
                    Circle()
                        .stroke(Color.tubeBlue.opacity(resetRingOpacity), lineWidth: 2)
                        .scaleEffect(resetRingScale)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("Reset map view")
                .accessibilityHint("Returns to the opening zoom and restores closest station")
                .transition(.scale(scale: 0.78).combined(with: .opacity))
                .onAppear(perform: emphasizeResetButton)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: showsReset)
        .onChange(of: locationProvider.location) { _, location in
            guard let location else { return }
            onFocusUserLocation(location)
        }
        .onChange(of: locationProvider.authorizationStatus) { _, status in
            if status == .denied || status == .restricted {
                locationErrorPresented = true
            }
        }
        .onChange(of: locationProvider.errorMessage) { _, errorMessage in
            if errorMessage != nil {
                locationErrorPresented = true
            }
        }
        .alert("Location unavailable", isPresented: $locationErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(locationErrorMessage)
        }
        .sheet(isPresented: $stationSearchPresented, onDismiss: {
            guard let station = pendingStationSelection else { return }
            pendingStationSelection = nil
            appState.select(station: station)
        }) {
            Group {
                if let graph = appState.graph {
                    StationSearchSheet(
                        graph: graph,
                        selectedStationID: appState.selectedStationID
                    ) { station in
                        pendingStationSelection = station
                    }
                } else {
                    ContentUnavailableView(
                        "Network unavailable",
                        systemImage: "tram.fill",
                        description: Text("Loading network data...")
                    )
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var locationErrorMessage: String {
        if locationProvider.needsSettingsPermission {
            return "Allow location access in Settings to zoom to your position."
        }
        return locationProvider.errorMessage
            ?? "Your current location could not be determined. Please try again."
    }

    private var mobileCoverageSelected: Bool {
        appState.mobileCoverageMode.isActive
    }

    private var mobileCoverageTint: Color {
        switch appState.mobileCoverageMode {
        case .off, .allUsable: .green
        case .undergroundOnly: .indigo
        }
    }

    private var allDisruptionsFill: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .red, location: 0),
                .init(color: .red, location: 0.5),
                .init(color: .orange, location: 0.5),
                .init(color: .orange, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var worksAccessibilityValue: String {
        switch worksScope {
        case .all: "All disruptions"
        case .major: "Major disruptions only"
        case .minor: "Minor disruptions only"
        case nil: "No disruption filter"
        }
    }

    private var resetRingOpacity: Double {
        if reduceMotion { return 0.5 }
        return resetRingExpanded ? 0 : 0.65
    }

    private var resetRingScale: CGFloat {
        if reduceMotion { return 1.08 }
        return resetRingExpanded ? 1.42 : 0.86
    }

    private func emphasizeResetButton() {
        resetRingExpanded = false
        guard !reduceMotion else { return }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.48).delay(0.06)) {
            resetRingExpanded = true
        }
    }
}

struct MobileCoverageLegend: View {
    @Environment(TubeAppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "cellularbars")
                    .foregroundStyle(.green)
                Text(appState.mobileCoverageMode.title)
                    .font(.appCaption(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let publishedAt = appState.mobileCoverage?.publishedAt {
                    Text(Self.formattedPublication(publishedAt))
                        .font(.appCaption2())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                legendItem("Coverage", style: .available)
                legendItem("No coverage", style: .unavailable)
            }
            HStack(spacing: 12) {
                legendItem("Unknown", style: .unknown)
                legendItem("Station only", style: .stationOnly)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Mobile coverage legend. Coloured lines have coverage. Grey lines have no verified coverage. Dashed lines are unknown. Signal badges mean station-only coverage."
        )
    }

    private func legendItem(_ title: String, style: LegendStyle) -> some View {
        HStack(spacing: 6) {
            legendMark(style)
                .frame(width: 24, height: 12)
            Text(title)
                .font(.appCaption2(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func legendMark(_ style: LegendStyle) -> some View {
        switch style {
        case .available:
            Capsule().fill(Color.tubeBlue)
        case .unavailable:
            Capsule().fill(Color.secondary.opacity(0.36))
        case .unknown:
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    path,
                    with: .color(Color.orange.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 3, dash: [4, 3])
                )
            }
        case .stationOnly:
            Image(systemName: "cellularbars")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Color.green, in: .circle)
        }
    }

    private static func formattedPublication(_ value: String) -> String {
        let components = value.split(separator: "-")
        guard components.count >= 2,
              let month = Int(components[1]),
              (1...12).contains(month) else { return value }
        let symbols = Calendar.current.monthSymbols
        return "As of \(symbols[month - 1].prefix(3)) \(components[0])"
    }

    private enum LegendStyle {
        case available
        case unavailable
        case unknown
        case stationOnly
    }
}

private extension View {
    func mapDockButtonStyle(
        isSelected: Bool = false,
        tint: Color = .clear
    ) -> some View {
        self
            .font(.appHeadline())
            .frame(width: MapDockMetrics.controlSize, height: MapDockMetrics.controlSize)
            .contentShape(.circle)
            .buttonStyle(.plain)
            .glassEffect(
                isSelected
                    ? .regular.tint(tint).interactive()
                    : .regular.interactive(),
                in: .circle
            )
    }
}
