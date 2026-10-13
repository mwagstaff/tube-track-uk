import Foundation
import Testing
@testable import TubeTrackUK

@MainActor
struct JourneyPlannerTests {
    @Test func scheduleUsesSupportedEndpointsAndReversesReturnDirection() throws {
        let fixture = Self.fixture
            .replacingOccurrences(of: "940A", with: "940GZZLUOXC")
            .replacingOccurrences(of: "940B", with: "940GZZLUTCR")
            .replacingOccurrences(of: "northern", with: "central")
            .replacingOccurrences(of: "\"direction\":\"Beta\"", with: "\"direction\":\"Eastbound\"")
        let plan = try JSONDecoder.tfl.decode(JourneyPlan.self, from: Data(fixture.utf8))
        let draft = try #require(plan.journeys[0].suggestedSchedule)
        #expect(draft.morning?.board.stopIds.contains("940GZZLUOXC") == true)
        #expect(draft.afternoon?.board.stopIds.contains("940GZZLUTCR") == true)
        #expect(draft.morning?.board.direction.rawValue == "eastbound")
        #expect(draft.afternoon?.board.direction.rawValue == "westbound")
        #expect(draft.morning?.board.destinationIDs == ["HUBTCR"])
        #expect(draft.afternoon?.board.destinationIDs == ["940GZZLUOXC"])
        let unsupported = fixture.replacingOccurrences(of: "\"mode\":\"tube\"", with: "\"mode\":\"national-rail\"")
        let rail = try JSONDecoder.tfl.decode(JourneyPlan.self, from: Data(unsupported.utf8))
        #expect(rail.journeys[0].suggestedSchedule == nil)
        #expect(try self.plan().journeys[0].suggestedSchedule == nil)
    }

    @Test func railJourneySuggestionsUseOperatorCodesAndCanonicalReturnStations() throws {
        let fixture = Self.fixture
            .replacingOccurrences(of: "940A", with: "nr:KTH")
            .replacingOccurrences(of: "940B", with: "HUBVIC")
            .replacingOccurrences(of: "\"mode\":\"tube\"", with: "\"mode\":\"national-rail\"")
            .replacingOccurrences(of: "\"direction\":\"Beta\"", with: "\"direction\":\"Northbound\",\"operatorCode\":\"SE\"")
        let plan = try JSONDecoder.tfl.decode(JourneyPlan.self, from: Data(fixture.utf8))
        let draft = try #require(plan.journeys[0].suggestedSchedule)
        #expect(draft.morning?.board.lineId == "national-rail:SE")
        #expect(draft.morning?.board.stopIds == ["KTH"])
        #expect(draft.afternoon?.board.stopIds == ["VIC"])
        #expect(draft.morning?.board.destinationIDs == ["HUBVIC"])
        #expect(draft.afternoon?.board.destinationIDs == ["nr:KTH"])
        #expect(draft.afternoon?.board.direction.rawValue == "southbound")
        #expect(draft.morning?.timeSummary == "07:30–09:30")
        #expect(draft.afternoon?.timeSummary == "16:30–18:30")
    }

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

    @Test func pullToRefreshWaitsForTheOwnedSearchAndKeepsResults() async throws {
        let model = JourneyPlannerModel(service: TestJourneyService(value: try plan()))
        model.from = station("940A")
        model.to = station("940B")
        model.startSearch()
        await model.load()
        let previousID = model.searchID
        let refresh = Task { await model.refreshSuggestions() }
        while !model.isLoading { await Task.yield() }
        #expect(model.searchID != previousID)
        #expect(model.result != nil)
        await model.load()
        await refresh.value
        #expect(!model.isLoading)
        #expect(model.result != nil)
    }

    @Test func cancellingRefreshWaitDoesNotCancelAnExistingSearch() async {
        let model = JourneyPlannerModel(service: TestJourneyService())
        model.from = station("940A")
        model.to = station("940B")
        model.startSearch()
        let id = model.searchID
        let refresh = Task { await model.refreshSuggestions() }
        await Task.yield()
        refresh.cancel()
        await refresh.value
        #expect(model.isLoading)
        #expect(model.searchID == id)
        await model.load()
        #expect(!model.isLoading)
        #expect(model.errorMessage != nil)
    }

    @Test func worksIsPresentedSeparatelyFromTheFourTabs() {
        #expect(AppTab.allCases == [.map, .nearMe, .journeys, .profile])
        let state = TubeAppState(monitorsConnectivity: false)
        state.showsWorks = true
        state.showDisruptionsOnMap(for: .tomorrow)
        #expect(!state.showsWorks)
        #expect(state.selectedTab == .map)
    }

    @Test func automaticRefreshRespectsExpiryAndKeepsPreviousChoices() async throws {
        let model = JourneyPlannerModel(service: TestJourneyService(value: try plan()))
        model.from = station("nr:KTH")
        model.to = station("940B")
        model.startSearch()
        await model.load()
        #expect(model.canSearch)
        model.refreshIfNeeded(now: model.nextAutomaticRefresh.addingTimeInterval(-1))
        #expect(!model.isLoading)
        model.refreshIfNeeded(now: model.nextAutomaticRefresh)
        #expect(model.isLoading)
        #expect(model.result != nil)
        let searchID = model.searchID
        model.refreshIfNeeded(now: model.nextAutomaticRefresh.addingTimeInterval(60))
        #expect(model.searchID == searchID)
    }

    @Test func mapJourneySelectionIncludesNationalRailStations() throws {
        let state = TubeAppState(monitorsConnectivity: false)
        state.graph = try TubeGraph.bundled().includingNationalRailStations()
        let stop = try #require(DepartureStop.bundled.first { $0.id == "nr:KTH" })
        #expect(state.prepareJourney(at: stop, asOrigin: true))
        #expect(state.journeyPlanner.from?.id == "nr:KTH")
    }

    @Test func durationsUseHoursAndMinutes() {
        for (minutes, expected) in [(0, "0 mins"), (1, "1 min"), (36, "36 mins"),
                                    (60, "1 hour"), (61, "1 hour, 1 min"), (96, "1 hour, 36 mins"), (120, "2 hours")] {
            #expect(JourneyFormatting.duration(minutes) == expected)
        }
    }

    @Test func operatorBrandingDecodesWithoutBreakingLegacyLines() throws {
        let branded = try JSONDecoder().decode(JourneyLine.self, from: Data(##"{"id":"southeastern","name":"Southeastern","direction":"Victoria","colour":"#1D2452","operatorCode":"SE"}"##.utf8))
        #expect(branded.colour == "#1D2452")
        #expect(branded.operatorCode == "SE")
        let legacy = try JSONDecoder().decode(JourneyLine.self, from: Data(#"{"id":"victoria","name":"Victoria","direction":"Brixton"}"#.utf8))
        #expect(legacy.colour == nil)
        #expect(legacy.operatorCode == nil)
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
