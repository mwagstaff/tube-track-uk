import Foundation

struct TubeStatusSnapshot: Codable, Sendable {
    let statuses: [TfLLineStatus]
    let disruptions: [ResolvedDisruption]
    let fetchedAt: Date
    let cached: Bool
}

actor TubeStatusService {
    private static let freshLifetime: TimeInterval = 30

    private let client: TubeTrackAPIClient
    private let cache: SnapshotCache
    private let repository: TubeNetworkRepository
    private var latestSnapshot: TubeStatusSnapshot?

    init(client: TubeTrackAPIClient, cache: SnapshotCache, repository: TubeNetworkRepository) {
        self.client = client
        self.cache = cache
        self.repository = repository
    }

    /// Reads the last known disruptions without waiting for a network request.
    /// The original timestamp is retained even when the data is very old.
    func cachedSnapshot() async -> TubeStatusSnapshot? {
        if let latestSnapshot {
            return latestSnapshot.asCached
        }
        guard let saved = try? await cache.load(TubeStatusSnapshot.self, named: "status.json") else {
            return nil
        }
        // The actor may have received a newer response while reading the disk.
        let snapshot = (latestSnapshot ?? saved).asCached
        latestSnapshot = snapshot
        return snapshot
    }

    func fetch(forceRefresh: Bool = false) async throws -> TubeStatusSnapshot {
        try Task.checkCancellation()
        let now = Date.now
        if !forceRefresh,
           let latestSnapshot,
           now.timeIntervalSince(latestSnapshot.fetchedAt) < Self.freshLifetime {
            return latestSnapshot
        }
        if !forceRefresh,
           let cached = await cachedSnapshot(),
           now.timeIntervalSince(cached.fetchedAt) < Self.freshLifetime {
            return cached
        }

        do {
            let response: TubeTrackAPIResponse<[TfLLineStatus]> = try await client.getSnapshot(
                "/api/v1/status",
                forceRefresh: forceRefresh
            )
            try Task.checkCancellation()
            let statuses = response.data
            let resolver = DisruptionResolver(repository: repository)
            let disruptions = statuses.flatMap(resolver.resolve).sorted { left, right in
                if left.severity != right.severity { return left.severity < right.severity }
                return left.lineID.displayName < right.lineID.displayName
            }
            let snapshot = TubeStatusSnapshot(
                statuses: statuses.map(\.compactedForDisplay),
                disruptions: disruptions,
                fetchedAt: response.updatedAt,
                cached: response.cached || response.stale
            )
            latestSnapshot = snapshot
            try? await cache.save(snapshot, named: "status.json")
            return snapshot
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let cached = await cachedSnapshot() {
                latestSnapshot = cached
                return cached
            }
            throw error
        }
    }
}

private extension TubeStatusSnapshot {
    var asCached: TubeStatusSnapshot {
        TubeStatusSnapshot(
            statuses: statuses,
            disruptions: disruptions,
            fetchedAt: fetchedAt,
            cached: true
        )
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
