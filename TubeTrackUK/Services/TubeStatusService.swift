import Foundation

struct TubeStatusSnapshot: Codable, Sendable {
    let statuses: [TfLLineStatus]
    let disruptions: [ResolvedDisruption]
    let fetchedAt: Date
    let cached: Bool
}

actor TubeStatusService {
    private let client: TfLClient
    private let cache: SnapshotCache
    private let repository: TubeNetworkRepository

    init(client: TfLClient, cache: SnapshotCache, repository: TubeNetworkRepository) {
        self.client = client
        self.cache = cache
        self.repository = repository
    }

    func fetch() async throws -> TubeStatusSnapshot {
        do {
            let statuses: [TfLLineStatus] = try await client.get(
                "/Line/Mode/tube,dlr,elizabeth-line/Status",
                queryItems: [URLQueryItem(name: "detail", value: "true")]
            )
            let resolver = DisruptionResolver(repository: repository)
            let disruptions = statuses.flatMap(resolver.resolve).sorted { left, right in
                if left.severity != right.severity { return left.severity < right.severity }
                return left.lineID.displayName < right.lineID.displayName
            }
            let snapshot = TubeStatusSnapshot(
                statuses: statuses,
                disruptions: disruptions,
                fetchedAt: .now,
                cached: false
            )
            try? await cache.save(snapshot, named: "status.json")
            return snapshot
        } catch {
            if let cached = try? await cache.load(TubeStatusSnapshot.self, named: "status.json") {
                return TubeStatusSnapshot(
                    statuses: cached.statuses,
                    disruptions: cached.disruptions,
                    fetchedAt: cached.fetchedAt,
                    cached: true
                )
            }
            throw error
        }
    }
}
