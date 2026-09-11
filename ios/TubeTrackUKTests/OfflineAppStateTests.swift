import Foundation
import Testing
@testable import TubeTrackUK

@Suite(.serialized)
struct OfflineAppStateTests {
    @Test @MainActor func disconnectedFirstLaunchLoadsMapSearchCoverageAndPlayableGame() async throws {
        let fixture = try OfflineAppFixture()
        defer { fixture.cleanUp() }
        let state = fixture.makeState()
        defer { state.setActive(false) }
        state.setNetworkAvailable(false)

        await state.start()

        let graph = try #require(state.graph)
        let document = try #require(state.initialBeckMapDocument)
        let coverage = try #require(state.mobileCoverage)
        #expect(state.isOffline)
        #expect(!state.isLoadingGraph)
        #expect(!state.isLoadingInitialStatus)
        #expect(!graph.stations.isEmpty)
        #expect(!document.paths.isEmpty)
        #expect(state.statusUpdatedAt == nil)
        #expect(state.worksUpdatedAt == nil)
        #expect(state.mapPresentationMode == .beck)

        let station = try #require(StationSearch.suggestions(in: graph, matching: "Oxford Circus").first)
        state.select(station: station)
        #expect(state.selectedStationID == station.id)
        #expect(station.name == "Oxford Circus")
        state.setMobileCoverageMode(.allUsable)
        let coveredSegment = try #require(graph.segments.first {
            coverage.coveredTunnelSegmentIDs.contains($0.id)
        })
        #expect(state.mobileCoverageMode == .allUsable)
        #expect(coverage.availability(for: coveredSegment, mode: state.mobileCoverageMode) == .available)
        state.cycleMobileCoverageMode()
        #expect(state.mobileCoverageMode == .undergroundOnly)

        state.setGameActive(true)
        let network = try TubeGameNetwork(graph: graph, document: document)
        #expect(Set(network.edges.compactMap(\.kind.lineID)) == Set(TubeLineID.allCases))
        var configuration = TubeGameConfiguration.standard
        configuration.countdownDuration = 0
        configuration.duration = 2
        configuration.collisionDistance = 0
        let engine = try TubeGameEngine(network: network, configuration: configuration, seed: 42)
        let initialPosition = engine.snapshot.player.position
        engine.start()
        engine.tick(deltaTime: 0.25)
        #expect(engine.snapshot.phase == .playing)
        #expect(engine.snapshot.elapsedTime == 0.25)
        #expect(engine.snapshot.player.position != initialPosition)
        #expect(!engine.snapshot.trains.isEmpty)
        engine.pause()
        engine.tick(deltaTime: 1)
        #expect(engine.snapshot.elapsedTime == 0.25)
        engine.resume()
        engine.tick(deltaTime: 2)
        #expect(engine.snapshot.phase == .ended(.completed))
        engine.restart()
        #expect(engine.snapshot.phase == .ready)
        state.setGameActive(false)

        await state.refreshStatus(forceRefresh: true)
        await state.refreshWorks(forceRefresh: true)
        await state.refreshNearbyArrivals(for: [station], forceRefresh: true)
        await state.refreshTrains()
        #expect(OfflineAppURLProtocol.requestCount == 0)
    }

    @Test @MainActor func offlineRestartRestoresDisruptionsWithOriginalAgesAndWorksHorizon() async throws {
        let fixture = try OfflineAppFixture()
        defer { fixture.cleanUp() }
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let through = savedAt.addingTimeInterval(60 * 86_400)
        let disruption = ResolvedDisruption(
            id: "victoria-delay", lineID: .victoria, title: "Severe delays",
            reason: "Delays due to a signal failure", severity: 6,
            affectedStationIDs: ["940GZZLUOXC"], affectedSegmentIDs: [], confidence: .lineOnly
        )
        let work = EngineeringWork(
            id: "victoria-works", title: "Planned closure", detail: "Track replacement",
            lineIDs: [.victoria], affectedStationIDs: ["940GZZLUOXC"], affectedSegmentIDs: [],
            startDate: savedAt, endDate: savedAt.addingTimeInterval(86_400),
            source: .unifiedAPI, fetchedAt: savedAt, confidence: .lineOnly
        )
        try await fixture.cache.save(TubeStatusSnapshot(
            statuses: [TfLLineStatus(id: .victoria, name: "Victoria", lineStatuses: [])],
            disruptions: [disruption], fetchedAt: savedAt, cached: false
        ), named: "status.json")
        try await fixture.cache.save(EngineeringWorksSnapshot(
            works: [work], fetchedAt: savedAt, cached: false, requestedThrough: through
        ), named: "works.json")
        let state = fixture.makeState()
        defer { state.setActive(false) }
        state.setNetworkAvailable(false)

        await state.start()

        #expect(state.statusUpdatedAt == savedAt)
        #expect(state.worksUpdatedAt == savedAt)
        #expect(state.disruptions == [disruption])
        #expect(state.engineeringWorks == [work])
        #expect(state.isUsingCachedStatus)
        #expect(state.isUsingCachedWorks)
        #expect(state.worksCachedThrough == through)
        #expect(state.hasSavedWorks(for: savedAt))
        #expect(state.hasSavedWorks(for: through))
        #expect(!state.hasSavedWorks(for: through.addingTimeInterval(86_400)))
        #expect(!state.hasSavedWorks(for: savedAt.addingTimeInterval(-86_400)))
        state.setDisruptionDateSelection(.custom(through.addingTimeInterval(86_400)))
        #expect(state.mapNetworkStatusSummary.goodServiceLineIDs.isEmpty)
        state.setDisruptionDateSelection(.custom(work.startDate))
        #expect(state.disruptionDataUpdatedAt == savedAt)
        #expect(state.selectedEngineeringWorks.contains(work))
        #expect(OfflineAppURLProtocol.requestCount == 0)
    }

    @Test @MainActor func disconnectStopsLiveRequestsAndKeepsBundledFeaturesAvailable() async throws {
        let fixture = try OfflineAppFixture()
        defer { fixture.cleanUp() }
        let state = fixture.makeState()
        defer { state.setActive(false) }
        await state.start()
        try await eventually {
            state.statusUpdatedAt != nil && state.worksUpdatedAt != nil
                && !state.isRefreshingStatus && !state.isRefreshingWorks
        }
        let graph = try #require(state.graph)
        let station = try #require(graph.stationsByID["940GZZLUOXC"])
        await state.refreshNearbyArrivals(for: [station], forceRefresh: true)
        #expect(state.nearbyArrivalsUpdatedAtByStationID[station.id] != nil)
        #expect(OfflineAppURLProtocol.requestCount > 0)

        state.setNetworkAvailable(false)
        let requestsAtDisconnect = OfflineAppURLProtocol.requestCount
        let savedStatusAge = state.statusUpdatedAt
        let savedWorksAge = state.worksUpdatedAt
        state.setLiveTrains(true)
        state.select(station: station)
        state.setTrainFilter(.victoria)
        state.setActive(false)
        state.setActive(true)
        await state.refreshStatus(forceRefresh: true)
        await state.refreshWorks(forceRefresh: true)
        await state.refreshTrains()
        await state.refreshNearbyArrivals(for: [station], forceRefresh: true)
        state.setMobileCoverageMode(.allUsable)
        // Changing map overlays intentionally clears the current selection.
        state.select(station: station)
        await Task.yield()

        #expect(state.isOffline)
        #expect(!state.showLiveTrains)
        #expect(!state.isLoadingLiveTrains)
        #expect(state.stationArrivals.isEmpty)
        #expect(state.nearbyArrivalsByStationID.isEmpty)
        #expect(state.nearbyArrivalsUpdatedAtByStationID.isEmpty)
        #expect(state.statusUpdatedAt == savedStatusAge)
        #expect(state.worksUpdatedAt == savedWorksAge)
        #expect(state.mobileCoverageMode == .allUsable)
        #expect(state.selectedStationID == station.id)
        #expect(OfflineAppURLProtocol.requestCount == requestsAtDisconnect)

        state.setNetworkAvailable(true)
        try await eventually {
            !state.isOffline && state.stationArrivalsUpdatedAt != nil
                && !state.isRefreshingStatus && !state.isRefreshingWorks
                && OfflineAppURLProtocol.requestCount > requestsAtDisconnect
        }
        #expect(!state.isUsingCachedStatus)
        #expect(!state.isUsingCachedWorks)
    }

    @Test func offlineAgeUsesFriendlySingularAndPluralBoundaries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(TimeInterval, String)] = [
            (-60, "just now"), (0, "just now"), (59, "just now"),
            (60, "a few minutes ago"), (299, "a few minutes ago"),
            (300, "5 minutes ago"), (3_599, "59 minutes ago"),
            (3_600, "1 hour ago"), (7_200, "2 hours ago"),
            (86_399, "23 hours ago"), (86_400, "1 day ago"),
            (172_800, "2 days ago"),
        ]
        for (elapsed, expected) in cases {
            #expect(OfflineStatusCopy.age(since: now.addingTimeInterval(-elapsed), now: now) == expected)
        }
        #expect(OfflineStatusCopy.message(updatedAt: nil, now: now, isWorks: false)
            == "Offline · No saved disruptions")
        #expect(OfflineStatusCopy.message(updatedAt: nil, now: now, isWorks: true)
            == "Offline · No saved works")
        #expect(OfflineStatusCopy.message(updatedAt: now, now: now, isWorks: false)
            == "Offline · Disruptions updated just now")
        #expect(OfflineStatusCopy.message(updatedAt: now.addingTimeInterval(-7_200), now: now, isWorks: true)
            == "Offline · Works updated 2 hours ago")
    }

    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

@MainActor
private struct OfflineAppFixture {
    let directory: URL
    let defaults: UserDefaults
    let suiteName: String
    var cache: SnapshotCache { SnapshotCache(directory: directory) }

    init() throws {
        let suiteName = "OfflineAppTests-\(UUID().uuidString)"
        self.suiteName = suiteName
        defaults = try #require(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory.appending(path: suiteName)
        OfflineAppURLProtocol.reset()
    }

    func makeState() -> TubeAppState {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineAppURLProtocol.self]
        configuration.urlCache = nil
        let client = TubeTrackAPIClient(
            configuration: TubeTrackAPIConfiguration(baseURL: URL(string: "https://offline-app.test")!),
            session: URLSession(configuration: configuration)
        )
        return TubeAppState(
            defaults: defaults, apiClient: client, snapshotCache: cache,
            monitorsConnectivity: false
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class OfflineAppURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static var requestCount: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
