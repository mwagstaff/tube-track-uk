import Foundation
import Observation

@MainActor @Observable
final class RiverBusState {
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "riverBusEnabled")
            if !isEnabled { clearSelection(); boats = []; estimator = RiverBoatEstimator() }
        }
    }
    var showsBoats: Bool {
        didSet {
            defaults.set(showsBoats, forKey: "riverBoatsEnabled")
            if !showsBoats { clearFleet() }
        }
    }
    private(set) var network: RiverNetwork {
        didSet {
            cachedGeographicSegments = nil
            geographicBoatPaths = RiverBoatPathCache()
        }
    }
    private(set) var statuses: [RiverLineStatus] = []
    private(set) var statusUpdatedAt: Date?
    private(set) var statusStale = false
    private(set) var boats: [EstimatedRiverBoat] = []
    private(set) var boards: [String: RiverBoardSnapshot] = [:]
    var selectedPierId: String?
    var selectedBoatId: String?
    var selectedLineId: String? { didSet { cachedGeographicSegments = nil } }
    @ObservationIgnored var cachedGeographicSegments: [RiverGeographicSegment]?
    @ObservationIgnored var geographicBoatPaths = RiverBoatPathCache()
    @ObservationIgnored var schematicBoatPaths = RiverBoatPathCache()
    @ObservationIgnored var schematicBoatDocumentKey: String?
    var selectionGeneration = 0
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var fleetError: String?
    let anchors: [RiverSchematicAnchor]
    let geometry: RiverMapGeometry
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: TubeTrackAPIClient
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private var estimator = RiverBoatEstimator()
    @ObservationIgnored private var legacyFleetUntil: Date?
    @ObservationIgnored private var networkUpdatedAt: Date?
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var boardPolicies: [String: RiverBoardRefreshPolicy] = [:]

    init(client: TubeTrackAPIClient, defaults: UserDefaults = .standard, cache: SnapshotCache = SnapshotCache()) {
        self.client = client; self.defaults = defaults; self.cache = cache
        isEnabled = defaults.object(forKey: "riverBusEnabled") as? Bool ?? true
        showsBoats = defaults.object(forKey: "riverBoatsEnabled") as? Bool ?? true
        network = RiverBundle.load("RiverNetwork", as: RiverNetwork.self) ?? .empty
        anchors = RiverBundle.load("RiverSchematic", as: [RiverSchematicAnchor].self) ?? []
        geometry = RiverMapGeometry()
    }

    var selectedPier: RiverPier? { selectedPierId.flatMap { network.pier($0) } }
    var selectedBoat: EstimatedRiverBoat? { boats.first { $0.id == selectedBoatId } }
    var selectedBoard: RiverBoardSnapshot? { selectedPierId.flatMap { boards[$0] } }
    var hasSelection: Bool { selectedPierId != nil || selectedBoatId != nil }
    var filteredBoats: [EstimatedRiverBoat] { boats.filter { selectedLineId == nil || $0.lineId == selectedLineId } }
    var filteredPiers: [RiverPier] { network.piers.filter { selectedLineId == nil || $0.lineIds.contains(selectedLineId!) || $0.id == selectedPierId } }
    var issueCount: Int { statuses.filter { $0.entries.contains { $0.severity != 10 && $0.severity != 18 } }.count }

    func clearSelection() { selectedPierId = nil; selectedBoatId = nil; error = nil }
    func select(_ pier: RiverPier) {
        isEnabled = true; selectedBoatId = nil; selectedPierId = pier.id
        if let selectedLineId, !pier.lineIds.contains(selectedLineId) { self.selectedLineId = nil }
        selectionGeneration &+= 1; error = nil
    }
    func select(_ boat: EstimatedRiverBoat) {
        selectedPierId = nil; selectedBoatId = boat.id; selectionGeneration &+= 1
    }

    func restore() async {
        if let restoration { await restoration.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreCache()
        }
        restoration = task
        await task.value
    }

    private func restoreCache() async {
        if let saved = try? await cache.load(RiverNetwork.self, named: "river-network.json"), !saved.piers.isEmpty {
            network = saved
        }
        if let saved = try? await cache.load([String: RiverBoardSnapshot].self, named: "river-boards.json") {
            boards.merge(saved.filter { Date.now.timeIntervalSince($0.value.updatedAt) < 300 }
                .mapValues { .init(predictions: $0.predictions, updatedAt: $0.updatedAt, stale: true) }) { current, _ in current }
        }
        if let saved = try? await cache.load(RiverStatusSnapshot.self, named: "river-status.json") {
            statuses = saved.statuses; statusUpdatedAt = saved.updatedAt; statusStale = true
        }
    }

    func poll() async {
        await restore()
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    func refresh() async {
        guard isEnabled, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        if networkUpdatedAt == nil || Date.now.timeIntervalSince(networkUpdatedAt!) > 86_400 {
            do {
                let response: TubeTrackAPIResponse<RiverNetwork> = try await client.getSnapshot("/api/v1/river/network")
                try Task.checkCancellation()
                if !response.data.piers.isEmpty {
                    network = response.data; networkUpdatedAt = response.updatedAt
                    try? await cache.save(network, named: "river-network.json")
                }
            } catch { if Task.isCancelled { return } }
        }
        guard !Task.isCancelled else { return }
        async let board: Void = refreshBoard()
        async let fleet: Void = refreshFleet()
        async let status: Void = refreshStatus()
        _ = await (board, fleet, status)
    }

    private func refreshBoard() async {
        guard let id = selectedPierId else { return }
        do {
            let response: TubeTrackAPIResponse<[RiverPrediction]> = try await client.getSnapshot("/api/v1/river/arrivals/\(id)")
            try Task.checkCancellation()
            guard selectedPierId == id else { return }
            let incoming = RiverBoardSnapshot(predictions: response.data, updatedAt: response.updatedAt, stale: response.stale)
            boards[id] = boardPolicies[id, default: RiverBoardRefreshPolicy()].resolve(incoming, previous: boards[id], now: .now)
            error = boards[id]?.stale == true ? "Waiting for confirmed departure updates" : nil
            boards = boards.filter { Date.now.timeIntervalSince($0.value.updatedAt) < 300 }
            try? await cache.save(boards, named: "river-boards.json")
        } catch {
            guard !Task.isCancelled, selectedPierId == id else { return }
            self.error = "Live departures are temporarily unavailable"
            if let old = boards[id] {
                boards[id] = .init(predictions: old.predictions, updatedAt: old.updatedAt, stale: true)
            }
        }
    }

    private func refreshFleet() async {
        guard showsBoats else { clearFleet(); return }
        do {
            if legacyFleetUntil.map({ $0 > .now }) != true {
                do {
                    let response: TubeTrackAPIResponse<[EstimatedRiverBoat]> = try await client.getSnapshot("/api/v1/river/boats")
                    try Task.checkCancellation()
                    guard showsBoats, isEnabled else { return }
                    let fresh = response.data.filter { boat in
                        boat.progress(at: .now) != nil && network.pier(boat.previousPierId) != nil
                            && network.pier(boat.nextPierId) != nil
                    }
                    // Expiration is per vessel, including held server estimates;
                    // response receipt time cannot make an old boat fresh.
                    if !response.stale || !fresh.isEmpty { boats = fresh }
                    else { boats = boats.filter { $0.progress(at: .now) != nil } }
                    fleetError = response.stale ? "Boat estimates are temporarily delayed" : nil
                    reconcileBoatSelection()
                    return
                } catch TubeTrackAPIClientError.httpStatus(404) {
                    // Allow a staged API/app rollout. Probe for the shared
                    // estimator again in five minutes, not on every refresh.
                    legacyFleetUntil = .now.addingTimeInterval(300)
                }
            }
            let response: TubeTrackAPIResponse<[RiverPrediction]> = try await client.getSnapshot("/api/v1/river/live")
            try Task.checkCancellation()
            guard showsBoats, isEnabled else { return }
            let usable = !response.stale && Date.now.timeIntervalSince(response.updatedAt) <= 90
            boats = estimator.update(usable ? response.data : [], network: network, at: .now)
            fleetError = usable ? nil : "Boat estimates are temporarily delayed"
            reconcileBoatSelection()
        } catch {
            guard !Task.isCancelled else { return }
            // A transport error must not restart observation history or reset
            // the age of positions that are still within their original window.
            boats = boats.filter { $0.progress(at: .now) != nil }
            reconcileBoatSelection()
            fleetError = "Boat estimates are temporarily unavailable"
        }
    }

    private func reconcileBoatSelection() {
        if selectedBoatId != nil && selectedBoat == nil { selectedBoatId = nil }
    }

    private func clearFleet() {
        boats = []; selectedBoatId = nil; estimator = RiverBoatEstimator()
    }

    private func refreshStatus() async {
        guard statusUpdatedAt == nil || Date.now.timeIntervalSince(statusUpdatedAt!) >= 60 else { return }
        do {
            let response: TubeTrackAPIResponse<[RiverLineStatus]> = try await client.getSnapshot("/api/v1/river/status")
            try Task.checkCancellation()
            statuses = response.data; statusUpdatedAt = response.updatedAt; statusStale = response.stale
            try? await cache.save(RiverStatusSnapshot(statuses: statuses, updatedAt: response.updatedAt), named: "river-status.json")
        } catch { if !Task.isCancelled { statusStale = true } }
    }
}
