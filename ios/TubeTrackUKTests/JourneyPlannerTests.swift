import Foundation
import Testing
@testable import TubeTrackUK

@MainActor
struct JourneyPlannerTests {
    @Test func queryUsesStationIDsExplicitTimeAndAccessibilityWithoutCredentials() {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let request = JourneyRequest(from: "940A", to: "940B", timeMode: .arriveBy, time: time, accessibility: .train)
        let query = Dictionary(uniqueKeysWithValues: request.queryItems.map { ($0.name, $0.value ?? "") })
        #expect(query["timeMode"] == "arriveBy")
        #expect(query["time"] == "2023-11-14T22:13:20Z")
        #expect(query["accessibility"] == "train")
        #expect(query["app_key"] == nil)
        let now = JourneyRequest(from: "940A", to: "940B", timeMode: .now, time: time, accessibility: .none)
        #expect(!now.queryItems.contains { $0.name == "time" })
    }

    @Test func interchangeMembersCannotBeUsedAsBothEndpoints() {
        let model = JourneyPlannerModel(service: TestJourneyService())
        model.from = station("940A", hub: "HUBA")
        model.to = station("910A", hub: "HUBA")
        #expect(model.hasSameStation)
        #expect(!model.canSearch)
        model.startSearch()
        #expect(model.searchID == nil)
    }

    @Test func decodesNormalizedPlanAndPreservesExpiryAndNotices() throws {
        let result = try plan()
        #expect(result.from.name == "Alpha")
        #expect(result.journeys[0].recommendation == "Earliest estimated arrival")
        #expect(result.journeys[0].legs[0].timing == "estimated")
        #expect(result.journeys[0].legs[0].scheduledDepartureTime == nil)
        #expect(result.journeys[0].warnings[0].kind == "accessibility")
        #expect(result.journeys[0].severeWarnings.isEmpty)
        #expect(result.expiresAt > result.requestedAt)
    }

    @Test func searchLoadsAndEditingClearsThePreviousResults() async throws {
        let model = JourneyPlannerModel(service: TestJourneyService(value: try plan()))
        model.from = station("940A")
        model.to = station("940B")
        model.startSearch()
        #expect(model.isLoading)
        await model.load()
        #expect(model.result?.data.journeys.count == 1)
        #expect(!model.isLoading)
        model.timeMode = .arriveBy
        #expect(model.result == nil)
        #expect(model.searchID == nil)
        model.swapStations()
        #expect(model.from?.id == "940B")
        #expect(model.to?.id == "940A")
    }

    @Test func lateResponseCannotReplaceAnEditedJourney() async throws {
        let service = DeferredJourneyService()
        let model = JourneyPlannerModel(service: service)
        model.from = station("940A")
        model.to = station("940B")
        model.startSearch()
        let task = Task { await model.load() }
        while !(await service.hasStarted) { await Task.yield() }
        model.to = station("940C")
        await service.finish(try plan())
        await task.value
        #expect(model.result == nil)
        #expect(!model.isLoading)
    }

    @Test func failureShowsAnActionableMessageWithoutKeepingAResult() async {
        let model = JourneyPlannerModel(service: TestJourneyService())
        model.from = station("940A")
        model.to = station("940B")
        model.startSearch()
        await model.load()
        #expect(model.result == nil)
        #expect(model.errorMessage?.contains("try again") == true)
        #expect(!model.isLoading)
    }

    @Test func refreshKeepsRouteChoicesAndPreventsDuplicateRequests() async throws {
        let model = JourneyPlannerModel(service: TestJourneyService(value: try plan()))
        model.from = station("940A")
        model.to = station("940B")
        model.startSearch()
        await model.load()
        model.startSearch(keepingResults: true)
        let refreshID = model.searchID
        #expect(model.result != nil)
        #expect(model.isLoading)
        model.startSearch()
        #expect(model.searchID == refreshID)
        #expect(model.result != nil)
        await model.load()
        #expect(!model.isLoading)
    }

    @Test func worksIsPresentedSeparatelyFromTheFourTabs() {
        #expect(AppTab.allCases == [.map, .nearMe, .journeys, .profile])
        let state = TubeAppState(monitorsConnectivity: false)
        state.showsWorks = true
        state.showDisruptionsOnMap(for: .tomorrow)
        #expect(!state.showsWorks)
        #expect(state.selectedTab == .map)
    }

    private func station(_ id: String, hub: String? = nil) -> TubeStation {
        TubeStation(id: id, name: id, latitude: 51.5, longitude: 0, schematicX: 0, schematicY: 0,
                    lineIDs: [.northern], interchange: hub != nil, searchAliases: [], hubID: hub)
    }

    private func plan() throws -> JourneyPlan {
        try JSONDecoder.tfl.decode(JourneyPlan.self, from: Data(Self.fixture.utf8))
    }

    private static let fixture = #"""
    {
      "from":{"id":"940A","name":"Alpha"},"to":{"id":"940B","name":"Beta"},
      "timeMode":"now","requestedAt":"2026-09-16T12:00:00.000Z","accessibility":"none",
      "expiresAt":"2026-09-16T12:00:20.000Z","messages":[],"attribution":"Powered by TfL",
      "journeys":[{
        "id":"one","departureTime":"2026-09-16T12:05:00.000Z","arrivalTime":"2026-09-16T12:25:00.000Z",
        "durationMinutes":20,"changes":0,"walkingMinutes":0,"waitingMinutes":5,"labels":["earliestArrival"],
        "warnings":[{"id":"notice","message":"Lift unavailable on another platform","kind":"accessibility","severity":"information"}],
        "legs":[{
          "id":"0","mode":"tube","instruction":"Northern line to Beta",
          "from":{"id":"940A","name":"Alpha","platform":null},"to":{"id":"940B","name":"Beta","platform":null},
          "lines":[{"id":"northern","name":"Northern","direction":"Beta"}],
          "departureTime":"2026-09-16T12:05:00.000Z","arrivalTime":"2026-09-16T12:25:00.000Z",
          "scheduledDepartureTime":null,"scheduledArrivalTime":null,"timing":"estimated","durationMinutes":20,
          "warnings":[],"stops":[]
        }]
      }]
    }
    """#
}

private struct TestJourneyService: JourneyFetching {
    var value: JourneyPlan?
    func fetch(_ request: JourneyRequest) async throws -> TubeTrackAPIResponse<JourneyPlan> {
        guard let value else { throw URLError(.notConnectedToInternet) }
        return TubeTrackAPIResponse(data: value, updatedAt: .now, cached: false, stale: false)
    }
}

private actor DeferredJourneyService: JourneyFetching {
    private var continuation: CheckedContinuation<TubeTrackAPIResponse<JourneyPlan>, Never>?
    var hasStarted: Bool { continuation != nil }
    func fetch(_ request: JourneyRequest) async throws -> TubeTrackAPIResponse<JourneyPlan> {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ plan: JourneyPlan) {
        continuation?.resume(returning: TubeTrackAPIResponse(data: plan, updatedAt: .now, cached: false, stale: false))
        continuation = nil
    }
}
