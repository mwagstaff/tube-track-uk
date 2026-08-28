import CoreLocation
import SwiftUI

struct ClosestStationMapSection: View {
    @Environment(TubeAppState.self) private var appState
    @State private var locationProvider = UserLocationProvider()

    let onHide: () -> Void

    private var closestStation: NearbyStation? {
        guard let graph = appState.graph,
              let location = locationProvider.location else { return nil }
        return NearbyStationFinder.nearestStations(
            to: location,
            in: graph.stations,
            limit: 1
        ).first
    }

    var body: some View {
        Group {
            if let graph = appState.graph, let closestStation {
                ClosestStationMapPanel(
                    nearbyStation: closestStation,
                    graph: graph,
                    onHide: onHide
                )
                .id(closestStation.id)
            } else {
                ClosestStationAvailabilityPanel(
                    isLoading: appState.isLoadingGraph || locationProvider.isRequesting,
                    needsPermission: locationProvider.needsSettingsPermission,
                    errorMessage: locationProvider.errorMessage,
                    onRetry: locationProvider.requestLocation,
                    onOpenNearMe: { appState.selectedTab = .nearMe },
                    onHide: onHide
                )
            }
        }
        .task {
            locationProvider.requestLocation()
        }
        .task(id: closestStation?.id) {
            guard let station = closestStation?.station else { return }
            await appState.refreshNearbyArrivals(for: [station])
        }
        .task(id: closestStation?.id) {
            guard let station = closestStation?.station else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await appState.refreshNearbyArrivals(for: [station])
            }
        }
    }
}

private struct ClosestStationMapPanel: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var requestedLineID: TubeLineID?

    let nearbyStation: NearbyStation
    let graph: TubeGraph
    let onHide: () -> Void

    private var station: TubeStation { nearbyStation.station }

    private var lineIDs: [TubeLineID] {
        graph.lineIDs(at: station)
    }

    private var arrivals: [TfLArrivalPrediction] {
        appState.nearbyArrivalsByStationID[station.id] ?? []
    }

    private var selectedLineID: TubeLineID? {
        StationDepartureSelection.resolved(
            current: requestedLineID,
            lineIDs: lineIDs,
            arrivals: arrivals
        )
    }

    private var selectedGroups: [StationDepartureGroup] {
        CompactStationDeparturePolicy.groups(
            from: arrivals,
            for: selectedLineID
        )
    }

    private var selectionInputID: String {
        let lines = lineIDs.map(\.rawValue).joined(separator: ":")
        let arrivalLines = Set(arrivals.map(\.lineId)).sorted().joined(separator: ":")
        return "\(lines):\(arrivalLines)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if lineIDs.count > 1 {
                linePicker
                    .padding(.top, 8)
            }

            Divider()
                .padding(.top, 8)

            TimelineView(.periodic(from: .now, by: 15)) { context in
                departures(now: context.date)
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: selectionInputID) {
            reconcileSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.tubeBlue, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text("Closest station")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(station.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(NearbyDistanceFormatter.string(from: nearbyStation.distance))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(action: onHide) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Hide closest station")
            .accessibilityHint("Moves this section to a button at the top of the map")
        }
    }

    private var linePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(lineIDs) { lineID in
                    StationLinePill(
                        lineID: lineID,
                        selected: selectedLineID == lineID,
                        action: { select(lineID) }
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func departures(now: Date) -> some View {
        if appState.nearbyArrivalsLoadingStationIDs.contains(station.id), arrivals.isEmpty {
            compactMessage("Loading live departures…", systemImage: nil, showsProgress: true)
        } else if let error = appState.nearbyArrivalsErrorsByStationID[station.id], arrivals.isEmpty {
            compactMessage(error, systemImage: "wifi.exclamationmark")
        } else if selectedGroups.isEmpty {
            compactMessage("No imminent departures reported.", systemImage: "clock")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(selectedGroups.enumerated()), id: \.element.id) { index, group in
                    CompactStationDepartureGroupView(group: group, now: now)
                    if index < selectedGroups.count - 1 {
                        Divider()
                    }
                }
            }
            .id(selectedLineID)
        }
    }

    private func compactMessage(
        _ message: String,
        systemImage: String?,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private func select(_ lineID: TubeLineID) {
        guard lineID != selectedLineID else { return }
        if reduceMotion {
            requestedLineID = lineID
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                requestedLineID = lineID
            }
        }
    }

    private func reconcileSelection() {
        if let requestedLineID, lineIDs.contains(requestedLineID) {
            return
        }
        requestedLineID = StationDepartureSelection.resolved(
            current: nil,
            lineIDs: lineIDs,
            arrivals: arrivals
        )
    }
}

private struct CompactStationDepartureGroupView: View {
    let group: StationDepartureGroup
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TubeLineDot(lineID: group.lineID, size: 8)
                Text(group.lineID.displayName)
                    .fontWeight(.semibold)
                Text(group.direction)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(group.arrivals, id: \.departureIdentity) { arrival in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(StationDepartureMetadata.destinationLabel(for: arrival))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(StationDepartureMetadata.departureTime(for: arrival, now: now))
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(Color.departureAccent)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct ClosestStationAvailabilityPanel: View {
    let isLoading: Bool
    let needsPermission: Bool
    let errorMessage: String?
    let onRetry: () -> Void
    let onOpenNearMe: () -> Void
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: needsPermission ? "location.slash.fill" : "location.fill")
                    .foregroundStyle(needsPermission ? .secondary : Color.tubeBlue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Closest station")
                    .font(.caption.weight(.semibold))
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if needsPermission {
                Button("Open") { onOpenNearMe() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            } else if errorMessage != nil {
                Button("Retry") { onRetry() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }

            Button(action: onHide) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Hide closest station")
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var statusMessage: String {
        if needsPermission {
            return "Location access is needed."
        }
        if let errorMessage {
            return errorMessage
        }
        return "Finding your nearest station…"
    }
}

enum CompactStationDeparturePolicy {
    static let maximumInformationLines = 6
    static let maximumDeparturesPerGroup = 2

    static func groups(
        from arrivals: [TfLArrivalPrediction],
        for selectedLineID: TubeLineID?,
        maximumInformationLines: Int = maximumInformationLines
    ) -> [StationDepartureGroup] {
        guard maximumInformationLines >= 2 else { return [] }
        let availableGroups = StationDepartureGroup.groups(
            from: arrivals,
            for: selectedLineID
        )
        let groupCount = min(
            availableGroups.count,
            maximumInformationLines / 2
        )
        guard groupCount > 0 else { return [] }

        let chosenGroups = Array(availableGroups.prefix(groupCount))
        var departureCounts = chosenGroups.map { $0.arrivals.isEmpty ? 0 : 1 }
        var usedLines = groupCount + departureCounts.reduce(0, +)

        while usedLines < maximumInformationLines {
            var addedDeparture = false
            for index in chosenGroups.indices where usedLines < maximumInformationLines {
                let availableCount = min(
                    maximumDeparturesPerGroup,
                    chosenGroups[index].arrivals.count
                )
                guard departureCounts[index] < availableCount else { continue }
                departureCounts[index] += 1
                usedLines += 1
                addedDeparture = true
            }
            if !addedDeparture { break }
        }

        return chosenGroups.indices.map { index in
            let group = chosenGroups[index]
            return StationDepartureGroup(
                lineID: group.lineID,
                direction: group.direction,
                arrivals: Array(group.arrivals.prefix(departureCounts[index]))
            )
        }
    }
}
