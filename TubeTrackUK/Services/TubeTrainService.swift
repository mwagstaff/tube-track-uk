import Foundation

actor TubeTrainService {
    private let client: TfLClient
    private let repository: TubeNetworkRepository

    init(client: TfLClient, repository: TubeNetworkRepository) {
        self.client = client
        self.repository = repository
    }

    func fetch(lineIDs: Set<TubeLineID>) async throws -> [LiveTubeTrain] {
        let requested = lineIDs.isEmpty ? Set(TubeLineID.allCases) : lineIDs
        let pathIDs = requested.map(\.rawValue).sorted().joined(separator: ",")
        let predictions: [TfLArrivalPrediction] = try await client.get("/Line/\(pathIDs)/Arrivals")
        let grouped = Dictionary(grouping: predictions) { prediction in
            "\(prediction.lineId):\(prediction.vehicleId ?? prediction.id)"
        }
        let now = Date.now

        return grouped.values.compactMap { entries in
            guard let next = entries
                .filter({ ($0.timeToStation ?? -1) >= 0 })
                .min(by: { ($0.timeToStation ?? .max) < ($1.timeToStation ?? .max) }),
                  let vehicleID = next.vehicleId,
                  let lineID = TubeLineID(rawValue: next.lineId),
                  let nextStationID = next.naptanId,
                  let previousStationID = repository.neighboringStation(
                      for: nextStationID,
                      on: lineID,
                      direction: next.direction
                  ),
                  let segment = repository.segment(
                      between: previousStationID,
                      and: nextStationID,
                      on: lineID
                  ) else {
                return nil
            }

            let seconds = max(0, next.timeToStation ?? 0)
            let baselineDuration = max(75, min(180, seconds + 45))
            let atPlatform = next.currentLocation?.localizedCaseInsensitiveContains("at platform") == true
            let progress = atPlatform ? 1.0 : max(0.05, min(0.95, 1 - Double(seconds) / Double(baselineDuration)))
            return LiveTubeTrain(
                id: "\(lineID.rawValue):\(vehicleID)",
                vehicleID: vehicleID,
                lineID: lineID,
                destination: next.destinationName ?? next.towards,
                direction: next.direction,
                previousStationID: previousStationID,
                nextStationID: nextStationID,
                segmentID: segment.id,
                progress: progress,
                secondsToNextStation: max(seconds, 1),
                updatedAt: now
            )
        }
        .sorted { $0.id < $1.id }
    }
}
