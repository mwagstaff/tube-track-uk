import CoreLocation
import SwiftUI

struct NearMeScreen: View {
    private static let stationBatchSize = 3

    @Environment(TubeAppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var locationProvider = UserLocationProvider()
    @State private var visibleStationCount = Self.stationBatchSize

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
                } else {
                    ProgressView("Finding nearby stations…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Near Me")
            .toolbar {
                if locationProvider.location != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            refresh()
                        }
                    }
                }
            }
        }
        .task {
            locationProvider.requestLocation()
        }
        .task(id: initialStationTaskID) {
            visibleStationCount = Self.stationBatchSize
            let stations = nearbyStations.map(\.station)
            guard !stations.isEmpty else { return }
            await appState.refreshNearbyArrivals(for: stations)
        }
    }

    private var allNearbyStations: [NearbyStation] {
        guard let graph = appState.graph, let location = locationProvider.location else { return [] }
        return NearbyStationFinder.stationsByDistance(to: location, in: graph.stations)
    }

    private var nearbyStations: [NearbyStation] {
        Array(allNearbyStations.prefix(visibleStationCount))
    }

    private var initialStationTaskID: String {
        allNearbyStations.prefix(Self.stationBatchSize).map(\.id).joined(separator: ":")
    }

    private var hasMoreStations: Bool {
        visibleStationCount < allNearbyStations.count
    }

    private func stationList(graph: TubeGraph) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Closest stations")
                        .font(.title3.weight(.bold))
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 3)

                ForEach(Array(nearbyStations.enumerated()), id: \.element.id) { index, nearby in
                    NearbyStationCard(
                        nearbyStation: nearby,
                        rank: index + 1,
                        graph: graph
                    )
                }

                if hasMoreStations {
                    LoadMoreStationsTrigger {
                        revealNextBatch()
                    }
                    .id(visibleStationCount)
                } else {
                    Text("Distances are straight-line estimates from your current location.")
                        .font(.caption2)
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
            await appState.refreshNearbyArrivals(for: nearbyStations.map(\.station))
        }
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
        let stations = nearbyStations.map(\.station)
        guard !stations.isEmpty else { return }
        Task {
            await appState.refreshNearbyArrivals(for: stations)
        }
    }

    private func revealNextBatch() {
        guard hasMoreStations else { return }
        let previousCount = visibleStationCount
        let nextCount = min(
            previousCount + Self.stationBatchSize,
            allNearbyStations.count
        )
        let newlyVisibleStations = allNearbyStations[previousCount..<nextCount].map(\.station)

        withAnimation(.smooth(duration: 0.3)) {
            visibleStationCount = nextCount
        }
        Task {
            await appState.refreshNearbyArrivals(for: newlyVisibleStations)
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
        .font(.caption.weight(.medium))
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
    @State private var presentedLineID: TubeLineID?

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

    private var departureGroups: [NearbyDepartureGroup] {
        NearbyDepartureGroup.groups(from: arrivals)
    }

    private var distanceText: String {
        NearbyDistanceFormatter.string(from: nearbyStation.distance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showOnMap()
            } label: {
                stationHeader
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(station.name), \(distanceText) away")
            .accessibilityHint("Shows this station on the Real World map")

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(lineIDs) { lineID in
                        StationLineStatusPill(
                            lineID: lineID,
                            condition: LineServiceCondition.condition(
                                for: appState.statuses.first { $0.id == lineID }
                            ),
                            action: { presentedLineID = lineID }
                        )
                    }
                }
                .padding(.horizontal, 15)
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 14)

            Divider()
                .padding(.horizontal, 15)

            departuresContent
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $presentedLineID) { lineID in
            LineStatusDetailSheet(lineID: lineID)
        }
    }

    private var stationHeader: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 27, height: 27)
                .background(Color.tubeBlue, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(station.name)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                Text(distanceText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 8)

            Label("View on map", systemImage: "map.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.tubeBlue)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.secondary.opacity(0.65))
        }
        .contentShape(.rect)
        .padding(.horizontal, 15)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var departuresContent: some View {
        if appState.nearbyArrivalsLoadingStationIDs.contains(station.id), arrivals.isEmpty {
            HStack(spacing: 9) {
                ProgressView()
                Text("Loading live departures…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let error = appState.nearbyArrivalsErrorsByStationID[station.id], arrivals.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Departures unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            .padding(.vertical, 3)
        } else if departureGroups.isEmpty {
            Text("No imminent departures reported.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 13) {
                ForEach(Array(departureGroups.enumerated()), id: \.element.id) { index, group in
                    NearbyDepartureGroupView(group: group)
                    if index < departureGroups.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func showOnMap() {
        appState.clearMapSelection()
        appState.select(station: station)
        appState.selectedTab = .realWorld
    }
}

private struct StationLineStatusPill: View {
    let lineID: TubeLineID
    let condition: LineServiceCondition
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.tubeLine(lineID))
                    .frame(width: 10, height: 10)
                    .overlay {
                        if lineID == .northern || lineID == .jubilee {
                            Circle().stroke(.white.opacity(0.8), lineWidth: 1)
                        }
                    }
                Text(lineID.displayName)
                    .lineLimit(1)

                switch condition {
                case .majorDisruption:
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                case .minorDisruption:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                case .good, .updating:
                    EmptyView()
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemGroupedBackground), in: .capsule)
            .overlay {
                Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lineID.displayName), \(condition.accessibilityDescription)")
        .accessibilityHint("Shows full service status")
    }
}

private struct LineStatusDetailSheet: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let lineID: TubeLineID

    private var lineStatus: TfLLineStatus? {
        appState.statuses.first { $0.id == lineID }
    }

    private var entries: [TfLStatusEntry] {
        lineStatus?.lineStatuses ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LineBadge(lineID: lineID)

                    if entries.isEmpty {
                        ContentUnavailableView(
                            "Status updating",
                            systemImage: "arrow.clockwise",
                            description: Text("Service details for this line aren’t available yet.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            statusEntry(entry)
                            if index < entries.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("\(lineID.displayName) status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func statusEntry(_ entry: TfLStatusEntry) -> some View {
        let presentation = presentation(for: entry)
        return VStack(alignment: .leading, spacing: 10) {
            Label(entry.statusSeverityDescription, systemImage: presentation.symbol)
                .font(.headline)
                .foregroundStyle(presentation.color)

            if let reason = entry.reason, !reason.isEmpty {
                Text(reason)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(entry.isGoodService ? "TfL is reporting normal service." : "No additional details were reported.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func presentation(for entry: TfLStatusEntry) -> (symbol: String, color: Color) {
        if entry.isOvernightClosure {
            return ("moon.zzz.fill", .indigo)
        }
        if entry.isActionableIssue, entry.statusSeverity != 9 {
            return ("exclamationmark.octagon.fill", .red)
        }
        if entry.isActionableIssue {
            return ("exclamationmark.triangle.fill", .yellow)
        }
        return ("checkmark.circle.fill", .green)
    }
}

private struct NearbyDepartureGroupView: View {
    let group: NearbyDepartureGroup
    @State private var isExpanded = false

    private var visibleArrivals: ArraySlice<TfLArrivalPrediction> {
        isExpanded ? group.arrivals[...] : group.arrivals.prefix(3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.tubeLine(group.lineID))
                    .frame(width: 9, height: 9)
                Text(group.lineID.displayName)
                    .font(.subheadline.weight(.bold))
                Text(group.direction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 8) {
                ForEach(visibleArrivals) { arrival in
                    departureRow(arrival)
                }
            }

            if group.arrivals.count > 3 {
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(isExpanded ? "Show fewer departures" : "View all departures")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.tubeBlue)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }
        }
    }

    private func departureRow(_ arrival: TfLArrivalPrediction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination(for: arrival))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let platform = platformDetail(for: arrival) {
                    Text(platform)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            Text(departureTime(for: arrival))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.tubeBlue)
        }
        .accessibilityElement(children: .combine)
    }

    private func destination(for arrival: TfLArrivalPrediction) -> String {
        (arrival.destinationName ?? arrival.towards ?? "Check platform")
            .replacingOccurrences(of: " Underground Station", with: "")
    }

    private func platformDetail(for arrival: TfLArrivalPrediction) -> String? {
        guard let platform = arrival.platformName, !platform.isEmpty else { return nil }
        let cardinalDirections = ["Northbound", "Southbound", "Eastbound", "Westbound"]
        if cardinalDirections.contains(where: { platform.localizedCaseInsensitiveContains($0) }),
           !platform.localizedCaseInsensitiveContains("platform") {
            return nil
        }
        return platform
    }

    private func departureTime(for arrival: TfLArrivalPrediction) -> String {
        let seconds: Int?
        if let expectedArrival = arrival.expectedArrival {
            seconds = max(0, Int(expectedArrival.timeIntervalSinceNow))
        } else {
            seconds = arrival.timeToStation
        }
        guard let seconds else { return "—" }
        if seconds < 45 { return "Due" }
        return "\(max(1, seconds / 60)) min"
    }
}
