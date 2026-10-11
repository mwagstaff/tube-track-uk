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
                    return TubeTrackAPIResponse(data: result.data, updatedAt: result.meta.updatedAt,
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

@MainActor
@Observable
final class JourneyPlannerModel {
    enum StationField: String, Identifiable {
        case from, to
        var id: String { rawValue }
    }
    var stationField: StationField?

    var from: TubeStation? { didSet { invalidate() } }
    var to: TubeStation? { didSet { invalidate() } }
    var timeMode: JourneyTimeMode = .now { didSet { invalidate() } }
    var time = Date.now.addingTimeInterval(3_600) { didSet { invalidate() } }
    var accessibility: JourneyAccessibility = .none { didSet { invalidate() } }
    private(set) var searchID: UUID?
    private(set) var result: TubeTrackAPIResponse<JourneyPlan>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var nextAutomaticRefresh = Date.distantPast
    @ObservationIgnored private let service: any JourneyFetching

    init(service: any JourneyFetching) { self.service = service }

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
    }

    func startSearch(keepingResults: Bool = false) {
        guard canSearch, !isLoading else { return }
        if !keepingResults { result = nil }
        errorMessage = nil
        isLoading = true
        searchID = UUID()
    }

    func cancelSearch() {
        searchID = nil
        isLoading = false
    }

    func load() async {
        guard let id = searchID, let from, let to else { return }
        let request = JourneyRequest(
            from: from.id, to: to.id, timeMode: timeMode,
            time: time, accessibility: accessibility
        )
        do {
            let response = try await service.fetch(request)
            try Task.checkCancellation()
            guard searchID == id else { return }
            result = response
            nextAutomaticRefresh = max(Date.now.addingTimeInterval(30), response.data.expiresAt)
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
