import Foundation

actor TubeTrainService {
    private let client: TfLClient
    private let repository: TubeNetworkRepository

    init(client: TfLClient, repository: TubeNetworkRepository) {
        self.client = client
        self.repository = repository
    }

    func fetch(lineIDs: Set<TubeLineID>) async throws -> [LiveTubeTrain] {
        let requested = Set(
            (lineIDs.isEmpty ? Set(TubeLineID.allCases) : lineIDs)
                .filter(\.supportsEstimatedTrains)
        )
        guard !requested.isEmpty else { return [] }

        let pathIDs = requested.map(\.rawValue).sorted().joined(separator: ",")
        let predictions: [TfLLiveTrainPrediction] = try await client.get("/Line/\(pathIDs)/Arrivals")
        var nearestByVehicle: [LiveVehicleKey: NearestLivePrediction] = [:]
        nearestByVehicle.reserveCapacity(min(512, predictions.count))

        for prediction in predictions {
            guard let vehicleID = prediction.vehicleId,
                  let lineID = TubeLineID(rawValue: prediction.lineId),
                  requested.contains(lineID),
                  let nextStationID = prediction.naptanId,
                  let seconds = prediction.timeToStation,
                  seconds >= 0 else {
                continue
            }

            let key = LiveVehicleKey(lineID: lineID, vehicleID: vehicleID)
            if let existing = nearestByVehicle[key], existing.seconds <= seconds {
                continue
            }
            nearestByVehicle[key] = NearestLivePrediction(
                prediction: prediction,
                lineID: lineID,
                vehicleID: vehicleID,
                nextStationID: nextStationID,
                seconds: seconds
            )
        }
        let now = Date.now

        return nearestByVehicle.values.compactMap { nearest in
            let prediction = nearest.prediction
            guard let previousStationID = repository.neighboringStation(
                      for: nearest.nextStationID,
                      on: nearest.lineID,
                      direction: prediction.direction,
                      destinationStationID: prediction.destinationNaptanId
                  ),
                  let segment = repository.segment(
                      between: previousStationID,
                      and: nearest.nextStationID,
                      on: nearest.lineID
                  ) else {
                return nil
            }

            let baselineDuration = max(75, min(180, nearest.seconds + 45))
            let atPlatform = prediction.currentLocation?.localizedCaseInsensitiveContains("at platform") == true
            let progress = atPlatform
                ? 1.0
                : max(0.05, min(0.95, 1 - Double(nearest.seconds) / Double(baselineDuration)))
            return LiveTubeTrain(
                id: "\(nearest.lineID.rawValue):\(nearest.vehicleID)",
                vehicleID: nearest.vehicleID,
                lineID: nearest.lineID,
                destination: prediction.destinationName ?? prediction.towards,
                direction: prediction.direction,
                previousStationID: previousStationID,
                nextStationID: nearest.nextStationID,
                segmentID: segment.id,
                progress: progress,
                secondsToNextStation: max(nearest.seconds, 1),
                updatedAt: now
            )
        }
        .sorted { $0.id < $1.id }
    }
}

private struct LiveVehicleKey: Hashable, Sendable {
    let lineID: TubeLineID
    let vehicleID: String
}

private struct NearestLivePrediction: Sendable {
    let prediction: TfLLiveTrainPrediction
    let lineID: TubeLineID
    let vehicleID: String
    let nextStationID: String
    let seconds: Int
}
