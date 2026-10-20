import Foundation

public actor RailCallingPointsService {
    public static let shared = RailCallingPointsService()
    private let client: TubeTrackAPIClient

    public init(client: TubeTrackAPIClient = TubeTrackAPIClient(configuration: .init(
        baseURL: URL(string: "https://api.skynolimit.dev/train-track")!))) {
        self.client = client
    }

    public func fetch(for arrival: TfLArrivalPrediction) async throws -> RailCallingPoints {
        guard arrival.supportsCallingPoints else { throw TubeTrackAPIClientError.invalidResponse }
        let reference: (station: String, serviceID: String)
        if let known = arrival.railServiceReference {
            reference = known
        } else {
            reference = try await resolveThameslink(arrival)
        }
        // Encode opaque IDs as one path component, never as extra URL paths.
        let result: [[String: RailCallingPoints]] = try await client.get(
            "/api/v2/service_details", pathComponents: [reference.serviceID],
            queryItems: [URLQueryItem(name: "fromCRS", value: reference.station)], forceRefresh: true)
        try Task.checkCancellation()
        guard let details = result.first?[reference.serviceID], details.crs == reference.station else {
            throw TubeTrackAPIClientError.invalidResponse
        }
        return details
    }

    private func resolveThameslink(_ arrival: TfLArrivalPrediction) async throws -> (station: String, serviceID: String) {
        guard arrival.lineId == "thameslink", let stop = arrival.naptanId,
              let scheduled = arrival.scheduledDeparture else { throw TubeTrackAPIClientError.invalidResponse }
        let codes = stop.count == 3 ? [stop] : NationalRailStations.codes(for: [stop])
        var matches: [(station: String, serviceID: String)] = []
        for crs in codes {
            try Task.checkCancellation()
            let board: NationalRailBoard = try await client.get("/api/v2/departures/from/\(crs)", forceRefresh: true)
            guard board.dataStatus == "live", let updated = board.lastSuccessfulUpdate,
                  abs(updated.timeIntervalSinceNow) < 90 else { continue }
            for row in board.departures where Self.matches(row, arrival: arrival, scheduled: scheduled, reference: updated) {
                matches.append((crs, row.serviceID))
            }
        }
        guard matches.count == 1, let match = matches.first else { throw TubeTrackAPIClientError.invalidResponse }
        return match
    }

    static func matches(_ row: NationalRailDeparture, arrival: TfLArrivalPrediction,
                        scheduled: Date, reference: Date) -> Bool {
        guard row.operatorCode?.uppercased() == "TL",
              NationalRailDeparture.clockDate(row.times.scheduled, near: reference) == scheduled else { return false }
        if let destination = arrival.destinationNaptanId {
            let codes = destination.count == 3 ? [destination] : NationalRailStations.codes(for: [destination])
            if !codes.isEmpty { return row.destinations.count == 1 && codes.contains(row.destinations[0].crs ?? "") }
        }
        func clean(_ name: String) -> String {
            name.lowercased().replacingOccurrences(of: " (rail|underground)? ?station$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = arrival.destinationName, !name.isEmpty, row.destinations.count == 1,
              let destination = row.destinations[0].locationName else { return false }
        return clean(name) == clean(destination)
    }
}
