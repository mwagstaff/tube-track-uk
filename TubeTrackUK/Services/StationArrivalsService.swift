import Foundation

actor StationArrivalsService {
    private let client: TfLClient

    init(client: TfLClient) {
        self.client = client
    }

    func fetch(stationID: String) async throws -> [TfLArrivalPrediction] {
        let predictions: [TfLArrivalPrediction] = try await client.get("/StopPoint/\(stationID)/Arrivals")
        return predictions
            .filter { TubeLineID(rawValue: $0.lineId) != nil }
            .sorted { ($0.timeToStation ?? .max) < ($1.timeToStation ?? .max) }
    }
}
