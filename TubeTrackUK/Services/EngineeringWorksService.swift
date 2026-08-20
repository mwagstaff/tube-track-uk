import Foundation

struct EngineeringWorksSnapshot: Codable, Sendable {
    let works: [EngineeringWork]
    let fetchedAt: Date
    let cached: Bool
}

actor EngineeringWorksService {
    private let client: TfLClient
    private let cache: SnapshotCache
    private let repository: TubeNetworkRepository

    init(client: TfLClient, cache: SnapshotCache, repository: TubeNetworkRepository) {
        self.client = client
        self.cache = cache
        self.repository = repository
    }

    func fetch(days: Int = 60) async throws -> EngineeringWorksSnapshot {
        do {
            let calendar = LondonRailDate.calendar
            let start = calendar.startOfDay(for: .now)
            let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = LondonRailDate.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let lineIDs = TubeLineID.allCases.map(\.rawValue).joined(separator: ",")
            let path = "/Line/\(lineIDs)/Status/\(formatter.string(from: start))/to/\(formatter.string(from: end))"
            let statuses: [TfLLineStatus] = try await client.get(
                path,
                queryItems: [URLQueryItem(name: "detail", value: "true")]
            )
            let fetchedAt = Date.now
            let works = EngineeringWorksBuilder(repository: repository).works(
                from: statuses,
                fetchedAt: fetchedAt
            )
            let deduplicated = EngineeringWorksNormalizer().deduplicatedAndSorted(works)
            let snapshot = EngineeringWorksSnapshot(
                works: deduplicated,
                fetchedAt: fetchedAt,
                cached: false
            )
            try? await cache.save(snapshot, named: "works.json")
            return snapshot
        } catch {
            if let cached = try? await cache.load(EngineeringWorksSnapshot.self, named: "works.json") {
                return EngineeringWorksSnapshot(works: cached.works, fetchedAt: cached.fetchedAt, cached: true)
            }
            throw error
        }
    }

}
