import SwiftUI
import TubeTrackCore
import UIKit

enum DepartureBoardTheme {
    static let background = Color(red: 0.13, green: 0.13, blue: 0.12)
    static let yellow = Color(red: 1, green: 0.86, blue: 0)
    static func lineName(_ id: String) -> String {
        TubeLineID(rawValue: id)?.displayName ?? (id.hasPrefix("national-rail:")
            ? "National Rail · \(id.dropFirst(14))" : id.uppercased())
    }
}

struct DepartureBoardCard: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(UserLocationProvider.self) private var location
    @Environment(StationBoardActivityController.self) private var activity: StationBoardActivityController?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let initialRequest: DepartureBoardRequest
    var favouriteID: UUID? = nil
    var isVisible = true
    var usesSavedView = true
    var presentedAsSheet = false
    var preferredServiceID: String? = nil
    @Environment(ScheduledJourneyStore.self) private var scheduleStore: ScheduledJourneyStore?
    @State private var trackingChoice: DepartureBoardDirectionGroup?
    @State private var scheduling: ScheduledJourney?
    @State private var selectedServiceID: String?
    @State private var expandedDirections: Set<String> = []
    @State private var linkedConfiguration: DepartureFavourite?
    @State private var showsDepartureSheet = false
    @State private var editing: DepartureFavourite?
    @State private var savingFavourite = false
    @State private var filtering: DepartureBoardRequest?
    @State private var keepAwake = false
    @State private var confirmDelete = false
    @State private var favouritePendingRemoval: DepartureFavourite?

    private var store: DepartureBoardStore { appState.departureBoards }
    private var key: String { initialRequest.originID + ":" + initialRequest.lineIDs.joined(separator: ",") }
    private var configuration: DepartureFavourite {
        if let favouriteID, let favourite = store.favourites.first(where: { $0.id == favouriteID }) { return favourite }
        if !usesSavedView { return linkedConfiguration ?? DepartureFavourite(outbound: initialRequest) }
        return store.views[key] ?? DepartureFavourite(outbound: initialRequest)
    }
    private var savedFavourite: DepartureFavourite? {
        if let favouriteID { return store.favourites.first { $0.id == favouriteID } }
        return store.favourites.first { $0.outbound == configuration.outbound && $0.returnLineIDs == configuration.returnLineIDs }
    }
    private var distances: [String: Double] {
        let endpoints = Set(configuration.endpointIDs)
        return DepartureLocation.distances(stops: appState.departureStops.filter { endpoints.contains($0.id) }, location: location.location)
    }
    private var originID: String {
        // Nearby and map boards stay at the station the passenger opened until
        // explicitly reversed. Only favourites choose their origin automatically.
        favouriteID == nil ? (configuration.manualOriginID ?? configuration.outbound.originID)
            : configuration.resolvedOrigin(distances: distances)
    }
    private var baseRequest: DepartureBoardRequest { configuration.request(from: originID) }
    private var request: DepartureBoardRequest {
        var value = baseRequest
        if let serviceID { value.lineIDs = [serviceID] }
        // Discover directions independently of their calling-at filters.
        value.destinationIDs = []
        return value
    }
    private var services: [DepartureServiceOption] {
        guard let stop = appState.departureStop(id: originID) else { return [] }
        var options = stop.lineIDs.map { DepartureServiceOption(id: $0, name: DepartureBoardTheme.lineName($0)) }
        options += appState.nationalRail.operators(atStationIDs: DepartureServiceOption.stationAliases(for: stop)).map {
            DepartureServiceOption(id: DepartureServiceOption.serviceID($0.id), name: $0.name)
        }
        options += DepartureServiceOption.mappedRailwayServices(for: stop)
        // Rail-only stations and operators absent from the bundled status index.
        for cached in store.boards where cached.key.originID == originID {
            options += cached.value.arrivals.map { DepartureServiceOption(id: $0.lineId, name: $0.operatorName ?? DepartureBoardTheme.lineName($0.lineId)) }
        }
        var seen = Set<String>()
        return options.filter {
            (baseRequest.lineIDs.isEmpty || baseRequest.lineIDs.contains($0.id)
                || preferredServiceID.map(DepartureServiceOption.serviceID) == $0.id) && seen.insert($0.id).inserted
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var serviceID: String? {
        DepartureServiceOption.selectedID(options: services, selected: selectedServiceID, preferred: preferredServiceID)
    }
    private var origin: DepartureStop? { appState.departureStop(id: request.originID) }
    private var boardTitle: String { origin.map { "\($0.name) departures" } ?? "Departures" }
    private var directionGroups: [DepartureBoardDirectionGroup] {
        var groups = DepartureBoardDirectionGroup.groups(from: board?.arrivals ?? [], origin: origin, stops: appState.departureStops)
        for filter in configuration.directionFilters ?? [] where filter.originID == originID && filter.lineIDs == request.lineIDs {
            if let direction = filter.direction, !groups.contains(where: { $0.title == direction }) {
                groups.append(.init(title: direction, arrivals: []))
            }
        }
        return groups
    }
    private var board: CustomDepartureBoard? { store.boards[request] }
    private var pollID: String {
        "\(request):\(configuration.directionFilters ?? []):\(baseRequest.destinationIDs):\(scenePhase == .active):\(isVisible || showsDepartureSheet):\(appState.isOffline):\(appState.selectedTab.rawValue)"
    }

    var body: some View {
        Group {
            if presentedAsSheet {
                NavigationStack {
                    ScrollView {
                        boardContent(expanded: true)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                        Toggle("Keep screen awake", isOn: $keepAwake)
                            .padding(.horizontal, 20).padding(.bottom, 20)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(boardTitle).font(.appHeadline()).lineLimit(2)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            favouriteButton
                                .font(.system(size: 17))
                            Button("Close departures", systemImage: "xmark") { dismiss() }
                                .labelStyle(.iconOnly).font(.system(size: 17))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationSizing(.page)
                .presentationCompactAdaptation(.sheet)
                .onChange(of: keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value && scenePhase == .active }
                .onChange(of: scenePhase) { _, phase in UIApplication.shared.isIdleTimerDisabled = keepAwake && phase == .active }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; keepAwake = false }
            } else {
                boardContent(expanded: false)
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            }
        }
        .foregroundStyle(.primary)
        .onChange(of: request) { _, _ in expandedDirections.removeAll() }
        .sheet(isPresented: $showsDepartureSheet) {
            DepartureBoardCard(initialRequest: initialRequest, favouriteID: favouriteID,
                               usesSavedView: usesSavedView, presentedAsSheet: true, preferredServiceID: serviceID)
        }
        .sheet(item: $editing) { editor($0) }
        .sheet(item: $scheduling) { journey in
            NavigationStack { ScheduledJourneyEditor(journey: journey) }
        }
        .confirmationDialog("Track this journey", isPresented: Binding(
            get: { trackingChoice != nil }, set: { if !$0 { trackingChoice = nil } }
        ), titleVisibility: .visible, presenting: trackingChoice) { group in
            Button("Start tracking now") { startTracking(group) }
                .disabled(!canTrack(group))
            if let draft = suggestedSchedule(group), scheduleStore != nil {
                Button("Add scheduled journey") { scheduling = draft }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            if !trackingRequest(group).destinationIDs.isEmpty {
                Text("Scheduled journeys track this service and direction. Calling-at filters apply only when you start tracking now.")
            }
        }
        .sheet(item: $filtering) { request in
            DepartureDirectionFilterEditor(request: request) { saved in
                var changed = configuration
                changed.setDirectionFilter(saved)
                update(changed)
                expandedDirections.removeAll()
            }
        }
        .task(id: pollID) {
            guard scenePhase == .active, isVisible || showsDepartureSheet, !appState.isOffline else { return }
            rememberOrigin()
            while !Task.isCancelled {
                await store.refresh(request)
                guard !Task.isCancelled else { return }
                if let board {
                    await activity?.update(request: request, board: board)
                    for group in directionGroups {
                        let filteredRequest = trackingRequest(group)
                        if !filteredRequest.destinationIDs.isEmpty {
                            await store.refresh(filteredRequest)
                        }
                        guard !Task.isCancelled else { return }
                        if let filteredBoard = directionBoard(board, group: group) {
                            await activity?.update(request: filteredRequest, board: filteredBoard)
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    @ViewBuilder private func editor(_ draft: DepartureFavourite) -> some View {
        DepartureBoardEditor(draft: draft, savingFavourite: savingFavourite || favouriteID != nil) { saved in
            if savingFavourite {
                store.save(saved)
                if favouriteID == nil { store.saveView(saved, key: key) }
            }
            else { update(saved) }
        }
    }

    private func boardContent(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !expanded {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !configuration.name.isEmpty { Text(configuration.name).font(.appCaption(.semibold)) }
                        Text(boardTitle).font(.appHeadline())
                            .accessibilityAddTraits(.isHeader)
                        if let origin {
                            DepartureDistanceButton(stop: origin, distance: distances[originID])
                        }
                    }
                    Spacer(minLength: 8)
                    favouriteButton
                    Button("Open departures", systemImage: "arrow.up.left.and.arrow.down.right") { showsDepartureSheet = true }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            } else {
                if !configuration.name.isEmpty { Text(configuration.name).font(.appCaption(.semibold)) }
                if let origin { DepartureDistanceButton(stop: origin, distance: distances[originID]) }
            }
            ViewThatFits(in: .horizontal) {
                servicePills.fixedSize(horizontal: true, vertical: false)
                ScrollView(.horizontal) { servicePills }
                    .scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading, spacing: 4) { controls }
            }
            .font(.appCaption(.semibold))
            if let origin, appState.journeyStation(for: origin) == nil {
                Text("Journey planning isn’t available for this stop.")
                    .font(.appCaption()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !configuration.outbound.destinationIDs.isEmpty, favouriteID != nil {
                Label(configuration.manualOriginID == nil ? "Direction follows location" : "Manual direction",
                      systemImage: configuration.manualOriginID == nil ? "location.fill" : "hand.raised")
                    .font(.appCaption2()).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                rows(now: timeline.date, expanded: expanded)
            }
            if let board {
                if let headline = board.conditionHeadline {
                    Label(headline, systemImage: "exclamationmark.triangle")
                        .font(.appCaption(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                if board.unverifiedCount > 0 {
                    Label("Some services are hidden because their calling points couldn’t be verified.", systemImage: "info.circle")
                        .font(.appCaption()).fixedSize(horizontal: false, vertical: true)
                }
                if board.unavailableSources > 0 {
                    Label("Some lines or operators are temporarily unavailable.", systemImage: "exclamationmark.triangle")
                        .font(.appCaption()).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    if store.errors[request] != nil || board.stale { Image(systemName: "exclamationmark.triangle") }
                    Text("Last update")
                    Text(board.updatedAt, style: .time)
                }.font(.appCaption2()).foregroundStyle(.secondary)
            }

        }
    }

    private var servicePills: some View {
        HStack(spacing: 7) {
            ForEach(services) { service in
                if let line = TubeLineID(rawValue: service.id) {
                    StationLinePill(lineID: line, selected: service.id == serviceID) { selectService(service.id) }
                } else {
                    NationalRailOperatorPill(name: service.name, id: service.id, selected: service.id == serviceID) { selectService(service.id) }
                }
            }
        }
    }

    private var favouriteButton: some View {
        Button(savedFavourite == nil ? "Save favourite" : "Remove favourite",
               systemImage: savedFavourite == nil ? "star" : "star.fill") {
            if let favourite = savedFavourite {
                favouritePendingRemoval = favourite
                confirmDelete = true
            } else {
                savingFavourite = true
                var draft = configuration
                draft.id = UUID()
                editing = draft
            }
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint(savedFavourite == nil ? "Opens the favourite editor" : "Asks for confirmation before removing this favourite")
        // Anchor the presentation to its control, outside the card's sheet presenters.
        .confirmationDialog("Remove this favourite?", isPresented: $confirmDelete,
                            titleVisibility: .visible, presenting: favouritePendingRemoval) { favourite in
            Button("Remove favourite", role: .destructive) {
                store.remove(favourite.id)
                favouritePendingRemoval = nil
                if presentedAsSheet && favouriteID != nil { dismiss() }
            }
            Button("Cancel", role: .cancel) { favouritePendingRemoval = nil }
        }
    }

    @ViewBuilder private var controls: some View {
        if let origin {
            Menu {
                Button("Start here", systemImage: "figure.walk.departure") { planJourney(from: origin, asOrigin: true) }
                Button("End here", systemImage: "mappin.and.ellipse") { planJourney(from: origin, asOrigin: false) }
            } label: { Label("Plan journey", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .frame(minHeight: 44)
                .disabled(appState.journeyStation(for: origin) == nil)
        }
        if favouriteID != nil {
            Button("Edit favourite", systemImage: "pencil") { savingFavourite = false; editing = configuration }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }
        if !configuration.outbound.destinationIDs.isEmpty {
            Button("Reverse", systemImage: "arrow.left.arrow.right") {
                var changed = configuration
                // Reverse exactly what is displayed, even if this isn't a favourite.
                changed.lastOriginID = originID; changed.manualOriginID = originID
                changed.reverse(distances: distances); update(changed)
            }.frame(minHeight: 44)
            if configuration.manualOriginID != nil {
                Button(favouriteID == nil ? "Reset direction" : "Use location", systemImage: "location") {
                    var changed = configuration; changed.manualOriginID = nil; update(changed)
                }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint(favouriteID == nil ? "Returns to the original station" : "Returns to automatic direction")
            }
        }
    }

    @ViewBuilder private func rows(now: Date, expanded: Bool) -> some View {
        if appState.isOffline {
            Label("Live departures unavailable offline", systemImage: "wifi.slash")
        } else if let error = store.errors[request], board == nil {
            Text(error).font(.appSubheadline())
        } else if let board, now.timeIntervalSince(board.updatedAt) > 90 {
            Text("Waiting for fresh departures…").font(.appSubheadline())
        } else if let board {
            if directionGroups.isEmpty {
                Text(request.destinationIDs.isEmpty ? "No imminent departures reported." : "No matching departures reported.")
                    .font(.appSubheadline())
            } else {
                let groups = directionGroups
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups) { group in
                        let filteredBoard = directionBoard(board, group: group)
                        let filteredArrivals = filteredBoard?.upcoming(at: now) ?? []
                        let filteredRequest = trackingRequest(group)
                        VStack(alignment: .leading, spacing: 10) {
                            ViewThatFits(in: .horizontal) {
                                HStack { directionHeading(group); Spacer(); directionControls(group) }
                                VStack(alignment: .leading) { directionHeading(group); directionControls(group) }
                            }
                            if !filteredRequest.destinationIDs.isEmpty {
                                Text("Calling at " + filteredRequest.destinationIDs.compactMap { appState.departureStop(id: $0)?.name }.joined(separator: " or "))
                                    .font(.appCaption()).fixedSize(horizontal: false, vertical: true)
                            }
                            VStack(spacing: expanded ? 22 : 14) {
                                if let error = store.errors[filteredRequest] {
                                    Text(error).font(.appSubheadline())
                                } else if filteredBoard == nil {
                                    ProgressView("Loading filtered departures…")
                                } else if let filteredBoard, now.timeIntervalSince(filteredBoard.updatedAt) > 90 {
                                    Text("Waiting for fresh departures…").font(.appSubheadline())
                                } else if filteredArrivals.isEmpty {
                                    Text("No matching departures. Change the filter to see more services.").font(.appSubheadline())
                                }
                                if let filteredBoard, now.timeIntervalSince(filteredBoard.updatedAt) <= 90 {
                                    ForEach(Array((expandedDirections.contains(group.id) ? filteredArrivals : Array(filteredArrivals.prefix(5))).enumerated()), id: \.offset) { _, arrival in
                                        StationDepartureRow(arrival: arrival, now: now, showsOperator: true)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .foregroundStyle(DepartureBoardTheme.yellow)
                            .background(DepartureBoardTheme.background, in: .rect(cornerRadius: 12))
                            .environment(\.colorScheme, .dark)
                            .environment(\.departureBoardYellow, true)
                            if filteredArrivals.count > 5 {
                                Button(expandedDirections.contains(group.id) ? "Show fewer" : "View all \(filteredArrivals.count) departures",
                                       systemImage: expandedDirections.contains(group.id) ? "chevron.up" : "chevron.down") {
                                    if !expandedDirections.insert(group.id).inserted { expandedDirections.remove(group.id) }
                                }.font(.appCaption(.semibold)).frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView("Loading departures…")
        }
    }

    private func selectService(_ id: String) {
        selectedServiceID = id
        expandedDirections.removeAll()
    }

    private func directionHeading(_ group: DepartureBoardDirectionGroup) -> some View {
        Text(group.title).font(.appHeadline()).accessibilityAddTraits(.isHeader)
    }

    private func trackingRequest(_ group: DepartureBoardDirectionGroup) -> DepartureBoardRequest {
        configuration.request(from: originID, serviceID: serviceID, direction: group.title)
    }

    private func directionBoard(_ board: CustomDepartureBoard, group: DepartureBoardDirectionGroup) -> CustomDepartureBoard? {
        let request = trackingRequest(group)
        if !request.destinationIDs.isEmpty { return store.boards[request] }
        return board.selecting(group.arrivals)
    }

    private func directionControls(_ group: DepartureBoardDirectionGroup) -> some View {
        HStack(spacing: 16) {
            Button("Filter", systemImage: "line.3.horizontal.decrease") { filtering = trackingRequest(group) }
                .accessibilityLabel("Filter \(group.title) departures")
                .frame(minHeight: 44)
            trackButton(group)
        }.font(.appCaption(.semibold))
    }

    private func planJourney(from stop: DepartureStop, asOrigin: Bool) {
        guard appState.prepareJourney(at: stop, asOrigin: asOrigin) else { return }
        if presentedAsSheet { dismiss() }
        appState.selectedTab = .journeys
    }

    @ViewBuilder private func trackButton(_ group: DepartureBoardDirectionGroup) -> some View {
        if let activity, activity.areActivitiesEnabled, let serviceID {
            let trackedRequest = trackingRequest(group)
            let tracking = activity.isTracking(request: trackedRequest)
            Button(tracking ? "Stop tracking" : "Track", systemImage: tracking ? "stop.circle" : "livephoto") {
                if tracking { Task { await activity.end(reason: .userEnded) } }
                else if suggestedSchedule(group) != nil && scheduleStore != nil { trackingChoice = group }
                else { startTracking(group) }
            }.font(.appCaption(.semibold)).frame(minHeight: 44)
                .accessibilityLabel(tracking ? "Stop tracking \(group.title)" : "Track \(services.first { $0.id == serviceID }?.name ?? serviceID) \(group.title)")
                .disabled(!tracking && !canTrack(group) && (scheduleStore == nil || suggestedSchedule(group) == nil))
        }
    }

    private func startTracking(_ group: DepartureBoardDirectionGroup) {
        guard let activity, let serviceID, canTrack(group),
              let board, let filteredBoard = directionBoard(board, group: group) else { return }
        let trackedRequest = trackingRequest(group)
        let name = services.first { $0.id == serviceID }?.name ?? serviceID
        Task {
            await activity.start(request: trackedRequest, stationName: origin?.name ?? "Departures",
                                 callingAt: "\(name) · \(group.title)", board: filteredBoard)
        }
    }

    private func suggestedSchedule(_ group: DepartureBoardDirectionGroup) -> ScheduledJourney? {
        guard let origin, let serviceID else { return nil }
        let name = services.first { $0.id == serviceID }?.name ?? serviceID
        let direction = DepartureDirectionFilter.resolve(label: group.title)
        guard var outbound = ScheduledBoard.departure(station: origin, serviceID: serviceID,
                                                      serviceName: name, direction: direction) else { return nil }
        let destinations = trackingRequest(group).destinationIDs
        outbound.destinationIDs = destinations
        var returning = destinations.count == 1 ? appState.departureStop(id: destinations[0]).flatMap {
            ScheduledBoard.departure(station: $0, serviceID: serviceID, serviceName: name, direction: direction.reversed)
        } : nil
        returning?.destinationIDs = [origin.id]
        return .suggested(outbound: outbound, returning: returning)
    }

    private func canTrack(_ group: DepartureBoardDirectionGroup) -> Bool {
        guard !appState.isOffline, store.errors[request] == nil,
              store.errors[trackingRequest(group)] == nil,
              let board = board.flatMap({ directionBoard($0, group: group) }) else { return false }
        return board.unavailableSources == 0 && !board.stale
            && Date.now.timeIntervalSince(board.updatedAt) <= 90 && !board.upcoming(at: .now).isEmpty
    }

    private func update(_ value: DepartureFavourite) {
        if favouriteID != nil { store.save(value) }
        else if !usesSavedView { linkedConfiguration = value }
        else { store.saveView(value, key: key) }
    }
    private func rememberOrigin() {
        guard favouriteID != nil, configuration.lastOriginID != originID else { return }
        var value = configuration; value.lastOriginID = originID; update(value)
    }
}

private struct DepartureBoardYellowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var departureBoardYellow: Bool {
        get { self[DepartureBoardYellowKey.self] }
        set { self[DepartureBoardYellowKey.self] = newValue }
    }
}


#Preview("Departure sheet") {
    let state = TubeAppState(monitorsConnectivity: false)
    state.graph = try? TubeGraph.bundled()
    state.setNetworkAvailable(false)
    return DepartureBoardCard(initialRequest: .init(originID: "HUBSYD"), isVisible: false, presentedAsSheet: true)
        .environment(state).environment(UserLocationProvider())
}

#Preview("Departure sheet · Large text") {
    let state = TubeAppState(monitorsConnectivity: false)
    state.graph = try? TubeGraph.bundled()
    state.setNetworkAvailable(false)
    return DepartureBoardCard(initialRequest: .init(originID: "HUBSYD"), isVisible: false, presentedAsSheet: true)
        .environment(state).environment(UserLocationProvider())
        .environment(\.dynamicTypeSize, .accessibility3).preferredColorScheme(.dark)
}
