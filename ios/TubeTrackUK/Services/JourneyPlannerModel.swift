import Foundation
import Observation

protocol JourneyFetching: Sendable {
    func fetch(_ request: JourneyRequest) async throws -> TubeTrackAPIResponse<JourneyPlan>
}

struct JourneyService: JourneyFetching {
    let client: TubeTrackAPIClient

    func fetch(_ request: JourneyRequest) async throws -> TubeTrackAPIResponse<JourneyPlan> {
        try await client.getSnapshot(
            "/api/v1/journeys", queryItems: request.queryItems, forceRefresh: true
        )
    }
}

@MainActor
@Observable
final class JourneyPlannerModel {
    var from: TubeStation? { didSet { invalidate() } }
    var to: TubeStation? { didSet { invalidate() } }
    var timeMode: JourneyTimeMode = .now { didSet { invalidate() } }
    var time = Date.now.addingTimeInterval(3_600) { didSet { invalidate() } }
    var accessibility: JourneyAccessibility = .none { didSet { invalidate() } }
    private(set) var searchID: UUID?
    private(set) var result: TubeTrackAPIResponse<JourneyPlan>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
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
            isLoading = false
        } catch {
            guard searchID == id else { return }
            isLoading = false
            guard !Task.isCancelled else { return }
            if case let TubeTrackAPIClientError.serviceError(_, message) = error {
                errorMessage = message
            } else if case TubeTrackAPIClientError.rateLimited = error {
                errorMessage = "Journey planning is busy. Please try again shortly."
            } else {
                errorMessage = "Journeys couldn’t be loaded. Check your connection and try again."
            }
        }
    }

    private func invalidate() {
        cancelSearch()
        result = nil
        errorMessage = nil
    }
}
