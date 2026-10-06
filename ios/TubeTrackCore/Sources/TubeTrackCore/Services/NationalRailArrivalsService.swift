import Foundation

actor NationalRailArrivalsService {
    struct Snapshot: Sendable {
        var arrivals: [TfLArrivalPrediction] = []
        var updatedAt: Date?
        var isStale = false
        var errorMessage: String?
    }
    private struct Cached: Sendable {
        let board: NationalRailBoard
        let fetchedAt: Date
    }
    private let client: TubeTrackAPIClient
    private var boards: [String: Cached] = [:]

    init(client: TubeTrackAPIClient) { self.client = client }

    func fetch(stationIDs: [String], forceRefresh: Bool) async throws -> Snapshot {
        let codes = NationalRailStations.codes(for: stationIDs)
        let includesThameslink = stationIDs.contains { $0.hasPrefix("nr:") }
        var result = Snapshot()
        for crs in codes {
            try Task.checkCancellation()
            let now = Date.now
            do {
                let board: NationalRailBoard
                if !forceRefresh, let cached = boards[crs], now.timeIntervalSince(cached.fetchedAt) < 30 {
                    board = cached.board
                } else {
                    board = try await client.get("/api/v2/departures/from/\(crs)", forceRefresh: forceRefresh)
                    guard ["live", "partial", "stale"].contains(board.dataStatus),
                          let updated = board.lastSuccessfulUpdate,
                          now.timeIntervalSince(updated) < 5 * 60 else {
                        throw TubeTrackAPIClientError.invalidResponse
                    }
                    boards[crs] = Cached(board: board, fetchedAt: now)
                }
                result.arrivals += board.predictions(crs: crs, now: now, includeThameslink: includesThameslink)
                if let updated = board.lastSuccessfulUpdate {
                    result.updatedAt = min(result.updatedAt ?? updated, updated)
                }
                if board.dataStatus != "live" {
                    result.isStale = true
                    result.errorMessage = "Some National Rail departures may be missing or out of date."
                }
            } catch {
                try Task.checkCancellation()
                result.isStale = true
                result.errorMessage = "National Rail departures are temporarily unavailable."
                if let cached = boards[crs], let updated = cached.board.lastSuccessfulUpdate,
                   now.timeIntervalSince(updated) < 5 * 60 {
                    result.arrivals += cached.board.predictions(crs: crs, now: now, includeThameslink: includesThameslink)
                    result.updatedAt = min(result.updatedAt ?? updated, updated)
                    result.errorMessage = "Showing saved National Rail departures. Live updates are temporarily unavailable."
                }
            }
        }
        boards = boards.filter { Date.now.timeIntervalSince($0.value.fetchedAt) < 5 * 60 }
        return result
    }
}
