import Foundation
import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case map
    case nearMe
    case works
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .map: "Map"
        case .nearMe: "Near Me"
        case .works: "Works"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .map: "map"
        case .nearMe: "location.fill"
        case .works: "wrench.and.screwdriver"
        case .about: "info.circle"
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

    var selectedTab: AppTab = .map {
        didSet {
            guard selectedTab != oldValue else { return }
            updateSelectedStationArrivalsVisibility()
        }
    }
    var mapPresentationMode: MapPresentationMode = .beck
    var sharedMapViewport: SharedMapViewport?
    var beckMapCameraSnapshot: BeckMapCameraSnapshot?
    var disruptionDisplayMode: DisruptionDisplayMode = .normal
    var disruptionDateSelection: DisruptionDateSelection = .today
    var selectedDisruptionTimeWindows = DisruptionTimeWindow.defaultSelected
    var highlightedDisruptionCategories = DisruptionCategory.defaultHighlighted
    var showLiveTrains = false
    var isLoadingLiveTrains = false
    var trainLineFilter: Set<TubeLineID> = []
    var selectedLineID: TubeLineID?
    var selectedStationID: String?
    private(set) var stationSelectionGeneration = 0
    var selectedDisruptionID: String?
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

    var graph: TubeGraph?
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

    @ObservationIgnored private var statusService: TubeStatusService?
    @ObservationIgnored private var worksService: EngineeringWorksService?
    @ObservationIgnored private var trainService: TubeTrainService?
    @ObservationIgnored private var stationArrivalsService: StationArrivalsService?
    @ObservationIgnored private var stationArrivalsTask: Task<Void, Never>?
    @ObservationIgnored private var stationArrivalsPollingTask: Task<Void, Never>?
    @ObservationIgnored private var stationArrivalsGeneration: UInt = 0
    @ObservationIgnored private var nearbyArrivalsGenerationByStationID: [String: UInt] = [:]
    @ObservationIgnored private var statusPollingTask: Task<Void, Never>?
    @ObservationIgnored private var trainPollingTask: Task<Void, Never>?
    @ObservationIgnored private var trainRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var trainRefreshFilter: Set<TubeLineID>?
    @ObservationIgnored private var trainRefreshGeneration: UInt = 0
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    var activeAffectedSegmentIDs: Set<String> {
        if hasFocusedMapSection { return focusedSegmentIDs }
        if let selectedDisruption { return selectedDisruption.affectedSegmentIDs }
        return Set(highlightedDisruptions.flatMap(\.affectedSegmentIDs))
    }

    var activeAffectedStationIDs: Set<String> {
        if hasFocusedMapSection { return focusedStationIDs }
        if let selectedDisruption { return selectedDisruption.affectedStationIDs }
        return Set(highlightedDisruptions.flatMap(\.affectedStationIDs))
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
            let loadedGraph = try TubeGraph.bundled()
            graph = loadedGraph
            let repository = TubeNetworkRepository(graph: loadedGraph)
            let client = TfLClient()
            let cache = SnapshotCache()
            statusService = TubeStatusService(client: client, cache: cache, repository: repository)
            worksService = EngineeringWorksService(client: client, cache: cache, repository: repository)
            trainService = TubeTrainService(client: client, repository: repository)
            stationArrivalsService = StationArrivalsService(client: client)
            isLoadingGraph = false
            await refreshStatus()
            guard !Task.isCancelled else { return }
            await refreshWorks()
            guard appIsActive, !Task.isCancelled else { return }
            startStatusPolling()
            if showLiveTrains { startTrainPolling() }
        } catch {
            isLoadingGraph = false
            statusError = error.localizedDescription
        }
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

    func refreshWorks() async {
        guard let worksService, !isRefreshingWorks else { return }
        isRefreshingWorks = true
        defer { isRefreshingWorks = false }
        do {
            let snapshot = try await worksService.fetch()
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
            startTrainPolling()
        } else {
            trainPollingTask?.cancel()
            trainPollingTask = nil
            cancelTrainRefresh()
            liveTrains = []
            activeTrainCounts = ActiveTrainCounts()
        }
    }

    func setTrainFilter(_ lineID: TubeLineID?) {
        let newFilter = lineID.map { Set([$0]) } ?? []
        guard newFilter != trainLineFilter else { return }
        trainLineFilter = newFilter
        if showLiveTrains {
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
        if disruptionDisplayMode == .issues {
            disruptionDisplayMode = .normal
        } else {
            enableDisruptionHighlighting()
        }
    }

    func enableDisruptionHighlighting() {
        disruptionDisplayMode = .issues
        if highlightedDisruptionCategories.isEmpty {
            highlightedDisruptionCategories = DisruptionCategory.defaultHighlighted
        }
    }

    func select(station: TubeStation) {
        cancelStationArrivalsPolling()
        cancelStationArrivalsRefresh()
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

    func refreshNearbyArrivals(for stations: [TubeStation]) async {
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
                        let arrivals = try await stationArrivalsService.fetch(
                            stationIDs: request.stopIDs
                        )
                        return NearbyArrivalsResult(
                            stationID: request.station.id,
                            generation: request.generation,
                            arrivals: arrivals,
                            errorDescription: nil
                        )
                    } catch {
                        return NearbyArrivalsResult(
                            stationID: request.station.id,
                            generation: request.generation,
                            arrivals: [],
                            errorDescription: error.localizedDescription
                        )
                    }
                }
            }

            for await result in group {
                guard nearbyArrivalsGenerationByStationID[result.stationID] == result.generation,
                      !Task.isCancelled else { continue }
                nearbyArrivalsLoadingStationIDs.remove(result.stationID)
                if let errorDescription = result.errorDescription {
                    nearbyArrivalsErrorsByStationID[result.stationID] = errorDescription
                } else {
                    nearbyArrivalsByStationID[result.stationID] = result.arrivals
                    nearbyArrivalsErrorsByStationID[result.stationID] = nil
                }
            }
        }
    }

    func select(disruption: ResolvedDisruption) {
        clearStationSelection()
        selectedDisruptionID = disruption.id
        selectedEngineeringWorkID = engineeringWork(
            matchingProjectedDisruptionID: disruption.id
        )?.id
        selectedLineID = disruption.lineID
        focusedSegmentIDs = []
        focusedStationIDs = []
        focusedLineIDs = []
        focusedResolutionConfidence = nil
        disruptionDisplayMode = .issues
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
            if showLiveTrains { startTrainPolling() }
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
        liveTrains.removeAll(keepingCapacity: false)
        activeTrainCounts = ActiveTrainCounts()
        stationArrivals.removeAll(keepingCapacity: false)
        stationArrivalsUpdatedAt = nil
        nearbyArrivalsByStationID.removeAll(keepingCapacity: false)
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
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
    }

    private func startTrainPolling() {
        guard appIsActive, trainPollingTask == nil, trainService != nil else { return }
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
        guard showLiveTrains, let trainService else { return }

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
        liveTrains = trains
        activeTrainCounts.update(
            with: trains,
            requestedLineIDs: requestedFilter
        )
        #if DEBUG
        print("[TubeTrack] live trains resolved=\(trains.count) filter=\(requestedFilter.map(\.rawValue).sorted())")
        #endif
    }

    private func handleTrainRefreshFailure(
        requestedFilter: Set<TubeLineID>,
        generation: UInt
    ) {
        guard generation == trainRefreshGeneration,
              showLiveTrains,
              requestedFilter == trainLineFilter else {
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
        isLoadingLiveTrains = false
    }

    private func cancelTrainRefresh() {
        trainRefreshGeneration &+= 1
        trainRefreshTask?.cancel()
        trainRefreshTask = nil
        trainRefreshFilter = nil
        isLoadingLiveTrains = false
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
            stationArrivalsError = error.localizedDescription
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

    private func updateSelectedStationArrivalsVisibility() {
        guard appIsActive,
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
    let errorDescription: String?
}

private struct NearbyArrivalsRequest: Sendable {
    let station: TubeStation
    let stopIDs: [String]
    let generation: UInt
}
