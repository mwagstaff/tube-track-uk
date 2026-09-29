import Foundation
import Observation
import TubeTrackCore

/// The service status of a National Rail operator the app does not draw,
/// such as Southern at a shared Thameslink station.
struct NationalRailOperatorStatus: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let lineStatuses: [TfLStatusEntry]

    var issue: TfLStatusEntry? { lineStatuses.first(where: \.isActionableIssue) }

    var headline: String {
        issue?.statusSeverityDescription
            ?? lineStatuses.first?.statusSeverityDescription
            ?? "Status unavailable"
    }
}

/// Bundled from Tools/NationalRailOperatorsBuilder: which operators call at
/// each of the app's 910G stop points.
struct NationalRailOperatorIndex: Decodable, Sendable {
    struct Operator: Decodable, Sendable {
        let id: String
        let name: String
        let stationIDs: [String]
    }

    let operators: [Operator]

    static let empty = NationalRailOperatorIndex(operators: [])
}

private struct NationalRailStatusSnapshot: Codable, Sendable {
    let statuses: [NationalRailOperatorStatus]
    let updatedAt: Date
}

@MainActor @Observable
final class NationalRailStatusState {
    private static let freshLifetime: TimeInterval = 60
    private static let cacheName = "national-rail-status.json"

    private(set) var statuses: [NationalRailOperatorStatus] = []
    private(set) var updatedAt: Date?
    private(set) var isStale = true
    @ObservationIgnored private let client: TubeTrackAPIClient
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private let operatorIDsByStation: [String: Set<String>]
    @ObservationIgnored private let operatorNames: [String: String]
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var isRefreshing = false

    init(
        client: TubeTrackAPIClient,
        cache: SnapshotCache = SnapshotCache(),
        index: NationalRailOperatorIndex = RiverBundle.load("NationalRailOperators", as: NationalRailOperatorIndex.self) ?? .empty
    ) {
        self.client = client
        self.cache = cache
        var byStation: [String: Set<String>] = [:]
        for entry in index.operators {
            for stationID in entry.stationIDs { byStation[stationID, default: []].insert(entry.id) }
        }
        operatorIDsByStation = byStation
        operatorNames = Dictionary(uniqueKeysWithValues: index.operators.map { ($0.id, $0.name) })
    }

    /// Operators that call at any of these stop points, with their status when
    /// it is known, in name order.
    func operators(atStationIDs stationIDs: [String]) -> [NationalRailOperatorStatus] {
        let ids = stationIDs.reduce(into: Set<String>()) { result, stationID in
            result.formUnion(operatorIDsByStation[stationID] ?? [])
        }
        return ids.map { id in
            statuses.first { $0.id == id }
                ?? NationalRailOperatorStatus(id: id, name: operatorNames[id] ?? id, lineStatuses: [])
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Disrupted operators that serve at least one station on the map.
    var disruptedOperators: [NationalRailOperatorStatus] {
        statuses.filter { operatorNames[$0.id] != nil && $0.issue != nil }
    }

    func refresh(forceRefresh: Bool = false) async {
        if !restored {
            restored = true
            if let saved = try? await cache.load(NationalRailStatusSnapshot.self, named: Self.cacheName) {
                statuses = saved.statuses
                updatedAt = saved.updatedAt
            }
        }
        guard !isRefreshing else { return }
        if !forceRefresh, !isStale, let updatedAt,
           Date.now.timeIntervalSince(updatedAt) < Self.freshLifetime {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response: TubeTrackAPIResponse<LossyList<NationalRailOperatorStatus>> = try await client.getSnapshot(
                "/api/v1/national-rail/status",
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }
            if statuses != response.data.elements { statuses = response.data.elements }
            updatedAt = response.updatedAt
            isStale = response.stale
            try? await cache.save(
                NationalRailStatusSnapshot(statuses: statuses, updatedAt: response.updatedAt),
                named: Self.cacheName
            )
        } catch {
            isStale = true
        }
    }
}
