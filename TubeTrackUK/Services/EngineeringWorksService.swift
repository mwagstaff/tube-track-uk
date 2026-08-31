import Foundation

struct EngineeringWorksSnapshot: Codable, Sendable {
    let works: [EngineeringWork]
    let fetchedAt: Date
    let cached: Bool
    let requestedThrough: Date?
}

actor EngineeringWorksService {
    private static let freshLifetime: TimeInterval = 6 * 60 * 60

    private let client: TfLClient
    private let cache: SnapshotCache
    private let repository: TubeNetworkRepository
    private var latestSnapshot: EngineeringWorksSnapshot?

    init(client: TfLClient, cache: SnapshotCache, repository: TubeNetworkRepository) {
        self.client = client
        self.cache = cache
        self.repository = repository
    }

    func fetch(
        through requestedDate: Date? = nil,
        days: Int = 60,
        forceRefresh: Bool = false
    ) async throws -> EngineeringWorksSnapshot {
        let now = Date.now
        let calendar = LondonRailDate.calendar
        let start = calendar.startOfDay(for: now)
        let defaultEnd = calendar.date(byAdding: .day, value: days, to: start) ?? start
        let requestedEnd = requestedDate.map { calendar.startOfDay(for: $0) } ?? defaultEnd
        let end = max(defaultEnd, requestedEnd)

        if !forceRefresh,
           let latestSnapshot,
           snapshot(latestSnapshot, covers: end, defaultDays: days),
           now.timeIntervalSince(latestSnapshot.fetchedAt) < Self.freshLifetime {
            return latestSnapshot
        }
        if !forceRefresh,
           let cached = try? await cache.load(EngineeringWorksSnapshot.self, named: "works.json"),
           snapshot(cached, covers: end, defaultDays: days),
           now.timeIntervalSince(cached.fetchedAt) < Self.freshLifetime {
            let snapshot = EngineeringWorksSnapshot(
                works: cached.works,
                fetchedAt: cached.fetchedAt,
                cached: true,
                requestedThrough: cached.requestedThrough
            )
            latestSnapshot = snapshot
            return snapshot
        }

        do {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = LondonRailDate.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let lineIDs = TubeLineID.allCases.map(\.rawValue).joined(separator: ",")
            let path = "/Line/\(lineIDs)/Status/\(formatter.string(from: start))/to/\(formatter.string(from: end))"
            let statuses: [TfLLineStatus] = try await client.get(
                path,
                queryItems: [URLQueryItem(name: "detail", value: "true")],
                priority: .background,
                forceRefresh: forceRefresh
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
                cached: false,
                requestedThrough: end
            )
            try? await cache.save(snapshot, named: "works.json")
            latestSnapshot = snapshot
            return snapshot
        } catch {
            if let cached = try? await cache.load(EngineeringWorksSnapshot.self, named: "works.json"),
               snapshot(cached, covers: end, defaultDays: days) {
                let snapshot = EngineeringWorksSnapshot(
                    works: cached.works,
                    fetchedAt: cached.fetchedAt,
                    cached: true,
                    requestedThrough: cached.requestedThrough
                )
                latestSnapshot = snapshot
                return snapshot
            }
            throw error
        }
    }

    private func snapshot(
        _ snapshot: EngineeringWorksSnapshot,
        covers requestedEnd: Date,
        defaultDays: Int
    ) -> Bool {
        let calendar = LondonRailDate.calendar
        let fallbackEnd = calendar.date(
            byAdding: .day,
            value: defaultDays,
            to: calendar.startOfDay(for: snapshot.fetchedAt)
        ) ?? snapshot.fetchedAt
        return (snapshot.requestedThrough ?? fallbackEnd) >= requestedEnd
    }
}
