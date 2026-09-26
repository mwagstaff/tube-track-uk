import CoreLocation
import SwiftUI

struct NearMeScreen: View {
    private static let stationBatchSize = 3

    @Environment(TubeAppState.self) private var appState
    @Environment(UserLocationProvider.self) private var locationProvider
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleStationCount = Self.stationBatchSize
    @State private var visibleStationIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if appState.isLoadingGraph {
                    ProgressView("Loading the Tube network…")
                } else if let graph = appState.graph, locationProvider.location != nil {
                    stationList(graph: graph)
                } else if locationProvider.needsSettingsPermission {
                    permissionUnavailable
                } else if let errorMessage = locationProvider.errorMessage {
                    locationUnavailable(message: errorMessage)
                } else if locationProvider.isRequesting || !locationProvider.hasRequestedLocation {
                    ProgressView("Finding nearby stations…")
                } else {
                    locationUnavailable(
                        message: "We couldn’t determine your location. Please try again."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Near Me")
            .toolbar {
                if locationProvider.location != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(
                            appState.isOffline ? "Update location" : "Refresh",
                            systemImage: appState.isOffline ? "location.fill" : "arrow.clockwise"
                        ) {
                            refresh()
                        }
                        .accessibilityHint(
                            appState.isOffline
                                ? "Updates your location using your device"
                                : "Updates your location and departures"
                        )
                    }
                }
            }
        }
        .task(id: appState.selectedTab) {
            guard appState.selectedTab == .nearMe else { return }
            locationProvider.requestLocation()
        }
        .task(id: initialStationTaskID) {
            guard appState.selectedTab == .nearMe,
                  appState.isViewingLiveStatus,
                  !appState.isOffline else {
                return
            }
            visibleStationCount = Self.stationBatchSize
            visibleStationIDs.removeAll(keepingCapacity: true)
            let stations = nearbyStations.map(\.station)
            guard !stations.isEmpty else { return }
            await appState.refreshNearbyArrivals(for: stations)
        }
        .task(id: nearbyArrivalsPollingTaskID) {
            guard appState.selectedTab == .nearMe,
                  appState.isViewingLiveStatus,
                  !appState.isOffline,
                  !visibleNearbyStations.isEmpty else {
                return
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      appState.selectedTab == .nearMe,
                      appState.isViewingLiveStatus,
                      !appState.isOffline else {
                    return
                }
                await appState.refreshNearbyArrivals(
                    for: visibleNearbyStations.map(\.station)
                )
            }
        }
    }

    private var allNearbyStations: [NearbyStation] {
        guard let graph = appState.graph, let location = locationProvider.location else { return [] }
        return NearbyStationFinder.stationsByDistance(to: location, in: graph.stations)
    }

    private var nearbyStations: [NearbyStation] {
        Array(allNearbyStations.prefix(visibleStationCount))
    }

    private var visibleNearbyStations: [NearbyStation] {
        NearMeArrivalRefreshPolicy.visibleStations(
            from: nearbyStations,
            visibleStationIDs: visibleStationIDs
        )
    }

    private var initialStationTaskID: String {
        let stationIDs = allNearbyStations
            .prefix(Self.stationBatchSize)
            .map(\.id)
            .joined(separator: ":")
        return "\(appState.selectedTab.rawValue):\(stationIDs):\(appState.isViewingLiveStatus ? "live" : "planned"):\(appState.isOffline)"
    }

    private var nearbyArrivalsPollingTaskID: String {
        let stationIDs = visibleStationIDs.sorted().joined(separator: ":")
        return "\(appState.selectedTab.rawValue):\(stationIDs):\(appState.isViewingLiveStatus ? "live" : "planned"):\(appState.isOffline)"
    }

    private var hasMoreStations: Bool {
        visibleStationCount < allNearbyStations.count
    }

    private func stationList(graph: TubeGraph) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    disruptionDateControl

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Closest stations")
                            .font(.appTitle3(.bold))
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 3)

                    ForEach(Array(nearbyStations.enumerated()), id: \.element.id) { index, nearby in
                        NearbyStationCard(
                            nearbyStation: nearby,
                            rank: index + 1,
                            graph: graph
                        )
                        .id(nearby.id)
                        .onScrollVisibilityChange(threshold: 0.2) { isVisible in
                            updateStationVisibility(nearby, isVisible: isVisible)
                        }
                    }

                    if hasMoreStations {
                        LoadMoreStationsTrigger {
                            revealNextBatch()
                        }
                        .id(visibleStationCount)
                    } else {
                        Text("Distances are straight-line estimates from your current location.")
                            .font(.appCaption2())
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            .refreshable {
                locationProvider.requestLocation()
                guard !appState.isOffline else { return }
                if appState.isViewingLiveStatus {
                    await appState.refreshNearbyArrivals(
                        for: stationsForManualRefresh,
                        forceRefresh: true
                    )
                } else {
                    await appState.refreshWorks(forceRefresh: true)
                }
            }
            .task(id: appState.nearMeFocusGeneration) {
                await applyNearMeFocus(using: proxy)
            }
        }
    }

    private func applyNearMeFocus(using proxy: ScrollViewProxy) async {
        guard appState.selectedTab == .nearMe,
              let stationID = appState.nearMeFocusedStationID else { return }

        let generation = appState.nearMeFocusGeneration
        guard let stationIndex = allNearbyStations.firstIndex(where: { $0.id == stationID }) else {
            appState.consumeNearMeFocus(generation: generation)
            return
        }

        if stationIndex >= visibleStationCount {
            visibleStationCount = stationIndex + 1
            await Task.yield()
        }

        await Task.yield()
        if reduceMotion {
            proxy.scrollTo(stationID, anchor: .top)
        } else {
            withAnimation(.smooth(duration: 0.35)) {
                proxy.scrollTo(stationID, anchor: .top)
            }
        }
        appState.consumeNearMeFocus(generation: generation)
    }

    private var disruptionDateControl: some View {
        HStack(spacing: 12) {
            Label("Disruptions", systemImage: "exclamationmark.triangle.fill")
                .font(.appHeadline())
                .foregroundStyle(Color.primary)

            Spacer(minLength: 8)

            DisruptionDateMenu()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var permissionUnavailable: some View {
        ContentUnavailableView {
            Label("Location access needed", systemImage: "location.slash.fill")
        } description: {
            Text("Allow location access to find the three stations closest to you.")
        } actions: {
            Button("Open Settings") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(settingsURL)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func locationUnavailable(message: String) -> some View {
        ContentUnavailableView {
            Label("Location unavailable", systemImage: "location.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                locationProvider.requestLocation()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func refresh() {
        locationProvider.requestLocation()
        guard !appState.isOffline else { return }
        Task {
            if appState.isViewingLiveStatus {
                let stations = stationsForManualRefresh
                guard !stations.isEmpty else { return }
                await appState.refreshNearbyArrivals(
                    for: stations,
                    forceRefresh: true
                )
            } else {
                await appState.refreshWorks(forceRefresh: true)
            }
        }
    }

    private func revealNextBatch() {
        guard hasMoreStations else { return }
        let previousCount = visibleStationCount
        let nextCount = min(
            previousCount + Self.stationBatchSize,
            allNearbyStations.count
        )
        withAnimation(.smooth(duration: 0.3)) {
            visibleStationCount = nextCount
        }
    }

    private var stationsForManualRefresh: [TubeStation] {
        NearMeArrivalRefreshPolicy.stationsForManualRefresh(
            from: nearbyStations,
            visibleStationIDs: visibleStationIDs,
            fallbackCount: Self.stationBatchSize
        )
    }

    private func updateStationVisibility(
        _ nearbyStation: NearbyStation,
        isVisible: Bool
    ) {
        if isVisible {
            let inserted = visibleStationIDs.insert(nearbyStation.id).inserted
            guard inserted, appState.isViewingLiveStatus, !appState.isOffline else { return }
            Task {
                await appState.refreshNearbyArrivals(for: [nearbyStation.station])
            }
        } else {
            visibleStationIDs.remove(nearbyStation.id)
        }
    }
}

private struct LoadMoreStationsTrigger: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
            Text("Loading 3 more nearby stations…")
        }
        .font(.appCaption(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            action()
        }
    }
}

private struct NearbyStationCard: View {
    @Environment(TubeAppState.self) private var appState

    let nearbyStation: NearbyStation
    let rank: Int
    let graph: TubeGraph

    private var station: TubeStation { nearbyStation.station }

    private var lineIDs: [TubeLineID] {
        graph.lineIDs(at: station)
    }

    private var arrivals: [TfLArrivalPrediction] {
        appState.nearbyArrivalsByStationID[station.id] ?? []
    }

    private var plannedDisruptionGroups: [NearbyLineDisruptionGroup] {
        NearbyLineDisruptionGroup.groups(
            lineIDs: lineIDs,
            works: appState.plannedWorksForSelectedDate
        )
    }

    private var hasIncompleteSavedWorks: Bool {
        appState.isOffline && !appState.hasSavedWorks(for: appState.selectedDisruptionDate)
    }

    private var distanceText: String {
        NearbyDistanceFormatter.string(from: nearbyStation.distance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    showOnMap()
                } label: {
                    stationHeader
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(station.name), \(distanceText) away")
                .accessibilityHint(
                    appState.isOffline
                        ? "Shows this station in the network map"
                        : "Shows this station in the real-world map view"
                )

                StationDirectionsButton(station: station, iconOnly: true)
                    .padding(.trailing, 8)
            }

            if appState.isViewingLiveStatus {
                StationDeparturesSection(
                    lineIDs: lineIDs,
                    arrivals: arrivals,
                    statuses: appState.statuses,
                    isLoading: appState.nearbyArrivalsLoadingStationIDs.contains(station.id),
                    isOffline: appState.isOffline,
                    errorMessage: appState.nearbyArrivalsErrorsByStationID[station.id]
                )
                .id(station.id)
                .padding(.horizontal, 15)
                .padding(.bottom, 13)
            } else {
                Divider()
                    .padding(.horizontal, 15)

                plannedDisruptionsContent
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)
            }
            CardUpdateFooter(
                updatedAt: appState.isViewingLiveStatus
                    ? (appState.nearbyArrivalsSourceUpdatedAt[station.id] ?? appState.nearbyArrivalsUpdatedAtByStationID[station.id])
                    : appState.worksUpdatedAt,
                isOffline: appState.isOffline,
                isStale: appState.isViewingLiveStatus
                    ? (appState.nearbyArrivalsStaleIDs.contains(station.id) || appState.nearbyArrivalsErrorsByStationID[station.id] != nil)
                    : appState.isUsingCachedWorks,
                staleAfter: appState.isViewingLiveStatus ? 120 : 1800)
                .padding(.horizontal, 15)
                .padding(.bottom, 13)
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var stationHeader: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.appCaption(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 27, height: 27)
                .background(Color.tubeBlue, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(station.name)
                    .font(.appHeadline())
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                Text(distanceText)
                    .font(.appCaption(.medium))
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 8)

            Label("View on map", systemImage: "map.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.tubeBlue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .padding(.leading, 15)
        .padding(.trailing, 6)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var plannedDisruptionsContent: some View {
        if hasIncompleteSavedWorks && appState.plannedWorksForSelectedDate.isEmpty {
            Label("No saved planned disruptions for this date. Connect to check for updates.", systemImage: "wifi.slash")
                .font(.appSubheadline())
                .foregroundStyle(.secondary)
        } else if !appState.isOffline && appState.isRefreshingWorks && appState.engineeringWorks.isEmpty {
            HStack(spacing: 9) {
                ProgressView()
                Text("Loading planned disruptions…")
                    .font(.appSubheadline())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let error = appState.worksError,
                  appState.engineeringWorks.isEmpty, !appState.isOffline {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Planned disruptions unavailable")
                        .font(.appSubheadline(.semibold))
                    Text(error)
                        .font(.appCaption())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if hasIncompleteSavedWorks {
                    Label(
                        "This date hasn’t been fully saved. Connect to check for more work.",
                        systemImage: "wifi.slash"
                    )
                    .font(.appCaption())
                    .foregroundStyle(.secondary)
                }
                Text("Planned disruptions")
                    .font(.appCaption(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(plannedDisruptionGroups.enumerated()), id: \.element.id) { index, group in
                    NearbyLineDisruptionView(group: group)
                    if index < plannedDisruptionGroups.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func showOnMap() {
        appState.clearMapSelection()
        appState.select(station: station)
        appState.mapPresentationMode = appState.isOffline ? .beck : .realWorld
        appState.selectedTab = .map
    }
}

struct NearbyLineDisruptionGroup: Identifiable, Equatable {
    let lineID: TubeLineID
    let works: [EngineeringWork]

    var id: TubeLineID { lineID }

    static func groups(
        lineIDs: [TubeLineID],
        works: [EngineeringWork]
    ) -> [NearbyLineDisruptionGroup] {
        lineIDs.map { lineID in
            NearbyLineDisruptionGroup(
                lineID: lineID,
                works: works
                    .filter { $0.lineIDs.contains(lineID) }
                    .sorted {
                        if $0.startDate != $1.startDate {
                            return $0.startDate < $1.startDate
                        }
                        return $0.id < $1.id
                    }
            )
        }
    }
}

private struct NearbyLineDisruptionView: View {
    @Environment(TubeAppState.self) private var appState

    let group: NearbyLineDisruptionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.tubeLine(group.lineID))
                    .frame(width: 10, height: 10)
                    .overlay {
                        if group.lineID == .northern || group.lineID == .jubilee {
                            Circle().stroke(.white.opacity(0.8), lineWidth: 1)
                        }
                    }
                Text(group.lineID.displayName)
                    .font(.appSubheadline(.bold))
            }
            .accessibilityElement(children: .combine)

            if group.works.isEmpty {
                Label {
                    Text(appState.isOffline ? "No planned disruption in saved data" : "No planned disruption reported")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.appSubheadline())
            } else {
                ForEach(Array(group.works.enumerated()), id: \.element.id) { index, work in
                    Button {
                        withAnimation(.easeInOut(duration: 0.55)) {
                            appState.focus(on: work, in: .map)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(work.title)
                                .font(.appSubheadline(.bold))
                                .foregroundStyle(.orange)
                            Text(work.detail)
                                .font(.appSubheadline())
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            Label(validityLabel(for: work), systemImage: "clock.fill")
                                .font(.appCaption(.semibold))
                                .foregroundStyle(.primary)

                            Divider()

                            HStack(spacing: 6) {
                                Spacer(minLength: 0)
                                Label("View on map", systemImage: "map.fill")
                                    .font(.appCaption(.bold))
                                    .foregroundStyle(Color.tubeBlue)

                                Image(systemName: "chevron.right")
                                    .font(.appCaption2(.bold))
                                    .foregroundStyle(Color.tubeBlue)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground), in: .rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                        }
                        .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(NearbyDisruptionButtonStyle())
                    .accessibilityHint("Opens the Map and highlights the affected section")

                    if index < group.works.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func validityLabel(for work: EngineeringWork) -> String {
        let start = LondonRailDate.formatted(work.startDate, dateFormat: "EEE d MMM, HH:mm")
        let endFormat = LondonRailDate.calendar.isDate(
            work.startDate,
            inSameDayAs: work.endDate
        ) ? "HH:mm" : "EEE d MMM, HH:mm"
        let end = LondonRailDate.formatted(work.endDate, dateFormat: endFormat)
        return "\(start) – \(end)"
    }
}

private struct NearbyDisruptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
