import Foundation

enum EngineeringWorksCoverageKind: String, Codable, Sendable {
    case publishedSchedule
}

struct EngineeringWorksSnapshot: Codable, Sendable {
    let works: [EngineeringWork]
    let fetchedAt: Date
    let cached: Bool
    let requestedThrough: Date?
    let coverageKind: EngineeringWorksCoverageKind?

    init(
        works: [EngineeringWork],
        fetchedAt: Date,
        cached: Bool,
        requestedThrough: Date?,
        coverageKind: EngineeringWorksCoverageKind? = nil
    ) {
        self.works = works
        self.fetchedAt = fetchedAt
        self.cached = cached
        self.requestedThrough = requestedThrough
        self.coverageKind = coverageKind
    }
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
        // TfL describes this as a six-month schedule. Requesting 400 days
        // ensures the initial snapshot includes every currently published row,
        // while `publishedThrough` still records the document's true horizon.
        days: Int = 400,
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

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = LondonRailDate.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let queryItems = [
            URLQueryItem(name: "from", value: formatter.string(from: start)),
            URLQueryItem(name: "to", value: formatter.string(from: end)),
        ]

        do {
            let response: TubeTrackAPIResponse<PlannedWorksV2Data> = try await client.getSnapshot(
                "/api/v2/planned-works",
                queryItems: queryItems,
                forceRefresh: forceRefresh
            )
            try Task.checkCancellation()
            let fetchedAt = response.updatedAt
            let works = EngineeringWorksBuilder(repository: repository).works(
                from: response.data.works,
                fetchedAt: fetchedAt
            )
            let deduplicated = EngineeringWorksNormalizer().deduplicatedAndSorted(works)
            guard let coverageThrough = Self.dateOnly(response.data.coverage.publishedThrough) else {
                throw TubeTrackAPIClientError.decoding("Invalid planned-works coverage date")
            }
            let snapshot = EngineeringWorksSnapshot(
                works: deduplicated,
                fetchedAt: fetchedAt,
                cached: response.cached || response.stale,
                requestedThrough: coverageThrough,
                coverageKind: .publishedSchedule
            )
            latestSnapshot = snapshot
            try? await cache.save(snapshot, named: "works.json")
            return snapshot
        } catch let v2Error {
            try Task.checkCancellation()
            if v2Error is CancellationError { throw v2Error }

            // V1 remains available during a staged server rollout and for
            // emergency rollback. It cannot establish long-range coverage, so
            // its requestedThrough value is deliberately left unknown.
            do {
                let response: TubeTrackAPIResponse<[TfLLineStatus]> = try await client.getSnapshot(
                    "/api/v1/planned-works",
                    queryItems: queryItems,
                    forceRefresh: forceRefresh
                )
                try Task.checkCancellation()
                let fetchedAt = response.updatedAt
                let works = EngineeringWorksBuilder(repository: repository).works(
                    from: response.data,
                    fetchedAt: fetchedAt
                )
                let snapshot = EngineeringWorksSnapshot(
                    works: EngineeringWorksNormalizer().deduplicatedAndSorted(works),
                    fetchedAt: fetchedAt,
                    cached: response.cached || response.stale,
                    requestedThrough: nil
                )
                latestSnapshot = snapshot
                try? await cache.save(snapshot, named: "works.json")
                return snapshot
            } catch let legacyError {
                try Task.checkCancellation()
                if legacyError is CancellationError { throw legacyError }
                if let cached = await cachedSnapshot() {
                    latestSnapshot = cached
                    return cached
                }
                throw v2Error
            }
        }
    }

    private func snapshot(
        _ snapshot: EngineeringWorksSnapshot,
        covers requestedEnd: Date
    ) -> Bool {
        // A legacy snapshot without a recorded range is useful offline, but
        // cannot establish that an arbitrary future date has been checked.
        guard snapshot.coverageKind == .publishedSchedule,
              let requestedThrough = snapshot.requestedThrough else { return false }
        return requestedThrough >= requestedEnd
    }

    private static func dateOnly(_ value: String) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return LondonRailDate.calendar.date(from: DateComponents(
            timeZone: LondonRailDate.timeZone,
            year: components[0],
            month: components[1],
            day: components[2]
        ))
    }
}

private extension EngineeringWorksSnapshot {
    var asCached: EngineeringWorksSnapshot {
        EngineeringWorksSnapshot(
            works: works,
            fetchedAt: fetchedAt,
            cached: true,
            // Preserve the saved range for offline users upgrading from v1.
            // Online freshness checks still require the v2 coverage marker.
            requestedThrough: requestedThrough,
            coverageKind: coverageKind
        )
    }
}
