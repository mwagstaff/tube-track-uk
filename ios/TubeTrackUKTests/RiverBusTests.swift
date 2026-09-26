import CoreLocation
import Foundation
import Testing
@testable import TubeTrackUK

struct RiverBusTests {
    let now = Date(timeIntervalSince1970: 1_790_337_600)
    let route = RiverRoute(id: "rb99:outbound:0", lineId: "rb99", direction: "outbound", stopIds: ["A", "B", "C"])

    func prediction(pier: String, arrival: TimeInterval, observed: TimeInterval = 0, vehicle: String? = "opaque", destination: String = "C") -> RiverPrediction {
        RiverPrediction(id: "\(pier):\(arrival)", vehicleId: vehicle, tripId: "trip", pierId: pier,
            lineId: "rb99", direction: "outbound", destinationId: destination, destinationName: "Destination Pier",
            expectedArrival: now.addingTimeInterval(arrival), observedAt: now.addingTimeInterval(observed),
            expiresAt: now.addingTimeInterval(arrival), terminatesHere: pier == destination)
    }

    @Test func preparedBoatPathsInterpolateByDistanceAndReuseOnlyDirectedPierPairs() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0),
                      CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 4)]
        let prepared = RiverPreparedPath(points)
        #expect(prepared.point(at: -1) == points.first)
        #expect(prepared.point(at: 0) == points.first)
        #expect(prepared.point(at: 0.25) == CGPoint(x: 1.75, y: 0))
        #expect(prepared.point(at: 0.5) == CGPoint(x: 3, y: 0.5))
        #expect(prepared.point(at: 1) == points.last)
        #expect(prepared.point(at: 2) == points.last)
        #expect(RiverPreparedPath([]).point(at: 0.5) == nil)
        #expect(RiverPreparedPath([.zero, .zero]).point(at: 0.5) == .zero)
        var builds = 0
        var cache = RiverBoatPathCache()
        for _ in 0..<100 {
            _ = cache.path(from: "A", to: "B") { builds += 1; return points }
        }
        #expect(builds == 1)
        let reversed = cache.path(from: "B", to: "A") { builds += 1; return points.reversed() }
        #expect(builds == 2 && reversed.point(at: 0) == points.last)
        cache = RiverBoatPathCache()
        _ = cache.path(from: "A", to: "B") { builds += 1; return points }
        #expect(builds == 3)
    }

    @Test func transientEmptyBoardsKeepSourceAgeUntilDistinctConfirmation() {
        var policy = RiverBoardRefreshPolicy()
        let original = RiverBoardSnapshot(predictions: [prediction(pier: "B", arrival: 300)], updatedAt: now, stale: false)
        let empty = RiverBoardSnapshot(predictions: [], updatedAt: now.addingTimeInterval(30), stale: false)
        let retained = policy.resolve(empty, previous: original, now: now.addingTimeInterval(30))
        #expect(retained.predictions.count == 1 && retained.updatedAt == now && retained.stale)
        let cachedRepeat = policy.resolve(empty, previous: retained, now: now.addingTimeInterval(40))
        #expect(cachedRepeat.predictions.count == 1 && cachedRepeat.updatedAt == now)
        let confirmed = policy.resolve(.init(predictions: [], updatedAt: now.addingTimeInterval(60), stale: false),
            previous: cachedRepeat, now: now.addingTimeInterval(60))
        #expect(confirmed.predictions.isEmpty && !confirmed.stale)
    }

    @Test func expiredPredictionGapWaitsForConfirmationWithoutDisplayingAnExpiredBoat() {
        var policy = RiverBoardRefreshPolicy()
        let previous = RiverBoardSnapshot(predictions: [prediction(pier: "B", arrival: 10)], updatedAt: now, stale: false)
        let waiting = policy.resolve(.init(predictions: [], updatedAt: now.addingTimeInterval(30), stale: false),
            previous: previous, now: now.addingTimeInterval(30))
        #expect(waiting.stale && waiting.updatedAt == now)
        #expect(waiting.predictions.filter { $0.isCurrent(at: now.addingTimeInterval(30)) }.isEmpty)
        #expect(waiting.validUntil(lineId: nil) == now.addingTimeInterval(10))
    }

    @Test func boardRecoveryReplacesHeldDataAndEmptyPollsCannotExtendExpiry() {
        var policy = RiverBoardRefreshPolicy()
        let original = RiverBoardSnapshot(predictions: [prediction(pier: "B", arrival: 300)], updatedAt: now, stale: false)
        let retained = policy.resolve(.init(predictions: [], updatedAt: now.addingTimeInterval(30), stale: false),
            previous: original, now: now.addingTimeInterval(30))
        let fresh = RiverBoardSnapshot(predictions: [prediction(pier: "B", arrival: 350, observed: 60)], updatedAt: now.addingTimeInterval(60), stale: false)
        #expect(policy.resolve(fresh, previous: retained, now: now.addingTimeInterval(60)).predictions == fresh.predictions)
        #expect(policy.resolve(original, previous: fresh, now: now.addingTimeInterval(65)).updatedAt == fresh.updatedAt)
        let expired = policy.resolve(.init(predictions: [], updatedAt: now.addingTimeInterval(151), stale: false),
            previous: fresh, now: now.addingTimeInterval(151))
        #expect(expired.predictions.isEmpty)
    }

    @Test func shortEmptyFleetPollDoesNotEraseWitnessedPierHistory() {
        var estimator = RiverBoatEstimator()
        let network = RiverNetwork(lines: [], piers: [], routes: [route])
        _ = estimator.update([prediction(pier: "A", arrival: 10)], network: network, at: now)
        #expect(estimator.update([], network: network, at: now.addingTimeInterval(12)).isEmpty)
        #expect(estimator.update([prediction(pier: "B", arrival: 120, observed: 20)], network: network, at: now.addingTimeInterval(20)).count == 1)
        #expect(estimator.update([], network: network, at: now.addingTimeInterval(111)).isEmpty)
        #expect(estimator.update([prediction(pier: "C", arrival: 240, observed: 150)], network: network, at: now.addingTimeInterval(150)).isEmpty)
    }

    @Test @MainActor func liveVehicleToggleEnablesBoatLayerAndStopsBothTogether() throws {
        let suite = "LiveVehicleToggle.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        defer { state.setActive(false) }
        state.river.isEnabled = false; state.river.showsBoats = false
        state.setLiveTrains(true)
        #expect(state.showLiveTrains && state.river.isEnabled && state.river.showsBoats)
        state.setLiveTrains(false)
        #expect(!state.showLiveTrains && !state.river.showsBoats && state.river.isEnabled)
    }

    @Test func cachedSnapshotCanWitnessPierTransitionWithoutANewerSourceTimestamp() throws {
        var estimator = RiverBoatEstimator()
        let network = RiverNetwork(lines: [], piers: [], routes: [route])
        _ = estimator.update([prediction(pier: "A", arrival: 10), prediction(pier: "B", arrival: 120)], network: network, at: now)
        let boats = estimator.update([prediction(pier: "B", arrival: 120)], network: network, at: now.addingTimeInterval(15))
        let boat = try #require(boats.first)
        #expect(boat.previousPierId == "A" && boat.observedAt == now)
        #expect(estimator.update([], network: network, at: now.addingTimeInterval(30)) == boats)
        #expect(estimator.update([], network: network, at: now.addingTimeInterval(91)).isEmpty)
    }

    @Test func sharedBoatContractDecodesAndBoundsSourceFreshness() throws {
        let json = """
        {"id":"boat","lineId":"rb1","previousPierId":"A","nextPierId":"B",
        "destination":"B Pier","segmentStartedAt":"2026-09-25T11:52:00Z",
        "expectedArrival":"2026-09-25T12:02:00Z","observedAt":"2026-09-25T12:00:00Z",
        "expiresAt":"2026-09-25T12:01:30Z","basis":"predictedTravelTime"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let boat = try decoder.decode(EstimatedRiverBoat.self, from: Data(json.utf8))
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z"))
        #expect(boat.basis == "predictedTravelTime")
        #expect(abs(try #require(boat.progress(at: instant)) - 0.8) < 0.0001)
        #expect(boat.progress(at: instant.addingTimeInterval(91)) == nil)
        #expect(boat.progress(at: instant.addingTimeInterval(-500)) == nil)
        let minimal = json.replacingOccurrences(of: ",\n\"expiresAt\":\"2026-09-25T12:01:30Z\",\"basis\":\"predictedTravelTime\"", with: "")
        #expect(try decoder.decode(EstimatedRiverBoat.self, from: Data(minimal.utf8)).basis == nil)
    }

    @Test @MainActor func sharedFleetSurvivesTemporaryErrorsWithoutRenewingAgeAndSupportsOldServers() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RiverFleetURLProtocol.self]
        let client = TubeTrackAPIClient(configuration: .init(baseURL: URL(string: "https://river.test")!),
                                        session: URLSession(configuration: configuration))
        let suite = "RiverFleetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = RiverBusState(client: client, defaults: defaults)
        state.isEnabled = true; state.showsBoats = true
        let instant = Date.now
        let boat = EstimatedRiverBoat(id: "shared", lineId: "rb1", previousPierId: "930GTMP", nextPierId: "930GCAW",
            destination: "Canary Wharf", segmentStartedAt: instant.addingTimeInterval(-300),
            expectedArrival: instant.addingTimeInterval(180), observedAt: instant.addingTimeInterval(-10),
            basis: "predictedTravelTime")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([boat])
        let roundedBoat = try JSONDecoder.tfl.decode([EstimatedRiverBoat].self, from: data)[0]
        RiverFleetURLProtocol.prepare([
            .init(status: 200, data: data),
            .init(status: 200, data: Data("{\"data\":[],\"meta\":{\"stale\":true}}".utf8)),
            .init(status: 503, data: Data()),
            .init(status: 200, data: Data("[]".utf8))
        ])
        await state.refresh()
        #expect(state.boats == [roundedBoat])
        await state.refresh() // transient empty snapshot
        #expect(state.boats == [roundedBoat] && state.fleetError != nil)
        await state.refresh() // transport error
        #expect(state.boats == [roundedBoat] && state.fleetError != nil)
        await state.refresh() // authoritative fresh empty snapshot
        #expect(state.boats.isEmpty)

        let oldServer = RiverBusState(client: client, defaults: defaults)
        RiverFleetURLProtocol.prepare([.init(status: 404, data: Data())])
        await oldServer.refresh(); await oldServer.refresh()
        #expect(RiverFleetURLProtocol.count("/api/v1/river/boats") == 1)
        #expect(RiverFleetURLProtocol.count("/api/v1/river/live") == 2)
    }

    @Test func noPositionFromOneSnapshotOrMissingIdentity() {
        var estimator = RiverBoatEstimator()
        let network = RiverNetwork(lines: [], piers: [], routes: [route])
        #expect(estimator.update([prediction(pier: "A", arrival: 10), prediction(pier: "B", arrival: 120)], network: network, at: now).isEmpty)
        #expect(estimator.update([prediction(pier: "B", arrival: 120, observed: 15, vehicle: nil)], network: network, at: now.addingTimeInterval(15)).isEmpty)
    }

    @Test func witnessedTransitionCreatesOneBoundedEstimateAndNeverSailsBeyondNextPier() throws {
        var estimator = RiverBoatEstimator()
        let network = RiverNetwork(lines: [], piers: [], routes: [route])
        _ = estimator.update([prediction(pier: "A", arrival: 10), prediction(pier: "B", arrival: 120)], network: network, at: now)
        let boats = estimator.update([prediction(pier: "B", arrival: 120, observed: 15)], network: network, at: now.addingTimeInterval(15))
        let boat = try #require(boats.first)
        #expect(boats.count == 1)
        #expect(boat.previousPierId == "A" && boat.nextPierId == "B")
        #expect(abs(try #require(boat.progress(at: now.addingTimeInterval(15))) - 5.0 / 110) < 0.0001)
        #expect(boat.progress(at: now.addingTimeInterval(120)) == nil)
        #expect(boat.progress(at: now.addingTimeInterval(106)) == nil)
        let held = estimator.update([], network: network, at: now.addingTimeInterval(45))
        #expect(held == boats)
        #expect(estimator.update([], network: network, at: now.addingTimeInterval(106)).isEmpty)
    }

    @Test func repeatedJourneyCallingPatternAllowsExpressSegmentButNotWrongDirection() throws {
        var estimator = RiverBoatEstimator()
        let network = RiverNetwork(lines: [], piers: [], routes: [route])
        _ = estimator.update([prediction(pier: "A", arrival: 10), prediction(pier: "C", arrival: 120)], network: network, at: now)
        let boats = estimator.update([prediction(pier: "C", arrival: 120, observed: 15)], network: network, at: now.addingTimeInterval(15))
        #expect(try #require(boats.first).previousPierId == "A")
        #expect(boats.first?.nextPierId == "C")
        #expect(estimator.update([prediction(pier: "C", arrival: 120, observed: 30)], network: network, at: now.addingTimeInterval(30)).count == 1)
        var reversed = RiverBoatEstimator()
        _ = reversed.update([prediction(pier: "C", arrival: 10), prediction(pier: "A", arrival: 120)], network: network, at: now)
        #expect(reversed.update([prediction(pier: "A", arrival: 120, observed: 15)], network: network, at: now.addingTimeInterval(15)).isEmpty)
    }

    @Test func skippedStopsNeedAConfirmedRouteVariantAndIdentityReuseCannotTeleport() {
        var estimator = RiverBoatEstimator()
        let network = RiverNetwork(lines: [], piers: [], routes: [route])
        _ = estimator.update([prediction(pier: "A", arrival: 10)], network: network, at: now)
        #expect(estimator.update([prediction(pier: "C", arrival: 120, observed: 15)], network: network, at: now.addingTimeInterval(15)).isEmpty)
        _ = estimator.update([prediction(pier: "A", arrival: 30)], network: network, at: now.addingTimeInterval(20))
        #expect(estimator.update([prediction(pier: "B", arrival: 120, observed: 35, destination: "elsewhere")], network: network, at: now.addingTimeInterval(35)).isEmpty)
    }

    @Test func staleObservationsCannotBecomeCurrentBecauseArrivalIsInTheFuture() {
        #expect(!prediction(pier: "B", arrival: 600, observed: -91).isCurrent(at: now))
        #expect(!prediction(pier: "B", arrival: -1).isCurrent(at: now))
        #expect(prediction(pier: "B", arrival: 600).isCurrent(at: now))
    }

    @Test func bundledPiersHaveDistinctReviewedAnchorsOnExistingRiverAndNavigableGeometry() throws {
        let network = try #require(RiverBundle.load("RiverNetwork", as: RiverNetwork.self))
        let anchors = try #require(RiverBundle.load("RiverSchematic", as: [RiverSchematicAnchor].self))
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: TubeGraph.bundled())
        let waterway = try #require(document.waterways?.first)
        let path = try #require(document.paths.first { $0.id == waterway.pathID })
        let points: [CGPoint] = path.commands.compactMap {
            switch $0 { case let .move(to), let .line(to): CGPoint(x: to.x, y: to.y); default: nil }
        }
        #expect(network.piers.count == 24)
        #expect(Set(anchors.map(\.id)) == Set(network.piers.map(\.id)))
        for anchor in anchors {
            let projection = try #require(RiverPolyline.project(anchor.riverPoint, onto: points))
            #expect(hypot(projection.point.x - anchor.x, projection.point.y - anchor.y) < 0.01)
            #expect(anchor.markerPoint != anchor.riverPoint)
        }
        let geometry = RiverMapGeometry()
        for route in network.routes {
            for (a, b) in zip(route.stopIds, route.stopIds.dropFirst()) {
                let from = try #require(network.pier(a)), to = try #require(network.pier(b))
                #expect(geometry.path(from: from, to: to).count >= 4)
            }
        }
        let from = try #require(network.pier("930GTMP")), to = try #require(network.pier("930GCAW"))
        #expect(geometry.path(from: from, to: to).count > 10)
    }

    @Test func crossRiverSchematicHasARealSegmentAndReversePathIsSymmetric() throws {
        let anchors = try #require(RiverBundle.load("RiverSchematic", as: [RiverSchematicAnchor].self))
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: TubeGraph.bundled())
        let a = try #require(anchors.first { $0.id == "930GNEL" }), b = try #require(anchors.first { $0.id == "930GCAW" })
        let path = RiverMapGeometry.schematicPath(from: a, to: b, document: document)
        #expect(path.count == 2 && path[0] != path[1])
        #expect(RiverMapGeometry.schematicPath(from: b, to: a, document: document) == Array(path.reversed()))
    }

    @Test @MainActor func favouritesPersistAndSeparateStationsFromPiersWithTheSameName() throws {
        let suite = "RiverFavouritesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let station = FavouriteStop(stopId: "station", name: "Canary Wharf", kind: .station)
        let pier = FavouriteStop(stopId: "pier", name: "Canary Wharf", kind: .pier)
        let store = FavouriteStopsStore(defaults: defaults)
        store.toggle(station); store.toggle(pier)
        #expect(FavouriteStopsStore(defaults: defaults).stops.count == 2)
        store.toggle(station)
        #expect(!store.contains(station) && store.contains(pier))
    }

    @Test @MainActor func pierSelectionEnablesRememberedLayerAndExcludesRailSelection() throws {
        let suite = "RiverSelectionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.selectedTab = .profile
        let pier = try #require(state.river.network.pier("930GCAW"))
        state.selectedStationID = "old-station"
        state.select(pier: pier)
        #expect(state.river.isEnabled && state.river.selectedPierId == pier.id)
        #expect(state.selectedStationID == nil && state.selectedTab == .map)
        #expect(defaults.bool(forKey: "riverBusEnabled"))
        state.clearMapSelection()
        #expect(!state.river.hasSelection && state.river.isEnabled)
        state.river.selectedBoatId = "previous-estimate"
        state.river.showsBoats = false
        #expect(!state.river.hasSelection && state.river.boats.isEmpty)
        #expect(!defaults.bool(forKey: "riverBoatsEnabled"))
        state.river.isEnabled = false
        #expect(!defaults.bool(forKey: "riverBusEnabled"))
    }
}

private final class RiverFleetURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let data: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func prepare(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.replies = replies; counts = [:]
    }
    static func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path, default: 0]
    }
    private static func reply(_ path: String) -> Reply {
        lock.lock(); defer { lock.unlock() }
        counts[path, default: 0] += 1
        if path == "/api/v1/river/boats", !replies.isEmpty { return replies.removeFirst() }
        if path == "/api/v1/river/live" { return Reply(status: 200, data: Data("[]".utf8)) }
        return Reply(status: 404, data: Data())
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.reply(url.path)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
