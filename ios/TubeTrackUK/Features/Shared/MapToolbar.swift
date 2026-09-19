import CoreLocation
import SwiftUI

enum MapDockMetrics {
    static let controlSize: CGFloat = 44
    static let horizontalPadding: CGFloat = 12
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
    let showsLabels: Bool
    let showsReset: Bool
    let onReset: () -> Void
    let onFocusUserLocation: (CLLocation) -> Void
    let onAction: (MapActionNotice) -> Void
    let onActionCompleted: () -> Void

    init(
        showsLabels: Bool = false,
        showsReset: Bool = false,
        onReset: @escaping () -> Void = {},
        onFocusUserLocation: @escaping (CLLocation) -> Void = { _ in },
        onAction: @escaping (MapActionNotice) -> Void = { _ in },
        onActionCompleted: @escaping () -> Void = {}
    ) {
        self.showsLabels = showsLabels
        self.showsReset = showsReset
        self.onReset = onReset
        self.onFocusUserLocation = onFocusUserLocation
        self.onAction = onAction
        self.onActionCompleted = onActionCompleted
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

    private var mobileCoverageActionTitle: String {
        switch appState.mobileCoverageMode.next {
        case .off: "Hide mobile coverage"
        case .allUsable: "Show mobile coverage"
        case .undergroundOnly: "Show underground coverage"
        }
    }

    private var worksActionTitle: String {
        switch nextWorksScope {
        case .all: "Highlight all disruptions"
        case .major: "Show major disruptions"
        case .minor: "Show minor delays"
        case nil: "Clear disruption highlights"
        }
    }

    var body: some View {
        VStack(spacing: showsLabels ? 6 : 8) {
            Button {
                let destinationMode = appState.mobileCoverageMode.next
                onAction(MapActionNotice(
                    message: destinationMode.noticeMessage,
                    symbol: "cellularbars"
                ))
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    appState.cycleMobileCoverageMode()
                }
                onActionCompleted()
            } label: {
                mapActionLabel(mobileCoverageActionTitle) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "cellularbars")
                            .font(.appSubheadline(.semibold))

                        if appState.mobileCoverageMode == .undergroundOnly {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 7, weight: .black))
                                .foregroundStyle(
                                    mobileCoverageSelected ? mobileCoverageTint : .primary
                                )
                                .frame(width: 13, height: 13)
                                .background(
                                    mobileCoverageSelected
                                        ? Color.white : Color(.systemBackground),
                                    in: .circle
                                )
                                .offset(x: 4, y: 4)
                        }
                    }
                    .foregroundStyle(mobileCoverageSelected ? .white : .primary)
                }
            }
            .mapActionButtonStyle(
                showsLabel: showsLabels,
                isSelected: mobileCoverageSelected,
                tint: mobileCoverageTint
            )
            .disabled(appState.mobileCoverage == nil)
            .accessibilityLabel(mobileCoverageActionTitle)
            .accessibilityValue(appState.mobileCoverageMode.title)
            .accessibilityHint(appState.mobileCoverageMode.next.noticeMessage)
            .accessibilityAddTraits(mobileCoverageSelected ? .isSelected : [])

            Button {
                onAction(MapActionNotice(
                    message: nextWorksNoticeMessage,
                    symbol: "wrench.and.screwdriver"
                ))
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    appState.setDisruptionHighlightScope(nextWorksScope)
                }
                onActionCompleted()
            } label: {
                mapActionLabel(worksActionTitle) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.appSubheadline(.semibold))
                        .foregroundStyle(worksSelected ? .white : .primary)
                }
            }
            .mapActionButtonStyle(
                showsLabel: showsLabels,
                isSelected: worksSelected && (showsLabels || worksScope != .all),
                tint: worksScope == .all && showsLabels ? .orange : worksTint
            )
            .background {
                if worksScope == .all, !showsLabels {
                    Circle()
                        .fill(allDisruptionsFill)
                }
            }
            .accessibilityLabel(worksActionTitle)
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
                mapActionLabel(
                    locationProvider.isRequesting
                        ? "Finding current location" : "Current location"
                ) {
                    if locationProvider.isRequesting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.tubeBlue)
                    } else {
                        Image(systemName: "location.fill")
                            .foregroundStyle(Color.tubeBlue)
                    }
                }
            }
            .mapActionButtonStyle(showsLabel: showsLabels)
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
                onActionCompleted()
            } label: {
                mapActionLabel(
                    destinationMode == .realWorld ? "Geographic map" : "Tube map"
                ) {
                    Image(systemName: appState.mapPresentationMode.switchActionSymbol)
                }
            }
            .mapActionButtonStyle(showsLabel: showsLabels)
            .accessibilityLabel(appState.mapPresentationMode.switchActionTitle)
            .requiresNetwork(appState.isOffline && destinationMode == .realWorld)

            Button {
                let showsLiveTrains = !appState.showLiveTrains
                onAction(MapActionNotice(
                    message: showsLiveTrains ? "Showing live trains" : "Hiding live trains",
                    symbol: showsLiveTrains ? "tram.fill" : "tram"
                ))
                appState.setLiveTrains(showsLiveTrains)
                onActionCompleted()
            } label: {
                mapActionLabel(
                    appState.showLiveTrains ? "Hide live trains" : "Show live trains"
                ) {
                    if appState.isLoadingLiveTrains && !appState.isOffline {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.blue)
                    } else {
                        Image(systemName: appState.showLiveTrains ? "tram.fill" : "tram")
                            .foregroundStyle(appState.showLiveTrains ? .white : .primary)
                    }
                }
            }
            .mapActionButtonStyle(
                showsLabel: showsLabels,
                isSelected: appState.showLiveTrains,
                tint: .blue
            )
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
                mapActionLabel("Search stations") {
                    Image(systemName: "magnifyingglass")
                }
            }
            .mapActionButtonStyle(showsLabel: showsLabels)
            .disabled(appState.graph == nil)
            .accessibilityLabel("Station search")

            if showsReset {
                Button {
                    onAction(MapActionNotice(
                        message: "Resetting zoom",
                        symbol: "scope"
                    ))
                    onReset()
                    onActionCompleted()
                } label: {
                    mapActionLabel("Reset map") {
                        Image(systemName: "scope")
                            .foregroundStyle(.white)
                    }
                }
                .mapActionButtonStyle(
                    showsLabel: showsLabels,
                    isSelected: true,
                    tint: Color.tubeBlue
                )
                .shadow(color: Color.tubeBlue.opacity(0.28), radius: 8)
                .overlay {
                    if !showsLabels {
                        Circle()
                            .stroke(Color.tubeBlue.opacity(resetRingOpacity), lineWidth: 2)
                            .scaleEffect(resetRingScale)
                            .allowsHitTesting(false)
                    }
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
            onActionCompleted()
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
            if let station = pendingStationSelection {
                pendingStationSelection = nil
                appState.select(station: station)
            }
            onActionCompleted()
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

    @ViewBuilder
    private func mapActionLabel<Icon: View>(
        _ title: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        if showsLabels {
            HStack(spacing: 10) {
                icon()
                    .frame(width: 22)
                Text(title)
                    .font(.appSubheadline(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .contentShape(.rect(cornerRadius: 12))
        } else {
            icon()
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

struct MapControlDock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsActions = false

    let showsClosestStation: Bool
    let closestStationOpacity: Double
    let showsReset: Bool
    let onReset: () -> Void
    let onFocusUserLocation: (CLLocation) -> Void
    let onAction: (MapActionNotice) -> Void

    var body: some View {
        Group {
            if showsActions {
                actionsPanel
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing))
                    )
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        setActionsVisible(true)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.appHeadline(.bold))
                            .frame(
                                width: MapDockMetrics.controlSize,
                                height: MapDockMetrics.controlSize
                            )
                            .glassEffect(.regular.interactive(), in: .circle)
                            .frame(width: 60, height: 60)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Map options")
                    .accessibilityHint("Shows labelled map controls")
                    .zIndex(2)

                    if showsClosestStation {
                        ClosestStationMapSection()
                            .opacity(closestStationOpacity)
                            .allowsHitTesting(closestStationOpacity > 0.12)
                            .accessibilityHidden(closestStationOpacity <= 0.12)
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(
            reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.26),
            value: showsActions
        )
    }

    private var actionsPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Map options")
                        .font(.appHeadline(.bold))
                    Text("Choose what to show on the map")
                        .font(.appCaption())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    setActionsVisible(false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.appSubheadline(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .background(.primary.opacity(0.07), in: .circle)
                .accessibilityLabel("Close map options")
            }

            MapActionButtons(
                showsLabels: true,
                showsReset: showsReset,
                onReset: onReset,
                onFocusUserLocation: onFocusUserLocation,
                onAction: onAction,
                onActionCompleted: {
                    setActionsVisible(false)
                }
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }

    private func setActionsVisible(_ isVisible: Bool) {
        if reduceMotion {
            showsActions = isVisible
        } else {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.26)) {
                showsActions = isVisible
            }
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

private struct MapActionButtonStyleModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let showsLabel: Bool
    let isSelected: Bool
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if showsLabel {
            content
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            isSelected
                                ? tint
                                : Color.primary.opacity(0.055)
                        )
                }
                .opacity(isEnabled ? 1 : 0.45)
        } else {
            content.mapDockButtonStyle(isSelected: isSelected, tint: tint)
        }
    }
}

private extension View {
    func mapActionButtonStyle(
        showsLabel: Bool,
        isSelected: Bool = false,
        tint: Color = .clear
    ) -> some View {
        modifier(MapActionButtonStyleModifier(
            showsLabel: showsLabel,
            isSelected: isSelected,
            tint: tint
        ))
    }

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
