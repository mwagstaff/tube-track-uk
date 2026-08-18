import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case map
    case realWorld
    case works
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .map: "Map"
        case .realWorld: "Real World"
        case .works: "Works"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .map: "map"
        case .realWorld: "globe.europe.africa"
        case .works: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }
}

enum DisruptionDisplayMode: String, CaseIterable {
    case normal
    case issues
}

@MainActor
@Observable
final class TubeAppState {
    var selectedTab: AppTab = .map
    var disruptionDisplayMode: DisruptionDisplayMode = .normal
    var showLiveTrains = false
    var trainLineFilter: Set<TubeLineID> = []
    var selectedLineID: TubeLineID?
    var selectedStationID: String?
    var selectedDisruptionID: String?
    var focusedSegmentIDs: Set<String> = []
    var focusedStationIDs: Set<String> = []
    var preferredColorScheme: ColorScheme?

    var graph: TubeGraph?
    var statuses: [TfLLineStatus] = []
    var disruptions: [ResolvedDisruption] = []
    var engineeringWorks: [EngineeringWork] = []
    var liveTrains: [LiveTubeTrain] = []
    var stationArrivals: [TfLArrivalPrediction] = []
    var isRefreshingStationArrivals = false
    var stationArrivalsError: String?
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
    @ObservationIgnored private var statusPollingTask: Task<Void, Never>?
    @ObservationIgnored private var trainPollingTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-DebugTab"), arguments.indices.contains(flag + 1),
           let tab = AppTab(rawValue: arguments[flag + 1]) {
            selectedTab = tab
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
        disruptions.first { $0.id == selectedDisruptionID }
    }

    var activeAffectedSegmentIDs: Set<String> {
        if !focusedSegmentIDs.isEmpty { return focusedSegmentIDs }
        if let selectedDisruption { return selectedDisruption.affectedSegmentIDs }
        return Set(disruptions.flatMap(\.affectedSegmentIDs))
    }

    var activeAffectedStationIDs: Set<String> {
        if !focusedStationIDs.isEmpty { return focusedStationIDs }
        if let selectedDisruption { return selectedDisruption.affectedStationIDs }
        return Set(disruptions.flatMap(\.affectedStationIDs))
    }

    var currentIssueCount: Int { disruptions.count }

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
            await refreshWorks()
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
            statuses = snapshot.statuses
            disruptions = snapshot.disruptions
            #if DEBUG
            for disruption in snapshot.disruptions {
                print("[TubeTrack] disruption=\(disruption.lineID.rawValue) segments=\(disruption.affectedSegmentIDs.count) confidence=\(disruption.confidence.rawValue)")
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
        } catch {
            worksError = error.localizedDescription
        }
    }

    func setLiveTrains(_ enabled: Bool) {
        showLiveTrains = enabled
        if enabled {
            startTrainPolling()
        } else {
            trainPollingTask?.cancel()
            trainPollingTask = nil
            liveTrains = []
        }
    }

    func setTrainFilter(_ lineID: TubeLineID?) {
        trainLineFilter = lineID.map { [$0] } ?? []
        if showLiveTrains {
            Task { await refreshTrains() }
        }
    }

    func select(station: TubeStation) {
        selectedStationID = station.id
        selectedLineID = nil
        selectedDisruptionID = nil
        stationArrivals = []
        stationArrivalsError = nil
        Task { await refreshArrivals(for: station.id) }
    }

    func clearStationSelection() {
        selectedStationID = nil
        stationArrivals = []
        stationArrivalsError = nil
    }

    func refreshArrivals(for stationID: String) async {
        guard let stationArrivalsService, selectedStationID == stationID, !isRefreshingStationArrivals else { return }
        isRefreshingStationArrivals = true
        defer { isRefreshingStationArrivals = false }
        do {
            let arrivals = try await stationArrivalsService.fetch(stationID: stationID)
            guard selectedStationID == stationID else { return }
            stationArrivals = Array(arrivals.prefix(12))
            stationArrivalsError = nil
        } catch {
            guard selectedStationID == stationID else { return }
            stationArrivalsError = error.localizedDescription
        }
    }

    func refreshTrains() async {
        guard showLiveTrains, let trainService else { return }
        do {
            liveTrains = try await trainService.fetch(lineIDs: trainLineFilter)
            #if DEBUG
            print("[TubeTrack] live trains resolved=\(liveTrains.count) filter=\(trainLineFilter.map(\.rawValue).sorted())")
            #endif
        } catch {
            // Live trains are supplemental. Keep the last positions until they
            // naturally become stale instead of replacing the whole map error state.
            liveTrains = liveTrains.filter { Date.now.timeIntervalSince($0.updatedAt) < 90 }
        }
    }

    func select(disruption: ResolvedDisruption) {
        selectedDisruptionID = disruption.id
        selectedLineID = disruption.lineID
        selectedStationID = nil
        focusedSegmentIDs = []
        focusedStationIDs = []
        disruptionDisplayMode = .issues
    }

    func focus(on work: EngineeringWork, in tab: AppTab) {
        selectedTab = tab
        selectedDisruptionID = nil
        selectedLineID = work.lineIDs.first
        focusedSegmentIDs = work.affectedSegmentIDs
        focusedStationIDs = work.affectedStationIDs
        disruptionDisplayMode = .issues
    }

    func clearMapSelection() {
        clearStationSelection()
        selectedLineID = nil
        selectedDisruptionID = nil
        focusedSegmentIDs = []
        focusedStationIDs = []
    }

    func setActive(_ active: Bool) {
        if active {
            startStatusPolling()
            if showLiveTrains { startTrainPolling() }
        } else {
            statusPollingTask?.cancel()
            statusPollingTask = nil
            trainPollingTask?.cancel()
            trainPollingTask = nil
        }
    }

    private func startStatusPolling() {
        guard statusPollingTask == nil else { return }
        statusPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
    }

    private func startTrainPolling() {
        guard trainPollingTask == nil else { return }
        trainPollingTask = Task { [weak self] in
            await self?.refreshTrains()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await self?.refreshTrains()
            }
        }
    }
}
