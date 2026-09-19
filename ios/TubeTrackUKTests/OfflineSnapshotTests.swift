import Foundation
import Testing
@testable import TubeTrackUK

@Suite(.serialized)
struct OfflineSnapshotTests {
    @Test func migratesExistingSnapshotsWithoutChangingTheirAge() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyDirectory = directory.appending(path: "Caches")
        let durableDirectory = directory.appending(path: "Application Support")
        let saved = statusSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await SnapshotCache(directory: legacyDirectory).save(saved, named: "status.json")

        let cache = SnapshotCache(directory: durableDirectory, legacyDirectory: legacyDirectory)
        let migrated = try await cache.load(TubeStatusSnapshot.self, named: "status.json")
        try FileManager.default.removeItem(at: legacyDirectory)
        let reloaded = try await SnapshotCache(directory: durableDirectory)
            .load(TubeStatusSnapshot.self, named: "status.json")

        #expect(migrated.fetchedAt == saved.fetchedAt)
        #expect(reloaded.fetchedAt == saved.fetchedAt)
        #expect(reloaded.statuses == saved.statuses)
        #expect(reloaded.disruptions == saved.disruptions)
    }

    @Test func migrationStillReturnsSavedDataWhenTheNewDirectoryCannotBeWritten() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedDirectory = directory.appending(path: "blocked")
        try Data("file in the way".utf8).write(to: blockedDirectory)
        let legacyDirectory = directory.appending(path: "Caches")
        let saved = statusSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await SnapshotCache(directory: legacyDirectory).save(saved, named: "status.json")

        let cache = SnapshotCache(directory: blockedDirectory, legacyDirectory: legacyDirectory)
        let loaded = try await cache.load(TubeStatusSnapshot.self, named: "status.json")

        #expect(loaded.fetchedAt == saved.fetchedAt)
        #expect(loaded.disruptions == saved.disruptions)
    }

    @Test func offlineStartupReadsOldStatusWithoutMakingARequest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let saved = statusSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await cache.save(saved, named: "status.json")
        let service = makeStatusService(cache: cache)

        let cached = try #require(await service.cachedSnapshot())

        #expect(cached.cached)
        #expect(cached.fetchedAt == saved.fetchedAt)
        #expect(cached.disruptions == saved.disruptions)
        #expect(OfflineSnapshotURLProtocol.requestCount == 0)
    }

    @Test func failedStatusRefreshRetainsTheSavedTimestamp() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let saved = statusSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await cache.save(saved, named: "status.json")
        let service = makeStatusService(cache: cache)

        let cached = try await service.fetch(forceRefresh: true)

        #expect(cached.cached)
        #expect(cached.fetchedAt == saved.fetchedAt)
        #expect(cached.disruptions == saved.disruptions)
        #expect(OfflineSnapshotURLProtocol.requestCount == 1)
    }

    @Test func everySuccessfulStatusResponseReplacesTheSavedSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let service = makeStatusService(cache: cache, response: statusResponse(severity: 9))
        _ = try await service.fetch(forceRefresh: true)
        OfflineSnapshotURLProtocol.prepare(response: statusResponse(severity: 6))

        let latest = try await service.fetch(forceRefresh: true)
        let restarted = makeStatusService(cache: SnapshotCache(directory: directory))
        let saved = try #require(await restarted.cachedSnapshot())

        #expect(!latest.cached)
        #expect(saved.cached)
        #expect(saved.statuses.first?.lineStatuses.first?.statusSeverity == 6)
        #expect(saved.disruptions == latest.disruptions)
        #expect(abs(saved.fetchedAt.timeIntervalSince(latest.fetchedAt)) < 1)
        #expect(OfflineSnapshotURLProtocol.requestCount == 0)
    }

    @Test func aStaleServerStatusResponseDoesNotResetTheDisruptionAge() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = SnapshotCache(directory: directory)
        let response = Data("""
        {"data":\(String(decoding: statusResponse(severity: 6), as: UTF8.self)),"meta":{"updatedAt":"2023-11-14T22:13:20.000Z","cached":false,"stale":true}}
        """.utf8)
        let service = makeStatusService(cache: cache, response: response)

        let snapshot = try await service.fetch(forceRefresh: true)
        let restarted = makeStatusService(cache: SnapshotCache(directory: directory))
        let saved = try #require(await restarted.cachedSnapshot())

        #expect(snapshot.cached)
        #expect(snapshot.fetchedAt == sourceDate)
        #expect(saved.fetchedAt == sourceDate)
        #expect(saved.disruptions == snapshot.disruptions)
    }

    @Test func statusRemainsAvailableInMemoryWhenSavingToDiskFails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedDirectory = directory.appending(path: "blocked")
        try Data("file in the way".utf8).write(to: blockedDirectory)
        let service = makeStatusService(
            cache: SnapshotCache(directory: blockedDirectory),
            response: statusResponse(severity: 6)
        )

        let latest = try await service.fetch(forceRefresh: true)
        OfflineSnapshotURLProtocol.prepare(response: nil)
        let fallback = try await service.fetch(forceRefresh: true)

        #expect(!latest.cached)
        #expect(fallback.cached)
        #expect(fallback.fetchedAt == latest.fetchedAt)
        #expect(fallback.statuses == latest.statuses)
        #expect(fallback.disruptions == latest.disruptions)
    }

    @Test func unavailableOrCorruptStatusDoesNotCreateAFreshEmptySnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("incomplete download".utf8).write(to: directory.appending(path: "status.json"))
        let service = makeStatusService(cache: SnapshotCache(directory: directory))

        #expect(await service.cachedSnapshot() == nil)
        await #expect(throws: (any Error).self) {
            try await service.fetch(forceRefresh: true)
        }
        #expect(await service.cachedSnapshot() == nil)
    }

    @Test func offlineStartupRetainsWorksAndTheirSavedDateRange() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let requestedThrough = fetchedAt.addingTimeInterval(60 * 86_400)
        let saved = worksSnapshot(fetchedAt: fetchedAt, requestedThrough: requestedThrough)
        try await cache.save(saved, named: "works.json")
        let service = makeWorksService(cache: cache)

        let cached = try #require(await service.cachedSnapshot())

        #expect(cached.cached)
        #expect(cached.fetchedAt == saved.fetchedAt)
        #expect(cached.requestedThrough == requestedThrough)
        #expect(cached.works == saved.works)
        #expect(OfflineSnapshotURLProtocol.requestCount == 0)
    }

    @Test func successfulWorksResponsePersistsItsQueriedRange() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let requestedThrough = LondonRailDate.calendar.date(byAdding: .day, value: 120, to: .now)!
        let publishedThrough = LondonRailDate.calendar.date(byAdding: .day, value: 180, to: .now)!
        let service = makeWorksService(
            cache: cache,
            response: v2WorksResponse(publishedThrough: publishedThrough)
        )

        let latest = try await service.fetch(through: requestedThrough, forceRefresh: true)
        let restarted = makeWorksService(cache: SnapshotCache(directory: directory))
        let saved = try #require(await restarted.cachedSnapshot())

        #expect(!latest.cached)
        #expect(saved.cached)
        #expect(saved.requestedThrough == LondonRailDate.calendar.startOfDay(for: publishedThrough))
        #expect(saved.coverageKind == .publishedSchedule)
        #expect(abs(saved.fetchedAt.timeIntervalSince(latest.fetchedAt)) < 1)
        #expect(OfflineSnapshotURLProtocol.requestCount == 0)
    }

    @Test func worksRemainAvailableInMemoryWhenSavingToDiskFails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedDirectory = directory.appending(path: "blocked")
        try Data("file in the way".utf8).write(to: blockedDirectory)
        let service = makeWorksService(
            cache: SnapshotCache(directory: blockedDirectory),
            response: Data("[]".utf8)
        )

        let latest = try await service.fetch(forceRefresh: true)
        OfflineSnapshotURLProtocol.prepare(response: nil)
        let cached = try await service.fetch(forceRefresh: true)

        #expect(!latest.cached)
        #expect(cached.cached)
        #expect(cached.fetchedAt == latest.fetchedAt)
        #expect(cached.requestedThrough == latest.requestedThrough)
    }

    @Test func staleServerWorksRetainTheSourceAgeInTheirRowsAndSavedSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = SnapshotCache(directory: directory)
        let response = Data("""
        {"data":[{"id":"victoria","name":"Victoria","lineStatuses":[{"id":1,"statusSeverity":4,"statusSeverityDescription":"Planned closure","reason":"Track replacement","validityPeriods":[{"fromDate":"2023-11-15T00:00:00Z","toDate":"2023-11-16T00:00:00Z"}]}]}],"meta":{"updatedAt":"2023-11-14T22:13:20.000Z","cached":true,"stale":true}}
        """.utf8)
        let service = makeWorksService(cache: cache, response: response)

        let snapshot = try await service.fetch(forceRefresh: true)
        let restarted = makeWorksService(cache: SnapshotCache(directory: directory))
        let saved = try #require(await restarted.cachedSnapshot())

        #expect(snapshot.cached)
        #expect(snapshot.fetchedAt == sourceDate)
        #expect(try #require(snapshot.works.first).fetchedAt == sourceDate)
        #expect(saved.fetchedAt == sourceDate)
        #expect(saved.works == snapshot.works)
        #expect(saved.requestedThrough == snapshot.requestedThrough)
    }

    @Test func anUnknownLegacyWorksRangeDoesNotSatisfyAFutureRequest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let saved = worksSnapshot(fetchedAt: .now, requestedThrough: nil)
        try await cache.save(saved, named: "works.json")
        let service = makeWorksService(cache: cache, response: Data("[]".utf8))

        let snapshot = try await service.fetch(days: 120)

        #expect(!snapshot.cached)
        #expect(snapshot.requestedThrough == nil)
        #expect(OfflineSnapshotURLProtocol.requestCount == 2)
    }

    @Test func failedWorksRefreshReturnsAvailableWorksWithoutExtendingTheirRange() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = worksSnapshot(
            fetchedAt: fetchedAt,
            requestedThrough: fetchedAt.addingTimeInterval(60 * 86_400)
        )
        try await cache.save(saved, named: "works.json")
        let service = makeWorksService(cache: cache)

        let fallback = try await service.fetch(days: 120, forceRefresh: true)

        #expect(fallback.cached)
        #expect(fallback.works == saved.works)
        #expect(fallback.fetchedAt == saved.fetchedAt)
        #expect(fallback.requestedThrough == saved.requestedThrough)
        #expect(OfflineSnapshotURLProtocol.requestCount == 2)
    }

    @Test func cancelledRefreshDoesNotTurnIntoASuccessfulCacheFallback() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        try await cache.save(statusSnapshot(fetchedAt: .now), named: "status.json")
        try await cache.save(worksSnapshot(fetchedAt: .now, requestedThrough: nil), named: "works.json")
        let statusService = makeStatusService(cache: cache)
        let worksService = makeWorksService(cache: cache)
        let statusTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await statusService.fetch(forceRefresh: true)
        }
        let worksTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worksService.fetch(forceRefresh: true)
        }

        await #expect(throws: CancellationError.self) { try await statusTask.value }
        await #expect(throws: CancellationError.self) { try await worksTask.value }
        #expect(OfflineSnapshotURLProtocol.requestCount == 0)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "TubeTrackOfflineTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func makeStatusService(cache: SnapshotCache, response: Data? = nil) -> TubeStatusService {
        TubeStatusService(client: makeClient(response: response), cache: cache, repository: repository)
    }

    private func makeWorksService(cache: SnapshotCache, response: Data? = nil) -> EngineeringWorksService {
        EngineeringWorksService(client: makeClient(response: response), cache: cache, repository: repository)
    }

    private func makeClient(response: Data?) -> TubeTrackAPIClient {
        OfflineSnapshotURLProtocol.prepare(response: response)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineSnapshotURLProtocol.self]
        configuration.urlCache = nil
        return TubeTrackAPIClient(
            configuration: TubeTrackAPIConfiguration(baseURL: URL(string: "https://offline.test")!),
            session: URLSession(configuration: configuration)
        )
    }

    private var repository: TubeNetworkRepository {
        TubeNetworkRepository(graph: TubeGraph(
            schemaVersion: 1,
            generatedAt: "2026-09-09",
            source: TubeGraphSource(name: "Test", url: "https://offline.test", attribution: "Test"),
            schematicSize: TubeGraphSize(width: 100, height: 100),
            stations: [],
            segments: [],
            lines: [TubeGraphLine(id: .victoria, name: "Victoria", segmentIDs: [], routes: [])]
        ))
    }

    private func statusResponse(severity: Int) -> Data {
        Data("""
        [{"id":"victoria","name":"Victoria","lineStatuses":[{"id":1,"statusSeverity":\(severity),"statusSeverityDescription":"Delays","reason":"Victoria line: delays"}]}]
        """.utf8)
    }

    private func v2WorksResponse(publishedThrough: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = LondonRailDate.calendar
        formatter.timeZone = LondonRailDate.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return Data("""
        {"data":{"works":[],"coverage":{"publishedThrough":"\(formatter.string(from: publishedThrough))"}},"meta":{"updatedAt":"2026-09-19T08:00:00.000Z","cached":false,"stale":false}}
        """.utf8)
    }

    private func statusSnapshot(fetchedAt: Date) -> TubeStatusSnapshot {
        TubeStatusSnapshot(
            statuses: [TfLLineStatus(id: .victoria, name: "Victoria", lineStatuses: [])],
            disruptions: [ResolvedDisruption(
                id: "victoria-delay", lineID: .victoria, title: "Severe delays",
                reason: "Victoria line: delays", severity: 6, affectedStationIDs: [],
                affectedSegmentIDs: [], confidence: .lineOnly
            )],
            fetchedAt: fetchedAt,
            cached: false
        )
    }

    private func worksSnapshot(fetchedAt: Date, requestedThrough: Date?) -> EngineeringWorksSnapshot {
        EngineeringWorksSnapshot(
            works: [EngineeringWork(
                id: "victoria-works", title: "Planned closure", detail: "Track replacement",
                lineIDs: [.victoria], affectedStationIDs: [], affectedSegmentIDs: [],
                startDate: fetchedAt, endDate: fetchedAt.addingTimeInterval(86_400),
                source: .unifiedAPI, fetchedAt: fetchedAt, confidence: .lineOnly
            )],
            fetchedAt: fetchedAt,
            cached: false,
            requestedThrough: requestedThrough
        )
    }
}

private final class OfflineSnapshotURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody: Data?
    nonisolated(unsafe) private static var requests = 0

    static var requestCount: Int { lock.withLock { requests } }

    static func prepare(response: Data?) {
        lock.withLock {
            responseBody = response
            requests = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.lock.withLock {
            Self.requests += 1
            return Self.responseBody
        }
        guard let data, let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
