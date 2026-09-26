import MapKit
import SwiftUI

struct FavouriteStopButton: View {
    @Environment(TubeAppState.self) private var appState
    let stop: FavouriteStop
    var body: some View {
        let saved = appState.favourites.contains(stop)
        Button(saved ? "Remove from favourites" : "Add to favourites", systemImage: saved ? "star.fill" : "star") {
            appState.favourites.toggle(stop)
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("\(saved ? "Remove" : "Save") \(stop.name)\(saved ? " from favourites" : " to favourites")")
        .accessibilityValue(saved ? "Saved" : "Not saved")
    }
}

struct RiverPierSymbol: View {
    var selected = false
    var expanded = true
    var compactDiameter: CGFloat = 11
    var body: some View {
        let showsIcon = expanded || selected
        ZStack {
            Circle()
                .fill(selected ? Color.blue : Color(.systemBackground))
                .overlay { Circle().stroke(Color.blue, lineWidth: selected ? 2.5 : (compactDiameter < 8 && !showsIcon ? 1.25 : 2)) }
            if showsIcon {
                Image(systemName: "ferry.fill")
                    .font(.system(size: selected ? 16 : 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.blue)
            }
        }
        .frame(width: showsIcon ? (selected ? 34 : 26) : compactDiameter,
               height: showsIcon ? (selected ? 34 : 26) : compactDiameter)
    }
}

struct RiverStatusRows: View {
    @Environment(TubeAppState.self) private var appState
    let lineIds: [String]?
    var body: some View {
        Section("River Bus service status") {
            if appState.river.statuses.isEmpty {
                Text("Service status unavailable").foregroundStyle(.secondary)
            }
            ForEach(appState.river.statuses.filter { lineIds == nil || lineIds!.contains($0.id) }) { status in
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.name).font(.headline)
                    if status.entries.isEmpty { Text("Service status unavailable").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(Array(status.entries.enumerated()), id: \.offset) { _, entry in
                        Text(entry.reason ?? entry.description).font(.subheadline)
                    }
                }
            }
            if appState.river.statusStale || appState.isOffline || Date.now.timeIntervalSince(appState.river.statusUpdatedAt ?? .distantPast) > 120 {
                Text("Service status may be out of date").foregroundStyle(.secondary)
            }
        }
    }
}

struct RiverPierCard: View {
    @Environment(TubeAppState.self) private var appState
    @State private var departuresHeight: CGFloat = 160
    let pier: RiverPier
    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                StopDetailHeader(stop: .pier(pier), closeHint: "Closes pier details") {
                    appState.river.clearSelection()
                } directions: {
                    StopDirectionsButton(name: pier.name, latitude: pier.latitude,
                                         longitude: pier.longitude, walking: true)
                }
                Text(pier.lineIds.map { appState.river.network.lineName($0) }.joined(separator: " · "))
                    .font(.appCaption(.semibold)).foregroundStyle(.secondary)
                Divider()
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(alignment: .leading, spacing: 8) {
                        let board = appState.river.selectedBoard
                        let departures = board.map {
                            RiverDepartureBoard.departures(in: $0, pierID: pier.id,
                                lineID: appState.river.selectedLineId, at: timeline.date)
                        } ?? []
                        if departures.isEmpty {
                            if board == nil && appState.river.error == nil && !appState.isOffline {
                                ProgressView("Loading departures…")
                            } else if !appState.isOffline,
                                      board?.validUntil(lineId: appState.river.selectedLineId).map({ $0 < timeline.date }) == true {
                                Text("Waiting for fresh departures…").font(.appSubheadline()).foregroundStyle(.secondary)
                            } else {
                                Text(appState.isOffline ? "Live departures unavailable offline"
                                    : appState.river.error != nil ? "Live departures temporarily unavailable" : "No live departures reported")
                                    .font(.appSubheadline()).foregroundStyle(.secondary)
                            }
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(Array(Set(departures.map(\.lineId))).sorted(), id: \.self) { lineID in
                                        RiverDepartureGroupView(
                                            pier: pier, lineID: lineID,
                                            departures: departures.filter { $0.lineId == lineID },
                                            date: timeline.date
                                        )
                                    }
                                }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                    departuresHeight = $0
                                }
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: min(departuresHeight, 280))
                        }

                    }
                }
                if appState.mapPresentationMode == .beck && !appState.river.anchors.contains(where: { $0.id == pier.id }) {
                    Text("This pier is available on Apple Maps when online.").font(.appCaption()).foregroundStyle(.secondary)
                }
                ForEach(appState.river.statuses.filter { pier.lineIds.contains($0.id) }) { status in
                    ForEach(Array(status.entries.filter { $0.severity != 10 && $0.severity != 18 }.enumerated()), id: \.offset) { _, entry in
                        Label("\(status.name): \(entry.reason ?? entry.description)", systemImage: "exclamationmark.triangle")
                            .font(.appCaption()).lineLimit(3)
                    }
                }
                CardUpdateFooter(updatedAt: appState.river.selectedBoard?.updatedAt, isOffline: appState.isOffline,
                    isStale: appState.river.selectedBoard?.stale == true || appState.river.error != nil,
                    staleAfter: 90, validUntil: appState.river.selectedBoard?.validUntil(lineId: appState.river.selectedLineId))
            }
        }
    }

}

private struct RiverDepartureGroupView: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(StationBoardActivityController.self) private var boardActivity: StationBoardActivityController?
    @State private var isExpanded = false
    let pier: RiverPier
    let lineID: String
    let departures: [RiverPrediction]
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(.blue).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(appState.river.network.lineName(lineID)).font(.appSubheadline(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                if let controller = boardActivity, controller.areActivitiesEnabled {
                    let isTracking = controller.isTracking(hubID: pier.id, lineIDRaw: lineID, direction: "All departures")
                    DepartureTrackButton(isTracking: isTracking,
                                         boardName: "\(appState.river.network.lineName(lineID)) at \(pier.name)") {
                        Task {
                            if isTracking { await controller.end(reason: .userEnded) }
                            else if !appState.isOffline, let board = appState.river.selectedBoard {
                                await controller.start(pier: pier, lineID: lineID, board: board,
                                                       statuses: appState.river.statuses)
                            }
                        }
                    }
                    .disabled(!isTracking && (appState.isOffline || appState.river.selectedBoard?.stale == true))
                }
            }
            ForEach(isExpanded ? departures : Array(departures.prefix(3))) { departure in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(departure.destinationName ?? "Destination unavailable")
                        .font(.appSubheadline()).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    let seconds = departure.expectedArrival.timeIntervalSince(date)
                    Text(seconds < 60 ? "Due" : "\(Int(ceil(seconds / 60))) min")
                        .font(.appSubheadline(.semibold)).monospacedDigit().fixedSize()
                        .foregroundStyle(Color.departureAccent)
                }
                .accessibilityElement(children: .combine)
            }
            if departures.count > 3 {
                Button(isExpanded ? "Show fewer departures" : "View all departures",
                       systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    isExpanded.toggle()
                }
                .font(.appCaption(.semibold))
                .frame(minHeight: 44)
                .buttonStyle(.plain)
                .foregroundStyle(Color.departureAccent)
            }
        }
    }
}

struct RiverBoatCard: View {
    @Environment(TubeAppState.self) private var appState
    let boat: EstimatedRiverBoat
    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(appState.river.network.lineName(boat.lineId)) · Estimated boat", systemImage: "ferry.fill").font(.appHeadline())
                    Spacer()
                    Button("Close boat", systemImage: "xmark.circle.fill") { appState.river.clearSelection() }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(alignment: .leading, spacing: 4) {
                        if boat.progress(at: timeline.date) != nil {
                            Text("Next: \(appState.river.network.pier(boat.nextPierId)?.name ?? "Unknown pier")")
                            Text("Predicted arrival \(boat.expectedArrival.formatted(date: .omitted, time: .shortened))").font(.appSubheadline())
                        } else { Text("Position estimate has expired").foregroundStyle(.secondary) }
                    }
                }
                Text("Estimated from pier predictions · Not GPS").font(.appCaption()).foregroundStyle(.secondary)
                CardUpdateFooter(updatedAt: boat.observedAt, isOffline: appState.isOffline,
                    isStale: appState.river.fleetError != nil, staleAfter: 90,
                    validUntil: min(boat.expectedArrival, boat.expiresAt ?? boat.observedAt.addingTimeInterval(90)))
            }
        }
    }
}

struct TransportStopSearchSheet: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let graph: TubeGraph
    let onStation: (TubeStation) -> Void
    let onPier: (RiverPier) -> Void
    var onTerminal: (CableCarTerminal?) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty && !appState.favourites.stops.isEmpty {
                    Section("Favourites") {
                        ForEach(appState.favourites.stops) { stop in
                            HStack {
                                Button { open(stop) } label: {
                                    Label { Text(stop.name) } icon: {
                                        if stop.kind == .cableCarTerminal { Image("CableCarIcon") }
                                        else { Image(systemName: stop.symbol) }
                                    }
                                }
                                Spacer()
                                FavouriteStopButton(stop: stop)
                            }
                        }
                    }
                }
                Section("Cable Car") {
                    if query.isEmpty || ["cable car", "london cable car", "ifs", "emirates"].contains(where: { $0.localizedStandardContains(query) }) {
                        Button { onTerminal(nil); dismiss() } label: { Label("London Cable Car", image: "CableCarIcon") }
                    }
                    ForEach(appState.cableCar.network.terminals.filter { query.isEmpty || $0.name.localizedStandardContains(query) || "cable car".localizedStandardContains(query) }) { terminal in
                        HStack {
                            Button { onTerminal(terminal); dismiss() } label: { Label(terminal.name, image: "CableCarIcon") }
                            Spacer()
                            FavouriteStopButton(stop: .terminal(terminal))
                        }
                    }
                }
                Section("Piers") {
                    ForEach(appState.river.network.piers.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.sorted { $0.name < $1.name }) { pier in
                        HStack {
                            Button { onPier(pier); dismiss() } label: { Label(pier.name, systemImage: "ferry.fill") }
                            Spacer()
                            FavouriteStopButton(stop: .pier(pier))
                        }
                    }
                }
                Section("Stations") {
                    ForEach(StationSearch.suggestions(in: graph, matching: query, limit: query.isEmpty ? nil : 40)) { station in
                        HStack {
                            Button { onStation(station); dismiss() } label: { Label(station.name, systemImage: "tram.fill") }
                            Spacer()
                            FavouriteStopButton(stop: .station(station))
                        }
                    }
                }
            }
            .buttonStyle(.borderless)
            .searchable(text: $query, prompt: "Station, pier or cable car")
            .navigationTitle("Find a stop")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func open(_ stop: FavouriteStop) {
        if stop.kind == .cableCarTerminal, let terminal = appState.cableCar.network.terminals.first(where: { $0.id == stop.stopId }) { onTerminal(terminal); dismiss() }
        else if stop.kind == .pier, let pier = appState.river.network.pier(stop.stopId) { onPier(pier); dismiss() }
        else if stop.kind == .station, let station = graph.stations.first(where: { ($0.hubID ?? $0.id) == stop.stopId }) {
            onStation(station); dismiss()
        }
    }
}
