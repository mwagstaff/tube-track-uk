import Foundation

struct TubeStatusSnapshot: Codable, Sendable {
    let statuses: [TfLLineStatus]
    let disruptions: [ResolvedDisruption]
    let fetchedAt: Date
    let cached: Bool
}

actor TubeStatusService {
    private static let freshLifetime: TimeInterval = 60

    private let client: TubeTrackAPIClient
    private let cache: SnapshotCache
    private let repository: TubeNetworkRepository
    private var latestSnapshot: TubeStatusSnapshot?

    init(client: TubeTrackAPIClient, cache: SnapshotCache, repository: TubeNetworkRepository) {
        self.client = client
        self.cache = cache
        self.repository = repository
    }

    func fetch(forceRefresh: Bool = false) async throws -> TubeStatusSnapshot {
        let now = Date.now
        if !forceRefresh,
           let latestSnapshot,
           now.timeIntervalSince(latestSnapshot.fetchedAt) < Self.freshLifetime {
            return latestSnapshot
        }
        if !forceRefresh,
           let cached = try? await cache.load(TubeStatusSnapshot.self, named: "status.json"),
           now.timeIntervalSince(cached.fetchedAt) < Self.freshLifetime {
            let snapshot = TubeStatusSnapshot(
                statuses: cached.statuses,
                disruptions: cached.disruptions,
                fetchedAt: cached.fetchedAt,
                cached: true
            )
            latestSnapshot = snapshot
            return snapshot
        }

        do {
            let statuses: [TfLLineStatus] = try await client.get(
                "/api/v1/status",
                forceRefresh: forceRefresh
            )
            let resolver = DisruptionResolver(repository: repository)
            let disruptions = statuses.flatMap(resolver.resolve).sorted { left, right in
                if left.severity != right.severity { return left.severity < right.severity }
                return left.lineID.displayName < right.lineID.displayName
            }
            let snapshot = TubeStatusSnapshot(
                statuses: statuses.map(\.compactedForDisplay),
                disruptions: disruptions,
                fetchedAt: .now,
                cached: false
            )
            try? await cache.save(snapshot, named: "status.json")
            latestSnapshot = snapshot
            return snapshot
        } catch {
            if let cached = try? await cache.load(TubeStatusSnapshot.self, named: "status.json") {
                let snapshot = TubeStatusSnapshot(
                    statuses: cached.statuses,
                    disruptions: cached.disruptions,
                    fetchedAt: cached.fetchedAt,
                    cached: true
                )
                latestSnapshot = snapshot
                return snapshot
            }
            throw error
        }
    }
}

private extension TfLLineStatus {
    var compactedForDisplay: TfLLineStatus {
        TfLLineStatus(
            id: id,
            name: name,
            lineStatuses: lineStatuses.map { status in
                TfLStatusEntry(
                    id: status.id,
                    statusSeverity: status.statusSeverity,
                    statusSeverityDescription: status.statusSeverityDescription,
                    reason: status.reason,
                    validityPeriods: nil,
                    disruption: nil
                )
            }
        )
    }
}
