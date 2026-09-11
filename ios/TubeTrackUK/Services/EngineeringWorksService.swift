import Foundation

struct EngineeringWorksSnapshot: Codable, Sendable {
    let works: [EngineeringWork]
    let fetchedAt: Date
    let cached: Bool
    let requestedThrough: Date?
}

actor EngineeringWorksService {
    private static let freshLifetime: TimeInterval = 5 * 60

    private let client: TubeTrackAPIClient
    private let cache: SnapshotCache
    private let repository: TubeNetworkRepository
    private var latestSnapshot: EngineeringWorksSnapshot?

    init(client: TubeTrackAPIClient, cache: SnapshotCache, repository: TubeNetworkRepository) {
        self.client = client
        self.cache = cache
        self.repository = repository
    }

    /// Makes saved works available immediately, retaining their actual date range.
    func cachedSnapshot() async -> EngineeringWorksSnapshot? {
        if let latestSnapshot {
            return latestSnapshot.asCached
        }
        guard let saved = try? await cache.load(EngineeringWorksSnapshot.self, named: "works.json") else {
            return nil
        }
        let snapshot = (latestSnapshot ?? saved).asCached
        latestSnapshot = snapshot
        return snapshot
    }

    func fetch(
        through requestedDate: Date? = nil,
        days: Int = 60,
        forceRefresh: Bool = false
    ) async throws -> EngineeringWorksSnapshot {
        try Task.checkCancellation()
        let now = Date.now
        let calendar = LondonRailDate.calendar
        let start = calendar.startOfDay(for: now)
        let defaultEnd = calendar.date(byAdding: .day, value: days, to: start) ?? start
        let requestedEnd = requestedDate.map { calendar.startOfDay(for: $0) } ?? defaultEnd
        let end = max(defaultEnd, requestedEnd)

        if !forceRefresh,
           let latestSnapshot,
           snapshot(latestSnapshot, covers: end),
           now.timeIntervalSince(latestSnapshot.fetchedAt) < Self.freshLifetime {
            return latestSnapshot
        }
        if !forceRefresh,
           let cached = await cachedSnapshot(),
           snapshot(cached, covers: end),
           now.timeIntervalSince(cached.fetchedAt) < Self.freshLifetime {
            return cached
        }

        do {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = LondonRailDate.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let response: TubeTrackAPIResponse<[TfLLineStatus]> = try await client.getSnapshot(
                "/api/v1/planned-works",
                queryItems: [
                    URLQueryItem(name: "from", value: formatter.string(from: start)),
                    URLQueryItem(name: "to", value: formatter.string(from: end)),
                ],
                forceRefresh: forceRefresh
            )
            try Task.checkCancellation()
            let fetchedAt = response.updatedAt
            let works = EngineeringWorksBuilder(repository: repository).works(
                from: response.data,
                fetchedAt: fetchedAt
            )
            let deduplicated = EngineeringWorksNormalizer().deduplicatedAndSorted(works)
            let snapshot = EngineeringWorksSnapshot(
                works: deduplicated,
                fetchedAt: fetchedAt,
                cached: response.cached || response.stale,
                requestedThrough: end
            )
            latestSnapshot = snapshot
            try? await cache.save(snapshot, named: "works.json")
            return snapshot
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // Keep the available works usable even if today's rolling horizon
            // or a newly selected date extends beyond the saved range. The
            // unchanged requestedThrough lets the UI describe that limitation.
            if let cached = await cachedSnapshot() {
                latestSnapshot = cached
                return cached
            }
            throw error
        }
    }

    private func snapshot(
        _ snapshot: EngineeringWorksSnapshot,
        covers requestedEnd: Date
    ) -> Bool {
        // A legacy snapshot without a recorded range is useful offline, but
        // cannot establish that an arbitrary future date has been checked.
        guard let requestedThrough = snapshot.requestedThrough else { return false }
        return requestedThrough >= requestedEnd
    }
}

private extension EngineeringWorksSnapshot {
    var asCached: EngineeringWorksSnapshot {
        EngineeringWorksSnapshot(
            works: works,
            fetchedAt: fetchedAt,
            cached: true,
            requestedThrough: requestedThrough
        )
    }
}
