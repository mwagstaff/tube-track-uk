import Foundation
import Observation

protocol JourneyFetching: Sendable {
    func fetch(_ request: JourneyRequest) async throws -> TubeTrackAPIResponse<JourneyPlan>
}

struct JourneyService: JourneyFetching {
    let client: TubeTrackAPIClient

    func fetch(_ request: JourneyRequest) async throws -> TubeTrackAPIResponse<JourneyPlan> {
        let started: CombinedJourneyJob = try await client.getSnapshot(
            "/api/v2/journey-searches", queryItems: request.queryItems,
            forceRefresh: true, httpMethod: "POST"
        ).data
        let path = "/api/v2/journey-searches/\(started.id)"
        do {
            var job = started
            let deadline = Date.now.addingTimeInterval(180)
            while Date.now < deadline {
                try Task.checkCancellation()
                if let result = job.result {
                    var plan = result.data
                    plan.searchID = started.id
                    return TubeTrackAPIResponse(data: plan, updatedAt: result.meta.updatedAt,
                                                cached: result.meta.cached, stale: result.meta.stale)
                }
                if let error = job.error {
                    throw TubeTrackAPIClientError.serviceError(code: error.code, message: error.message)
                }
                guard ["queued", "running"].contains(job.status) else {
                    throw TubeTrackAPIClientError.serviceError(code: "SEARCH_EXPIRED", message: "This search ended. Please search again.")
                }
                try await Task.sleep(for: .milliseconds(min(5_000, max(1_000, job.pollAfterMs))))
                job = try await client.get(path, forceRefresh: true)
            }
            throw TubeTrackAPIClientError.serviceError(code: "SEARCH_TIMEOUT", message: "The search took too long. Please try again.")
        } catch {
            // A separate task can release the server lease even when this view's
            // task was cancelled. Other callers' coalesced searches remain live.
            let cleanup = Task { () -> Void in
                let _: TubeTrackAPIResponse<EmptyJourneyResponse>? = try? await client.getSnapshot(
                    path, forceRefresh: true, httpMethod: "DELETE"
                )
            }
            _ = await cleanup.result
            throw error
        }
    }
}

private struct EmptyJourneyResponse: Decodable, Sendable {}

private struct CombinedJourneyJob: Decodable, Sendable {
    struct Failure: Decodable, Sendable { let code: String; let message: String }
    struct Result: Decodable, Sendable {
        struct Metadata: Decodable, Sendable { let updatedAt: Date; let cached: Bool; let stale: Bool }
        let data: JourneyPlan
        let meta: Metadata
    }
    let id: String
    let status: String
    let pollAfterMs: Int
    let result: Result?
    let error: Failure?
}

struct RecentJourneySearch: Codable, Identifiable, Sendable {
    let id: UUID
    let searchedAt: Date
    let from: JourneyStation
    let to: JourneyStation
    let via: [JourneyStation]
    let timeMode: JourneyTimeMode
    let time: Date
    let accessibility: JourneyAccessibility

    var routeKey: RecentJourneyRouteKey {
        RecentJourneyRouteKey(fromID: from.id, toID: to.id, viaIDs: via.map(\.id))
    }

    func matches(_ query: String) -> Bool {
        let searchable = ([from.name, to.name] + via.map(\.name) + [timeMode.title, accessibility.title]).joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchable.localizedStandardContains(String($0))
        }
    }
}

struct RecentJourneyRouteKey: Hashable {
    let fromID: String
    let toID: String
    let viaIDs: [String]
}

struct RecentJourneySearchPage {
    let entries: [RecentJourneySearch]
    let number: Int
    let count: Int
}

@MainActor
@Observable
final class JourneyPlannerModel {
    static let recentSearchPageSize = 50
    static let maximumRecentSearches = 500
    static let minimumResultLifetime: TimeInterval = 5 * 60
    enum StationField: String, Identifiable {
        case from, to, via
        var id: String { rawValue }
    }
    var stationField: StationField?

    var from: TubeStation? { didSet { invalidate() } }
    var to: TubeStation? { didSet { invalidate() } }
    var via: [TubeStation] = [] { didSet { invalidate() } }
    var timeMode: JourneyTimeMode = .now { didSet { invalidate() } }
    var time = Date.now.addingTimeInterval(3_600) { didSet { invalidate() } }
    var accessibility: JourneyAccessibility = .none { didSet { invalidate() } }
    private(set) var searchID: UUID?
    private(set) var result: TubeTrackAPIResponse<JourneyPlan>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var nextAutomaticRefresh = Date.distantPast
    private(set) var recentSearches: [RecentJourneySearch] = []
    @ObservationIgnored private let service: any JourneyFetching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let historyKey: String

    init(service: any JourneyFetching, defaults: UserDefaults = .standard,
         historyKey: String = "journeySearchHistory.v1.\(AppInstall.identifier)") {
        self.service = service
        self.defaults = defaults
        self.historyKey = historyKey
        if let data = defaults.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([RecentJourneySearch].self, from: data) {
            var seen = Set<RecentJourneyRouteKey>()
            recentSearches = Array(saved.sorted { $0.searchedAt > $1.searchedAt }
                .filter { seen.insert($0.routeKey).inserted }
                .prefix(Self.maximumRecentSearches))
            if recentSearches.count != saved.count,
               let cleaned = try? JSONEncoder().encode(recentSearches) {
                defaults.set(cleaned, forKey: historyKey)
            }
        }
    }

    /// Short live-feed expiries should not make an entire route search appear obsolete within seconds.
    /// Refreshes can run sooner, while the visible warning waits for a five-minute-old result.
    static func displayExpiry(for response: TubeTrackAPIResponse<JourneyPlan>) -> Date {
        max(response.data.expiresAt, response.updatedAt.addingTimeInterval(minimumResultLifetime))
    }

    func recentSearchPage(matching query: String, index: Int) -> RecentJourneySearchPage {
        let matching = recentSearches.filter { $0.matches(query) }
        let count = max(1, (matching.count + Self.recentSearchPageSize - 1) / Self.recentSearchPageSize)
        let number = min(max(0, index), count - 1)
        return RecentJourneySearchPage(
            entries: Array(matching.dropFirst(number * Self.recentSearchPageSize).prefix(Self.recentSearchPageSize)),
            number: number, count: count)
    }

    var canSearch: Bool {
        guard let from, let to else { return false }
        return (from.hubID ?? from.id) != (to.hubID ?? to.id)
    }

    var hasSameStation: Bool {
        from != nil && to != nil && !canSearch
    }

    func swapStations() {
        let oldFrom = from
        from = to
        to = oldFrom
        via.reverse()
    }

    func startSearch(keepingResults: Bool = false) {
        guard canSearch, !isLoading else { return }
        if !keepingResults { saveRecentSearch() }
        if !keepingResults { result = nil }
        errorMessage = nil
        isLoading = true
        searchID = UUID()
    }

    @discardableResult
    func rerun(_ search: RecentJourneySearch, stations: [TubeStation], now: Date = .now) -> Bool {
        guard !isLoading else { return false }
        let byID = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
        guard let origin = byID[search.from.id], let destination = byID[search.to.id],
              search.via.allSatisfy({ byID[$0.id] != nil }) else {
            errorMessage = "A station in this search is no longer available. Choose the stations again."
            return false
        }
        from = origin
        to = destination
        via = search.via.compactMap { byID[$0.id] }
        timeMode = search.timeMode
        time = search.time
        if timeMode != .now && time <= now {
            timeMode = .now
            time = now.addingTimeInterval(3_600)
        }
        accessibility = search.accessibility
        startSearch()
        return isLoading
    }

    private func saveRecentSearch() {
        guard let from, let to else { return }
        let entry = RecentJourneySearch(id: UUID(), searchedAt: .now,
            from: JourneyStation(id: from.id, name: from.name),
            to: JourneyStation(id: to.id, name: to.name),
            via: via.map { JourneyStation(id: $0.id, name: $0.name) },
            timeMode: timeMode, time: time, accessibility: accessibility)
        recentSearches.removeAll { $0.routeKey == entry.routeKey }
        recentSearches.insert(entry, at: 0)
        if recentSearches.count > Self.maximumRecentSearches {
            recentSearches.removeLast(recentSearches.count - Self.maximumRecentSearches)
        }
        if let data = try? JSONEncoder().encode(recentSearches) { defaults.set(data, forKey: historyKey) }
    }

    func cancelSearch() {
        searchID = nil
        isLoading = false
    }

    func load() async {
        guard let id = searchID, let from, let to else { return }
        let request = JourneyRequest(
            from: from.id, to: to.id, timeMode: timeMode,
            time: time, accessibility: accessibility, via: via.map(\.id)
        )
        do {
            let response = try await service.fetch(request)
            try Task.checkCancellation()
            guard searchID == id else { return }
            result = response
            nextAutomaticRefresh = response.stale ? Date.now.addingTimeInterval(30)
                : max(Date.now.addingTimeInterval(60), response.data.expiresAt)
            isLoading = false
        } catch {
            guard searchID == id else { return }
            isLoading = false
            guard !Task.isCancelled else { return }
            nextAutomaticRefresh = Date.now.addingTimeInterval(60)
            if case let TubeTrackAPIClientError.serviceError(_, message) = error {
                errorMessage = message
            } else if case TubeTrackAPIClientError.rateLimited = error {
                errorMessage = "Journey planning is busy. Please try again shortly."
            } else {
                errorMessage = "Journeys couldn’t be loaded. Check your connection and try again."
            }
        }
    }

    /// The screen's searchID task owns loading and cancellation. Keep the native
    /// pull-to-refresh indicator visible until that search finishes, without
    /// launching a second network request or cancelling an existing refresh.
    func refreshSuggestions() async {
        guard !Task.isCancelled else { return }
        startSearch(keepingResults: true)
        let id = searchID
        while isLoading && searchID == id {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
    }

    func refreshIfNeeded(now: Date = .now) {
        guard result != nil, !isLoading, now >= nextAutomaticRefresh else { return }
        startSearch(keepingResults: true)
    }

    private func invalidate() {
        cancelSearch()
        result = nil
        errorMessage = nil
    }
}
