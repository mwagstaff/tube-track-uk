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
        .frame(width: 44, height: 44)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let pier: RiverPier
    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(pier.name).font(.appHeadline()).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 2) {
                    Text(pier.lineIds.map { appState.river.network.lineName($0) }.joined(separator: " · "))
                        .font(.appCaption(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    FavouriteStopButton(stop: .pier(pier))
                    Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") {
                        let item = MKMapItem(location: CLLocation(latitude: pier.latitude, longitude: pier.longitude), address: nil)
                        item.name = pier.name
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                    }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(appState.isOffline)
                    Button("Close pier", systemImage: "xmark.circle.fill") { appState.river.clearSelection() }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(alignment: .leading, spacing: 8) {
                        let board = appState.river.selectedBoard
                        let departures = (board?.predictions ?? []).filter {
                            !$0.terminatesHere && $0.isCurrent(at: timeline.date)
                                && (appState.river.selectedLineId == nil || $0.lineId == appState.river.selectedLineId)
                                && timeline.date.timeIntervalSince(board?.updatedAt ?? .distantPast) <= 90
                        }.sorted { $0.expectedArrival < $1.expectedArrival }
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
                            boardRows(departures.prefix(dynamicTypeSize.isAccessibilitySize ? 2 : 4), at: timeline.date)
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

    private func boardRows(_ departures: ArraySlice<RiverPrediction>, at date: Date) -> some View {
        VStack(spacing: 8) {
            ForEach(departures) { departure in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(appState.river.network.lineName(departure.lineId)).font(.appSubheadline(.semibold)).foregroundStyle(.blue)
                    Text(departure.destinationName ?? "Destination unavailable").font(.appSubheadline()).lineLimit(2)
                    Spacer(minLength: 6)
                    let seconds = departure.expectedArrival.timeIntervalSince(date)
                    Text(seconds < 60 ? "Due" : "\(Int(ceil(seconds / 60))) min")
                        .font(.appSubheadline(.semibold)).monospacedDigit().fixedSize()
                }
                .accessibilityElement(children: .combine)
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
