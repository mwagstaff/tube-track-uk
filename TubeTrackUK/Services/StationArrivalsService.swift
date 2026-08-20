import Foundation

actor StationArrivalsService {
    private let client: TfLClient

    init(client: TfLClient) {
        self.client = client
    }

    func fetch(stationIDs: [String]) async throws -> [TfLArrivalPrediction] {
        var predictions: [TfLArrivalPrediction] = []
        for stationID in Set(stationIDs) {
            let arrivals: [TfLArrivalPrediction] = try await client.get("/StopPoint/\(stationID)/Arrivals")
            predictions.append(contentsOf: arrivals)
        }
        return predictions
            .filter { TubeLineID(rawValue: $0.lineId) != nil }
            .reduce(into: [String: TfLArrivalPrediction]()) { $0[$1.id] = $1 }
            .values
            .sorted { ($0.timeToStation ?? .max) < ($1.timeToStation ?? .max) }
    }
}
