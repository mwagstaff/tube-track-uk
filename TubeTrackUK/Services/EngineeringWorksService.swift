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
            let calendar = Calendar(identifier: .gregorian)
            let start = calendar.startOfDay(for: .now)
            let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.dateFormat = "yyyy-MM-dd"
            let lineIDs = TubeLineID.allCases.map(\.rawValue).joined(separator: ",")
            let path = "/Line/\(lineIDs)/Status/\(formatter.string(from: start))/to/\(formatter.string(from: end))"
            let statuses: [TfLLineStatus] = try await client.get(
                path,
                queryItems: [URLQueryItem(name: "detail", value: "true")]
            )
            let resolver = DisruptionResolver(repository: repository)
            var works: [EngineeringWork] = []
            for line in statuses {
                for status in line.lineStatuses where isPlannedWork(status) {
                    let validity = status.validityPeriods?.first
                    guard let startDate = validity?.fromDate, let endDate = validity?.toDate else { continue }
                    let resolved = resolver.resolve(status, lineID: line.id)
                    works.append(
                        EngineeringWork(
                            id: "\(line.id.rawValue):\(status.id):\(Int(startDate.timeIntervalSince1970))",
                            title: status.statusSeverityDescription,
                            detail: status.reason ?? status.disruption?.description ?? status.statusSeverityDescription,
                            lineIDs: [line.id],
                            affectedStationIDs: resolved.affectedStationIDs,
                            affectedSegmentIDs: resolved.affectedSegmentIDs,
                            startDate: startDate,
                            endDate: endDate,
                            source: .unifiedAPI,
                            fetchedAt: .now,
                            confidence: resolved.confidence
                        )
                    )
                }
            }
            let deduplicated = EngineeringWorksNormalizer().deduplicatedAndSorted(works)
            let snapshot = EngineeringWorksSnapshot(works: deduplicated, fetchedAt: .now, cached: false)
            try? await cache.save(snapshot, named: "works.json")
            return snapshot
        } catch {
            if let cached = try? await cache.load(EngineeringWorksSnapshot.self, named: "works.json") {
                return EngineeringWorksSnapshot(works: cached.works, fetchedAt: cached.fetchedAt, cached: true)
            }
            throw error
        }
    }

    private func isPlannedWork(_ status: TfLStatusEntry) -> Bool {
        let category = status.disruption?.category ?? status.disruption?.categoryDescription ?? ""
        return category.localizedCaseInsensitiveContains("plannedwork")
            || category.localizedCaseInsensitiveContains("planned work")
    }

}
