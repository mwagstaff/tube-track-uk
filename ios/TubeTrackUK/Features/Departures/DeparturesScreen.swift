import SwiftUI

struct DeparturesScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(UserLocationProvider.self) private var location
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var count = 5
    @State private var query = ""
    @State private var visible: Set<String> = []
    @State private var creating: DepartureFavourite?

    private var store: DepartureBoardStore { appState.departureBoards }
    private var stops: [DepartureStop] { appState.departureStops }
    private var distances: [String: Double] { DepartureLocation.distances(stops: stops, location: location.location) }
    private var nearby: [DepartureStop] {
        let distances = distances
        return stops.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.railCodes.contains { $0.localizedStandardContains(query) } }
            .sorted {
                let left = distances[$0.id] ?? .infinity, right = distances[$1.id] ?? .infinity
                if left != right { return left < right }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
    private var favourites: [DepartureFavourite] {
        let distances = distances
        return store.favourites.sorted {
            let leftID = $0.resolvedOrigin(distances: distances), rightID = $1.resolvedOrigin(distances: distances)
            let left = distances[leftID] ?? .infinity, right = distances[rightID] ?? .infinity
            if left != right { return left < right }
            let leftName = $0.name.isEmpty ? appState.departureStop(id: leftID)?.name ?? leftID : $0.name
            let rightName = $1.name.isEmpty ? appState.departureStop(id: rightID)?.name ?? rightID : $1.name
            return leftName == rightName ? $0.id.uuidString < $1.id.uuidString : leftName.localizedStandardCompare(rightName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Departure boards", selection: Binding(get: { store.tab }, set: { store.tab = $0 })) {
                    Text("Favourites").tag("favourites")
                    Text("Nearby").tag("nearby")
                }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 10)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if store.tab == "favourites" {
                                if favourites.isEmpty {
                                    ContentUnavailableView {
                                        Label("Your commute, both ways", systemImage: "star")
                                    } description: {
                                        Text("Save a departure board and we’ll show the outbound or return journey nearest to you.")
                                    } actions: { Button("Add favourite", action: addFavourite).buttonStyle(.borderedProminent) }
                                }
                                ForEach(favourites) { favourite in
                                    card(request: favourite.outbound, favouriteID: favourite.id, id: favourite.id.uuidString)
                                }
                            } else {
                                if distances.isEmpty { locationPrompt }
                                if distances.isEmpty && query.isEmpty {
                                    ContentUnavailableView("Find a departure board", systemImage: "magnifyingglass",
                                        description: Text("Search for a station or pier, or enable location for nearby departures."))
                                } else {
                                    ForEach(Array(nearby.prefix(count))) { stop in
                                        card(request: .init(originID: stop.id), id: stop.id)
                                    }
                                    if nearby.count > count {
                                        Button("Show 5 more stations") { count += 5 }
                                            .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered)
                                    }
                                    if nearby.isEmpty { ContentUnavailableView.search(text: query) }
                                }
                            }
                        }.padding(16)
                    }
                    .task(id: appState.nearMeFocusGeneration) {
                        guard let id = appState.nearMeFocusedStationID,
                              let stop = appState.departureStop(id: id) else { return }
                        store.tab = "nearby"
                        if distances.isEmpty { query = stop.name }
                        if let index = nearby.firstIndex(where: { $0.id == stop.id }) { count = max(count, index + 1) }
                        await Task.yield()
                        proxy.scrollTo(stop.id, anchor: .top)
                        appState.consumeNearMeFocus(generation: appState.nearMeFocusGeneration)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Departures")
            .searchable(text: $query, prompt: "Find a station or pier")
            .onChange(of: query) { _, value in count = 5; if !value.isEmpty { store.tab = "nearby" } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Add favourite", systemImage: "plus", action: addFavourite) }
            }
            .sheet(item: $creating) { favourite in
                DepartureBoardEditor(draft: favourite) { store.save($0); store.tab = "favourites" }
            }
            .sheet(item: Binding(get: { appState.linkedDepartureBoard }, set: { appState.linkedDepartureBoard = $0 })) { request in
                DepartureBoardCard(initialRequest: request, usesSavedView: false, presentedAsSheet: true)
            }
        }
        .task(id: "\(appState.selectedTab.rawValue):\(scenePhase == .active)") {
            guard appState.selectedTab == .nearMe, scenePhase == .active else { return }
            while !Task.isCancelled {
                location.requestLocation()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private func card(request: DepartureBoardRequest, favouriteID: UUID? = nil, id: String) -> some View {
        DepartureBoardCard(initialRequest: request, favouriteID: favouriteID,
            isVisible: visible.contains(id) && appState.selectedTab == .nearMe)
            .id(id)
            .onScrollVisibilityChange(threshold: 0.05) { showing in
                if showing { visible.insert(id) } else { visible.remove(id) }
            }
    }
    private var locationPrompt: some View {
        HStack(alignment: .top) {
            Label("Use your location to find nearby stations.", systemImage: "location")
                .font(.appSubheadline())
            Spacer()
            Button(location.needsSettingsPermission ? "Settings" : "Enable") {
                if location.needsSettingsPermission, let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                else { location.requestLocation() }
            }.frame(minHeight: 44)
        }
    }
    private func addFavourite() {
        creating = DepartureFavourite(outbound: .init(originID: nearby.first?.id ?? stops.first?.id ?? ""))
    }
}
