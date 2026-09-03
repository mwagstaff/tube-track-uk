import Foundation
import Observation
import SwiftUI

enum LiveDepartureWaitingCopy {
    static let title = "Waiting for live data"
    static let message = "Waiting for live departures. They should arrive shortly."
}

enum AppTab: String, CaseIterable, Identifiable {
    case map
    case nearMe
    case works
    case profile

    var id: Self { self }

    var title: String {
        switch self {
        case .map: "Map"
        case .nearMe: "Near Me"
        case .works: "Works"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .map: "map"
        case .nearMe: "location.fill"
        case .works: "wrench.and.screwdriver"
        case .profile: "person.crop.circle"
        }
    }
}

enum DisruptionDisplayMode: String, CaseIterable, Sendable {
    case normal
    case issues

    func mutesSegment(isAffected: Bool) -> Bool {
        switch self {
        case .normal:
            isAffected
        case .issues:
            !isAffected
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var actionTitle: String {
        switch self {
        case .system: "Use system appearance"
        case .light: "Enable light mode"
        case .dark: "Enable dark mode"
        }
    }
}

@MainActor
@Observable
final class TubeAppState {
    private static let appearanceModeKey = "appearanceMode"
    private static let nearbyArrivalsStaleLifetime: TimeInterval = 5 * 60

    var selectedTab: AppTab = .map {
        didSet {
            guard selectedTab != oldValue else { return }
            updateSelectedStationArrivalsVisibility()
            updateLiveTrainPollingVisibility()
        }
    }
    var mapPresentationMode: MapPresentationMode = .beck
    var sharedMapViewport: SharedMapViewport?
    var beckMapCameraSnapshot: BeckMapCameraSnapshot?
    var disruptionDisplayMode: DisruptionDisplayMode = .normal
    var selectedMapNetworkStat: MapNetworkStatFilter?
    var disruptionDateSelection: DisruptionDateSelection = .today
    var selectedDisruptionTimeWindows = DisruptionTimeWindow.defaultSelected
    var highlightedDisruptionCategories = DisruptionCategory.defaultHighlighted
    private(set) var isGameActive = false
    var showLiveTrains = false
    var isLoadingLiveTrains = false
    var trainLineFilter: Set<TubeLineID> = []
    var selectedTrainID: String?
    private(set) var trainSelectionGeneration = 0
    var selectedLineID: TubeLineID?
    var selectedStationID: String?
    private(set) var stationSelectionGeneration = 0
    private(set) var nearMeFocusedStationID: String?
    private(set) var nearMeFocusGeneration = 0
    var selectedDisruptionID: String?
    private(set) var disruptionSelectionGeneration = 0
    private(set) var disruptionOverviewFocusGeneration = 0
    var selectedEngineeringWorkID: String?
    var focusedSegmentIDs: Set<String> = []
    var focusedStationIDs: Set<String> = []
    var focusedLineIDs: Set<TubeLineID> = []
    var focusedResolutionConfidence: ResolutionConfidence?
    var appearanceMode: AppAppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
        }
    }

    var preferredColorScheme: ColorScheme? {
        appearanceMode.colorScheme
    }

    var disruptionHighlightScope: MapDisruptionHighlightScope? {
        MapDisruptionHighlightScope(filter: selectedMapNetworkStat)
    }

    var isViewingDisruptedLines: Bool {
        disruptionHighlightScope != nil
    }

    var graph: TubeGraph?
    private(set) var initialBeckMapDocument: BeckMapDocument?
    var statuses: [TfLLineStatus] = []
    var disruptions: [ResolvedDisruption] = []
    var engineeringWorks: [EngineeringWork] = []
    var liveTrains: [LiveTubeTrain] = []
    var activeTrainCounts = ActiveTrainCounts()
    var stationArrivals: [TfLArrivalPrediction] = []
    private(set) var stationArrivalsUpdatedAt: Date?
    var isRefreshingStationArrivals = false
    var stationArrivalsError: String?
    var nearbyArrivalsByStationID: [String: [TfLArrivalPrediction]] = [:]
    var nearbyArrivalsUpdatedAtByStationID: [String: Date] = [:]
    var nearbyArrivalsLoadingStationIDs: Set<String> = []
    var nearbyArrivalsErrorsByStationID: [String: String] = [:]
    var statusUpdatedAt: Date?
    var worksUpdatedAt: Date?
    var isUsingCachedStatus = false
    var isUsingCachedWorks = false
    var isLoadingGraph = true
    var isRefreshingStatus = false
    var isRefreshingWorks = false
    var statusError: String?
    var worksError: String?
    @ObservationIgnored private var apiClient: TubeTrackAPIClient?
    @ObservationIgnored private var statusService: TubeStatusService?
    @ObservationIgnored private var worksService: EngineeringWorksService?
    @ObservationIgnored private var trainService: (any LiveTrainFetching)?
    @ObservationIgnored private var stationArrivalsService: StationArrivalsService?
    @ObservationIgnored private var stationArrivalsTask: Task<Void, Never>?
    @ObservationIgnored private var stationArrivalsPollingTask: Task<Void, Never>?
    @ObservationIgnored private var stationArrivalsGeneration: UInt = 0
    @ObservationIgnored private var nearbyArrivalsGenerationByStationID: [String: UInt] = [:]
    @ObservationIgnored private var statusPollingTask: Task<Void, Never>?
    @ObservationIgnored private var trainPollingTask: Task<Void, Never>?
    @ObservationIgnored private var trainRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var trainRetryTask: Task<Void, Never>?
    @ObservationIgnored private var trainRefreshFilter: Set<TubeLineID>?
    @ObservationIgnored private var liveTrainRetryAfter: Date?
    @ObservationIgnored private var trainRefreshGeneration: UInt = 0
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private var initialRefreshTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        trainService: (any LiveTrainFetching)? = nil
    ) {
        self.defaults = defaults
        self.trainService = trainService
        appearanceMode = defaults.string(forKey: Self.appearanceModeKey)
            .flatMap(AppAppearanceMode.init(rawValue:)) ?? .system

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-DebugTab"), arguments.indices.contains(flag + 1),
           let tab = AppTab(rawValue: arguments[flag + 1]) {
            selectedTab = tab
        }
        if let flag = arguments.firstIndex(of: "-DebugMapMode"),
           arguments.indices.contains(flag + 1),
           let mode = MapPresentationMode(rawValue: arguments[flag + 1]) {
            mapPresentationMode = mode
        }
        if arguments.contains("-DebugLiveTrains") {
            showLiveTrains = true
            trainLineFilter = [.piccadilly]
        }
        if arguments.contains("-DebugIssues") {
            disruptionDisplayMode = .issues
        }
        #endif
    }

    var selectedStation: TubeStation? {
        guard let selectedStationID else { return nil }
        return graph?.stations.first { $0.id == selectedStationID }
    }

    var selectedDisruption: ResolvedDisruption? {
        visibleDisruptions.first { $0.id == selectedDisruptionID }
    }

    var selectedEngineeringWork: EngineeringWork? {
        guard let selectedEngineeringWorkID else { return nil }
        return engineeringWorks.first { $0.id == selectedEngineeringWorkID }
    }

    var selectedTrain: LiveTubeTrain? {
        guard let selectedTrainID else { return nil }
        return liveTrains.first { $0.id == selectedTrainID }
    }

    var isViewingLiveStatus: Bool {
        disruptionDateSelection == .today
    }

    var selectedDisruptionDate: Date {
        disruptionDateSelection.date()
    }

    var latestSelectableDisruptionDate: Date {
        LondonRailDate.calendar.date(
            byAdding: .day,
            value: 60,
            to: DisruptionDateSelection.today.date()
        ) ?? DisruptionDateSelection.today.date()
    }

    var plannedWorksForSelectedDate: [EngineeringWork] {
        guard !isViewingLiveStatus else { return [] }
        return LondonRailDate.works(
            engineeringWorks,
            overlapping: selectedDisruptionDate
        )
    }

    var selectedEngineeringWorks: [EngineeringWork] {
        LondonRailDate.works(
            plannedWorksForSelectedDate,
            overlappingAny: selectedDisruptionTimeWindows,
            on: selectedDisruptionDate
        )
    }

    var authoritativeStationBoardSnapshot: LiveTrainStationBoardSnapshot? {
        guard let selectedStationID,
              let stationArrivalsUpdatedAt,
              stationArrivalsError == nil else {
            return nil
        }
        return LiveTrainStationBoardSnapshot(
            stationID: selectedStationID,
            arrivals: stationArrivals,
            updatedAt: stationArrivalsUpdatedAt
        )
    }

    var visibleDisruptions: [ResolvedDisruption] {
        if isViewingLiveStatus { return disruptions }
        return selectedEngineeringWorks.flatMap { resolvedDisruptions(for: $0) }
    }

    var highlightedDisruptions: [ResolvedDisruption] {
        visibleDisruptions.filter { highlightedDisruptionCategories.contains($0.category) }
    }

    var mapHighlightedDisruptions: [ResolvedDisruption] {
        guard let disruptionHighlightScope else { return highlightedDisruptions }
        return visibleDisruptions.filter { disruptionHighlightScope.includes($0) }
    }

    var mapNetworkStatusSummary: MapNetworkStatusSummary {
        MapNetworkStatusSummary(
            statuses: statuses,
            disruptions: visibleDisruptions,
            isViewingLiveStatus: isViewingLiveStatus
        )
    }

    var activeAffectedSegmentIDs: Set<String> {
        if hasFocusedMapSection { return focusedSegmentIDs }
        if let selectedDisruption { return selectedDisruption.affectedSegmentIDs }
        return Set(mapHighlightedDisruptions.flatMap(\.affectedSegmentIDs))
    }

    var activeAffectedStationIDs: Set<String> {
        if hasFocusedMapSection { return focusedStationIDs }
        if let selectedDisruption { return selectedDisruption.affectedStationIDs }
        return Set(mapHighlightedDisruptions.flatMap(\.affectedStationIDs))
    }

    var hasFocusedMapSection: Bool {
        !focusedLineIDs.isEmpty || !focusedSegmentIDs.isEmpty || !focusedStationIDs.isEmpty
    }

    var currentIssueCount: Int {
        isViewingLiveStatus ? disruptions.count : selectedEngineeringWorks.count
    }

    func plannedWorkCount(in window: DisruptionTimeWindow) -> Int {
        LondonRailDate.works(
            plannedWorksForSelectedDate,
            overlappingAny: [window],
            on: selectedDisruptionDate
        ).count
    }

    var disruptionDataUpdatedAt: Date? {
        isViewingLiveStatus ? statusUpdatedAt : worksUpdatedAt
    }

    var isUsingCachedDisruptionData: Bool {
        isViewingLiveStatus ? isUsingCachedStatus : isUsingCachedWorks
    }

    var isRefreshingDisruptionData: Bool {
        isViewingLiveStatus ? isRefreshingStatus : isRefreshingWorks
    }

    var isLoadingInitialStatus: Bool {
        statuses.isEmpty
            && statusUpdatedAt == nil
            && (isRefreshingStatus || statusError == nil)
    }

    var disruptionDataError: String? {
        isViewingLiveStatus ? statusError : worksError
    }

    var goodServiceLineCount: Int {
        statuses.filter { line in
            line.lineStatuses.allSatisfy { $0.isGoodService || $0.isOvernightClosure }
        }.count
    }

    func start() async {
        guard !started else { return }
        started = true
        isLoadingGraph = true
        do {
            // JSON decoding and artwork validation are local CPU and disk work.
            // Keep both off the main actor so the startup interstitial can draw
            // immediately and remain responsive while the map is prepared.
            let startupContent = try await Task.detached(priority: .userInitiated) {
                let graph = try TubeGraph.bundled()
                let document = try BeckMapRepository().load(
                    region: .fullUnderground,
                    graph: graph
                )
                return (graph, document)
            }.value
            guard !Task.isCancelled else { return }

            let loadedGraph = startupContent.0
            initialBeckMapDocument = startupContent.1
            graph = loadedGraph
            let repository = TubeNetworkRepository(graph: loadedGraph)
            let client = TubeTrackAPIClient()
            apiClient = client
            let cache = SnapshotCache()
            statusService = TubeStatusService(client: client, cache: cache, repository: repository)
            worksService = EngineeringWorksService(client: client, cache: cache, repository: repository)
            if trainService == nil {
                trainService = TubeTrainService(client: client, repository: repository)
            }
            stationArrivalsService = StationArrivalsService(client: client)
            isLoadingGraph = false

            // Live status and planned works enhance the already usable map.
            // Fetch them concurrently without keeping the launch interstitial
            // on screen or delaying interaction with the bundled map.
            initialRefreshTask = Task { [weak self] in
                await self?.refreshInitialNetworkData()
            }
        } catch {
            isLoadingGraph = false
            statusError = error.localizedDescription
        }
    }

    private func refreshInitialNetworkData() async {
        async let statusRefresh: Void = refreshStatus()
        async let worksRefresh: Void = refreshWorks()
        _ = await (statusRefresh, worksRefresh)

        guard appIsActive, !Task.isCancelled else { return }
        startStatusPolling()
        updateLiveTrainPollingVisibility()
    }

    func refreshStatus() async {
        guard let statusService, !isRefreshingStatus else { return }
        isRefreshingStatus = true
        defer { isRefreshingStatus = false }
        do {
            let snapshot = try await statusService.fetch()
            if statuses != snapshot.statuses {
                statuses = snapshot.statuses
            }
            let disruptionsChanged = disruptions != snapshot.disruptions
            if disruptionsChanged {
                disruptions = snapshot.disruptions
            }
            #if DEBUG
            if disruptionsChanged {
                for disruption in snapshot.disruptions {
                    print("[TubeTrack] disruption=\(disruption.lineID.rawValue) segments=\(disruption.affectedSegmentIDs.count) confidence=\(disruption.confidence.rawValue)")
                }
            }
            #endif
            statusUpdatedAt = snapshot.fetchedAt
            isUsingCachedStatus = snapshot.cached
            statusError = nil
            if selectedDisruptionID != nil && selectedDisruption == nil {
                selectedDisruptionID = nil
            }
        } catch {
            statusError = error.localizedDescription
        }
    }

    func refreshWorks(
        through requestedDate: Date? = nil,
        forceRefresh: Bool = false
    ) async {
        guard let worksService, !isRefreshingWorks else { return }
        isRefreshingWorks = true
        defer { isRefreshingWorks = false }
        do {
            let snapshot = try await worksService.fetch(
                through: requestedDate,
                forceRefresh: forceRefresh
            )
            engineeringWorks = snapshot.works
            worksUpdatedAt = snapshot.fetchedAt
            isUsingCachedWorks = snapshot.cached
            worksError = nil
            if selectedEngineeringWorkID != nil && selectedEngineeringWork == nil {
                clearMapSelection()
            }
        } catch {
            worksError = error.localizedDescription
        }
    }

    func setLiveTrains(_ enabled: Bool) {
        showLiveTrains = enabled
        if enabled {
            isLoadingLiveTrains = liveTrains.isEmpty
            updateLiveTrainPollingVisibility()
        } else {
            trainPollingTask?.cancel()
            trainPollingTask = nil
            cancelTrainRefresh()
            selectedTrainID = nil
            liveTrains = []
            activeTrainCounts = ActiveTrainCounts()
        }
    }

    func setGameActive(_ active: Bool) {
        guard active != isGameActive else { return }
        isGameActive = active

        if active {
            trainPollingTask?.cancel()
            trainPollingTask = nil
            cancelTrainRefresh()
            cancelStationArrivalsPolling()
            cancelStationArrivalsRefresh()
        } else {
            updateLiveTrainPollingVisibility()
            updateSelectedStationArrivalsVisibility()
        }
    }

    func setTrainFilter(_ lineID: TubeLineID?) {
        let newFilter = lineID.map { Set([$0]) } ?? []
        guard newFilter != trainLineFilter else { return }
        trainLineFilter = newFilter
        if showLiveTrains, selectedTab == .map {
            requestTrainRefresh()
        }
    }

    func setDisruptionCategory(_ category: DisruptionCategory, highlighted: Bool) {
        var categories = highlightedDisruptionCategories
        if highlighted {
            categories.insert(category)
        } else {
            categories.remove(category)
        }
        highlightedDisruptionCategories = categories
        if !highlighted, selectedDisruption?.category == category {
            clearMapSelection()
        }
    }

    func setDisruptionDateSelection(_ selection: DisruptionDateSelection) {
        guard selection != disruptionDateSelection else { return }
        clearMapSelection()
        selectedMapNetworkStat = nil
        disruptionDisplayMode = .normal
        disruptionDateSelection = selection
    }

    func toggleDisruptionTimeWindow(_ window: DisruptionTimeWindow) {
        clearMapSelection()
        if selectedDisruptionTimeWindows.contains(window) {
            selectedDisruptionTimeWindows.remove(window)
        } else {
            selectedDisruptionTimeWindows.insert(window)
        }
    }

    func toggleDisruptionHighlighting() {
        if let disruptionHighlightScope {
            setDisruptionHighlightScope(disruptionHighlightScope.next)
        } else {
            setDisruptionHighlightScope(.all)
        }
    }

    func enableDisruptionHighlighting() {
        if highlightedDisruptionCategories.isEmpty {
            highlightedDisruptionCategories = DisruptionCategory.defaultHighlighted
        }
        setDisruptionHighlightScope(.all)
    }

    func setDisruptionHighlightScope(_ scope: MapDisruptionHighlightScope?) {
        clearMapSelection()
        selectedMapNetworkStat = scope?.filter
        disruptionDisplayMode = scope == nil ? .normal : .issues
    }

    func highlightAllDisruptionsOnMap() {
        setDisruptionHighlightScope(.all)
        disruptionOverviewFocusGeneration &+= 1
    }

    func showDisruptionsOnMap(for selection: DisruptionDateSelection) {
        setDisruptionDateSelection(selection)
        highlightAllDisruptionsOnMap()
        selectedTab = .map
    }

    func select(station: TubeStation) {
        cancelStationArrivalsPolling()
        cancelStationArrivalsRefresh()
        selectedTrainID = nil
        selectedStationID = station.id
        stationSelectionGeneration &+= 1
        selectedLineID = nil
        selectedDisruptionID = nil
        selectedEngineeringWorkID = nil
        stationArrivals = []
        stationArrivalsUpdatedAt = nil
        stationArrivalsError = nil
        if selectedTab == .map {
            requestStationArrivals(for: station.id)
            startStationArrivalsPolling()
        }
    }

    func showNearMe(focusedOn station: TubeStation) {
        nearMeFocusedStationID = station.id
        nearMeFocusGeneration &+= 1
        selectedTab = .nearMe
    }

    func consumeNearMeFocus(generation: Int) {
        guard generation == nearMeFocusGeneration else { return }
        nearMeFocusedStationID = nil
    }

    func clearStationSelection() {
        cancelStationArrivalsPolling()
        cancelStationArrivalsRefresh()
        selectedStationID = nil
        stationArrivals = []
        stationArrivalsUpdatedAt = nil
        stationArrivalsError = nil
    }

    func refreshTrains() async {
        requestTrainRefresh()
        let refreshTask = trainRefreshTask
        await refreshTask?.value
    }

    func select(train: LiveTubeTrain) {
        clearStationSelection()
        selectedTrainID = train.id
        trainSelectionGeneration &+= 1
        selectedLineID = nil
        selectedDisruptionID = nil
        selectedEngineeringWorkID = nil
        focusedSegmentIDs = []
        focusedStationIDs = []
        focusedLineIDs = []
        focusedResolutionConfidence = nil
    }

    func refreshNearbyArrivals(
        for stations: [TubeStation],
        forceRefresh: Bool = false
    ) async {
        guard let graph, let stationArrivalsService else { return }

        let stationIDs = Set(stations.map(\.id))
        nearbyArrivalsLoadingStationIDs.formUnion(stationIDs)

        let requests = stations.map { station -> NearbyArrivalsRequest in
            let generation = (nearbyArrivalsGenerationByStationID[station.id] ?? 0) &+ 1
            nearbyArrivalsGenerationByStationID[station.id] = generation
            nearbyArrivalsErrorsByStationID[station.id] = nil
            return NearbyArrivalsRequest(
                station: station,
                stopIDs: graph.stations(inSamePlaceAs: station).map(\.id),
                generation: generation
            )
        }

        await withTaskGroup(of: NearbyArrivalsResult.self) { group in
            for request in requests {
                group.addTask {
                    do {
                        let snapshot = try await stationArrivalsService.fetchSnapshot(
                            stationIDs: request.stopIDs,
                            forceRefresh: forceRefresh
                        )
                        return NearbyArrivalsResult(
                            stationID: request.station.id,
                            generation: request.generation,
                            arrivals: snapshot.arrivals,
                            fetchedAt: snapshot.fetchedAt,
                            errorDescription: nil
                        )
                    } catch {
                        return NearbyArrivalsResult(
                            stationID: request.station.id,
                            generation: request.generation,
                            arrivals: [],
                            fetchedAt: nil,
                            errorDescription: LiveDepartureWaitingCopy.message
                        )
                    }
                }
            }

            for await result in group {
                guard nearbyArrivalsGenerationByStationID[result.stationID] == result.generation,
                      !Task.isCancelled else { continue }
                nearbyArrivalsLoadingStationIDs.remove(result.stationID)
                if let errorDescription = result.errorDescription {
                    if let updatedAt = nearbyArrivalsUpdatedAtByStationID[result.stationID],
                       Date.now.timeIntervalSince(updatedAt) >= Self.nearbyArrivalsStaleLifetime {
                        nearbyArrivalsByStationID[result.stationID] = nil
                        nearbyArrivalsUpdatedAtByStationID[result.stationID] = nil
                    }
                    nearbyArrivalsErrorsByStationID[result.stationID] = errorDescription
                } else {
                    nearbyArrivalsByStationID[result.stationID] = result.arrivals
                    nearbyArrivalsUpdatedAtByStationID[result.stationID] = result.fetchedAt
                    nearbyArrivalsErrorsByStationID[result.stationID] = nil
                }
            }
        }
    }

    func select(disruption: ResolvedDisruption) {
        let mapFocus = MapDisruptionFocus(disruption: disruption, graph: graph)
        selectedMapNetworkStat = nil
        clearStationSelection()
        selectedTrainID = nil
        selectedDisruptionID = disruption.id
        selectedEngineeringWorkID = engineeringWork(
            matchingProjectedDisruptionID: disruption.id
        )?.id
        selectedLineID = disruption.lineID
        focusedSegmentIDs = mapFocus.segmentIDs
        focusedStationIDs = mapFocus.stationIDs
        focusedLineIDs = mapFocus.lineIDs
        focusedResolutionConfidence = mapFocus.confidence
        disruptionDisplayMode = .issues
        disruptionSelectionGeneration &+= 1
    }

    func toggleMapNetworkStat(_ filter: MapNetworkStatFilter) {
        if let disruptionScope = MapDisruptionHighlightScope(filter: filter),
           selectedMapNetworkStat != filter {
            setDisruptionHighlightScope(disruptionScope)
            return
        }
        clearMapSelection()
        disruptionDisplayMode = .normal
        selectedMapNetworkStat = selectedMapNetworkStat == filter ? nil : filter
    }

    func focus(on work: EngineeringWork, in tab: AppTab) {
        let workIsInSelectedPlannedDay = !isViewingLiveStatus
            && !LondonRailDate.works(
                [work],
                overlapping: selectedDisruptionDate
            ).isEmpty
        clearMapSelection()
        if !workIsInSelectedPlannedDay {
            disruptionDateSelection = .custom(work.startDate)
        }
        let workDate = selectedDisruptionDate
        let matchingWindows = Set(DisruptionTimeWindow.allCases.filter { window in
            !LondonRailDate.works(
                [work],
                overlappingAny: [window],
                on: workDate
            ).isEmpty
        })
        selectedDisruptionTimeWindows.formUnion(matchingWindows)
        selectedTab = tab
        selectedTrainID = nil
        selectedEngineeringWorkID = work.id
        selectedDisruptionID = nil
        selectedLineID = work.lineIDs.first
        focusedSegmentIDs = work.affectedSegmentIDs
        focusedStationIDs = work.affectedStationIDs
        focusedLineIDs = Set(work.lineIDs)
        focusedResolutionConfidence = work.confidence
        disruptionDisplayMode = .issues
    }

    func clearMapSelection() {
        clearStationSelection()
        selectedTrainID = nil
        selectedLineID = nil
        selectedDisruptionID = nil
        selectedEngineeringWorkID = nil
        focusedSegmentIDs = []
        focusedStationIDs = []
        focusedLineIDs = []
        focusedResolutionConfidence = nil
    }

    func setActive(_ active: Bool) {
        appIsActive = active
        if active {
            startStatusPolling(refreshImmediately: true)
            updateLiveTrainPollingVisibility()
            updateSelectedStationArrivalsVisibility()
        } else {
            statusPollingTask?.cancel()
            statusPollingTask = nil
            trainPollingTask?.cancel()
            trainPollingTask = nil
            cancelTrainRefresh()
            cancelStationArrivalsPolling()
            cancelStationArrivalsRefresh()
        }
    }

    func handleMemoryWarning() {
        trainPollingTask?.cancel()
        trainPollingTask = nil
        cancelTrainRefresh()
        cancelStationArrivalsPolling()
        cancelStationArrivalsRefresh()
        showLiveTrains = false
        selectedTrainID = nil
        liveTrains.removeAll(keepingCapacity: false)
        activeTrainCounts = ActiveTrainCounts()
        stationArrivals.removeAll(keepingCapacity: false)
        stationArrivalsUpdatedAt = nil
        nearbyArrivalsByStationID.removeAll(keepingCapacity: false)
        nearbyArrivalsUpdatedAtByStationID.removeAll(keepingCapacity: false)
        nearbyArrivalsLoadingStationIDs.removeAll(keepingCapacity: false)
        nearbyArrivalsErrorsByStationID.removeAll(keepingCapacity: false)
        nearbyArrivalsGenerationByStationID.removeAll(keepingCapacity: false)
        updateSelectedStationArrivalsVisibility()
    }

    private func resolvedDisruptions(for work: EngineeringWork) -> [ResolvedDisruption] {
        let segmentsByID = graph?.segmentsByID
        return work.lineIDs.map { lineID in
            let segmentIDs: Set<String>
            if let segmentsByID {
                segmentIDs = Set(work.affectedSegmentIDs.filter {
                    segmentsByID[$0]?.lineID == lineID
                })
            } else {
                segmentIDs = work.affectedSegmentIDs
            }

            return ResolvedDisruption(
                id: "planned:\(work.id):\(lineID.rawValue)",
                lineID: lineID,
                title: work.title,
                reason: work.detail,
                severity: 5,
                affectedStationIDs: work.affectedStationIDs,
                affectedSegmentIDs: segmentIDs,
                confidence: work.confidence
            )
        }
    }

    private func engineeringWork(
        matchingProjectedDisruptionID disruptionID: String
    ) -> EngineeringWork? {
        selectedEngineeringWorks.first { work in
            resolvedDisruptions(for: work).contains { $0.id == disruptionID }
        }
    }

    private func startStatusPolling(refreshImmediately: Bool = false) {
        guard appIsActive, statusPollingTask == nil, statusService != nil else { return }
        statusPollingTask = Task { [weak self] in
            if refreshImmediately {
                await self?.refreshStatus()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
    }

    private func startTrainPolling() {
        guard appIsActive,
              selectedTab == .map,
              trainPollingTask == nil,
              trainService != nil else { return }
        trainPollingTask = Task { [weak self] in
            await self?.refreshTrains()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.refreshTrains()
            }
        }
    }

    private func requestTrainRefresh() {
        guard showLiveTrains,
              selectedTab == .map,
              trainRetryTask == nil,
              let trainService else { return }

        let requestedFilter = trainLineFilter
        if trainRefreshTask != nil, trainRefreshFilter == requestedFilter {
            return
        }

        trainRefreshTask?.cancel()
        trainRefreshGeneration &+= 1
        let generation = trainRefreshGeneration
        trainRefreshFilter = requestedFilter

        trainRefreshTask = Task { [weak self] in
            defer { self?.finishTrainRefresh(generation: generation) }
            do {
                let trains = try await trainService.fetch(lineIDs: requestedFilter)
                guard !Task.isCancelled else { return }
                self?.applyTrainRefresh(
                    trains,
                    requestedFilter: requestedFilter,
                    generation: generation
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.handleTrainRefreshFailure(
                    error,
                    requestedFilter: requestedFilter,
                    generation: generation
                )
            }
        }
    }

    private func applyTrainRefresh(
        _ trains: [LiveTubeTrain],
        requestedFilter: Set<TubeLineID>,
        generation: UInt
    ) {
        guard generation == trainRefreshGeneration,
              showLiveTrains,
              requestedFilter == trainLineFilter else {
            return
        }
        cancelScheduledTrainRetry()
        let previousTrains = liveTrains
        let previousByID = Dictionary(
            uniqueKeysWithValues: previousTrains.map { ($0.id, $0) }
        )
        if let selectedTrainID,
           let previous = previousByID[selectedTrainID],
           let incoming = trains.first(where: { $0.id == selectedTrainID }),
           !LiveTrainSnapshotReconciler.isContinuousJourney(
               from: previous,
               to: incoming,
               at: incoming.updatedAt
           ) {
            self.selectedTrainID = nil
        }
        let reconciledTrains = LiveTrainSnapshotReconciler.reconcile(
            previous: previousTrains,
            incoming: trains,
            at: trains.map(\.updatedAt).max() ?? .now,
            segmentsByID: graph?.segmentsByID ?? [:],
            requestedLineIDs: requestedFilter
        )
        liveTrains = reconciledTrains
        if let selectedTrainID,
           !reconciledTrains.contains(where: { $0.id == selectedTrainID }) {
            self.selectedTrainID = nil
        }
        activeTrainCounts.update(
            with: reconciledTrains,
            requestedLineIDs: requestedFilter
        )
        #if DEBUG
        print("[TubeTrack] live trains resolved=\(reconciledTrains.count) filter=\(requestedFilter.map(\.rawValue).sorted())")
        #endif
    }

    private func handleTrainRefreshFailure(
        _ error: Error,
        requestedFilter: Set<TubeLineID>,
        generation: UInt
    ) {
        guard generation == trainRefreshGeneration,
              showLiveTrains,
              requestedFilter == trainLineFilter else {
            return
        }

        if case let TubeTrackAPIClientError.rateLimited(retryAfter) = error {
            isLoadingLiveTrains = liveTrains.isEmpty
            scheduleTrainRetry(after: retryAfter)
            return
        }

        // Live trains are supplemental. Keep the last positions until they
        // naturally become stale instead of replacing the whole map error state.
        let freshTrains = liveTrains.filter { Date.now.timeIntervalSince($0.updatedAt) < 90 }
        if freshTrains.count != liveTrains.count {
            liveTrains = freshTrains
            activeTrainCounts.update(
                with: freshTrains,
                requestedLineIDs: requestedFilter
            )
        }
    }

    private func finishTrainRefresh(generation: UInt) {
        guard generation == trainRefreshGeneration else { return }
        trainRefreshTask = nil
        trainRefreshFilter = nil
        isLoadingLiveTrains = showLiveTrains
            && liveTrains.isEmpty
            && trainRetryTask != nil
    }

    private func cancelTrainRefresh() {
        trainRefreshGeneration &+= 1
        trainRefreshTask?.cancel()
        trainRefreshTask = nil
        trainRefreshFilter = nil
        cancelScheduledTrainRetry()
        isLoadingLiveTrains = false
    }

    private func scheduleTrainRetry(after retryAfter: Date?) {
        cancelScheduledTrainRetry()
        let retryDate = (retryAfter ?? Date.now.addingTimeInterval(60))
            .addingTimeInterval(0.5)
        liveTrainRetryAfter = retryDate
        trainRetryTask = Task { [weak self] in
            let delay = max(0, retryDate.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.resumeTrainRefresh(after: retryDate)
        }
    }

    private func resumeTrainRefresh(after retryDate: Date) {
        guard liveTrainRetryAfter == retryDate else { return }
        trainRetryTask = nil
        liveTrainRetryAfter = nil
        guard appIsActive, selectedTab == .map, showLiveTrains else {
            isLoadingLiveTrains = false
            return
        }
        isLoadingLiveTrains = liveTrains.isEmpty
        requestTrainRefresh()
    }

    private func cancelScheduledTrainRetry() {
        trainRetryTask?.cancel()
        trainRetryTask = nil
        liveTrainRetryAfter = nil
    }

    private func requestStationArrivals(for stationID: String) {
        guard appIsActive,
              selectedTab == .map,
              stationArrivalsService != nil,
              selectedStationID == stationID else {
            return
        }

        stationArrivalsTask?.cancel()
        stationArrivalsGeneration &+= 1
        let generation = stationArrivalsGeneration
        isRefreshingStationArrivals = true
        stationArrivalsTask = Task { [weak self] in
            await self?.loadStationArrivals(for: stationID, generation: generation)
        }
    }

    private func startStationArrivalsPolling() {
        guard appIsActive,
              selectedTab == .map,
              selectedStationID != nil,
              stationArrivalsService != nil,
              stationArrivalsPollingTask == nil else {
            return
        }

        stationArrivalsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      let stationID = self.selectedStationID else {
                    return
                }
                guard self.stationArrivalsTask == nil else { continue }
                self.requestStationArrivals(for: stationID)
            }
        }
    }

    private func loadStationArrivals(for stationID: String, generation: UInt) async {
        defer { finishStationArrivalsRefresh(generation: generation) }
        guard let stationArrivalsService,
              let station = graph?.stationsByID[stationID] else {
            return
        }

        do {
            let stopIDs = graph?.stations(inSamePlaceAs: station).map(\.id) ?? [stationID]
            let arrivals = try await stationArrivalsService.fetch(stationIDs: stopIDs)
            guard !Task.isCancelled,
                  generation == stationArrivalsGeneration,
                  selectedStationID == stationID else {
                return
            }
            stationArrivals = arrivals
            stationArrivalsUpdatedAt = .now
            stationArrivalsError = nil
        } catch {
            guard !Task.isCancelled,
                  generation == stationArrivalsGeneration,
                  selectedStationID == stationID else {
                return
            }
            stationArrivalsError = LiveDepartureWaitingCopy.message
        }
    }

    private func finishStationArrivalsRefresh(generation: UInt) {
        guard generation == stationArrivalsGeneration else { return }
        stationArrivalsTask = nil
        isRefreshingStationArrivals = false
    }

    private func cancelStationArrivalsRefresh() {
        stationArrivalsGeneration &+= 1
        stationArrivalsTask?.cancel()
        stationArrivalsTask = nil
        isRefreshingStationArrivals = false
    }

    private func cancelStationArrivalsPolling() {
        stationArrivalsPollingTask?.cancel()
        stationArrivalsPollingTask = nil
    }

    private func updateLiveTrainPollingVisibility() {
        guard appIsActive, !isGameActive, selectedTab == .map, showLiveTrains else {
            trainPollingTask?.cancel()
            trainPollingTask = nil
            cancelTrainRefresh()
            return
        }
        isLoadingLiveTrains = liveTrains.isEmpty
        startTrainPolling()
    }

    private func updateSelectedStationArrivalsVisibility() {
        guard appIsActive,
              !isGameActive,
              selectedTab == .map,
              let selectedStationID else {
            cancelStationArrivalsPolling()
            cancelStationArrivalsRefresh()
            return
        }
        requestStationArrivals(for: selectedStationID)
        startStationArrivalsPolling()
    }
}

struct ActiveTrainCounts: Equatable, Sendable {
    private(set) var byLineID: [TubeLineID: Int] = [:]

    var total: Int {
        byLineID.values.reduce(0, +)
    }

    func count(for lineID: TubeLineID) -> Int {
        byLineID[lineID, default: 0]
    }

    func activeLineCount(excluding excludedLineIDs: Set<TubeLineID> = []) -> Int {
        byLineID.reduce(into: 0) { count, entry in
            guard entry.value > 0, !excludedLineIDs.contains(entry.key) else { return }
            count += 1
        }
    }

    mutating func update(
        with trains: [LiveTubeTrain],
        requestedLineIDs: Set<TubeLineID>
    ) {
        let incomingCounts = Dictionary(grouping: trains, by: \.lineID)
            .mapValues(\.count)

        guard !requestedLineIDs.isEmpty else {
            byLineID = incomingCounts
            return
        }

        for lineID in requestedLineIDs {
            byLineID[lineID] = incomingCounts[lineID, default: 0]
        }
    }
}

private struct NearbyArrivalsResult: Sendable {
    let stationID: String
    let generation: UInt
    let arrivals: [TfLArrivalPrediction]
    let fetchedAt: Date?
    let errorDescription: String?
}

private struct NearbyArrivalsRequest: Sendable {
    let station: TubeStation
    let stopIDs: [String]
    let generation: UInt
}
