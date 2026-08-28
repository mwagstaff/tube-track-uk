import Foundation

struct LiveTubeTrain: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let vehicleID: String
    let lineID: TubeLineID
    let destination: String?
    let direction: String?
    let previousStationID: String
    let nextStationID: String
    let segmentID: String
    let progress: Double
    let secondsToNextStation: Int
    let updatedAt: Date

    func projectedProgress(at date: Date) -> Double {
        guard secondsToNextStation > 0 else { return progress }
        let elapsed = max(0, date.timeIntervalSince(updatedAt))
        let remainingProgress = max(0, 1 - progress)
        return min(
            1,
            progress + remainingProgress * elapsed / Double(secondsToNextStation)
        )
    }
}

/// The stop-specific departure board is the strongest live signal available
/// when the user has selected a station. Keep that snapshot separate from the
/// network-wide predictions used to estimate marker positions so renderers can
/// reject a marker without mutating the underlying live-train collection.
struct LiveTrainStationBoardSnapshot: Sendable {
    let stationID: String
    let arrivals: [TfLArrivalPrediction]
    let updatedAt: Date
}

enum LiveTrainMarkerPolicy {
    /// Tram and DLR stops are close enough that a much longer countdown is
    /// commonly a future scheduled working, for which placing a physical
    /// marker on the preceding segment is false precision. This intentionally
    /// does not constrain heavy-rail lines with longer inter-station runs.
    static let maximumLightRailSecondsToNearestStation = 5 * 60

    private static let arrivalGrace: TimeInterval = 10
    private static let stationBoardLifetime: TimeInterval = 75
    private static let maximumBoardSkew: TimeInterval = 90

    static func projectedProgress(
        for train: LiveTubeTrain,
        at date: Date,
        stationBoard: LiveTrainStationBoardSnapshot?
    ) -> Double? {
        let elapsed = max(0, date.timeIntervalSince(train.updatedAt))
        guard elapsed <= Double(train.secondsToNextStation) + arrivalGrace else {
            return nil
        }

        let progress = train.projectedProgress(at: date)
        guard let stationBoard,
              stationBoard.stationID == train.nextStationID,
              date.timeIntervalSince(stationBoard.updatedAt) <= stationBoardLifetime else {
            return progress
        }

        let lineArrivals = stationBoard.arrivals.filter { $0.lineId == train.lineID.rawValue }
        guard !lineArrivals.isEmpty else {
            // A successful empty board means no train is currently forecast to
            // call at this station, so a marker approaching it cannot be true.
            return nil
        }

        let arrivalsWithVehicleIDs = lineArrivals.filter {
            normalizedVehicleID($0.vehicleId) != nil
        }
        guard !arrivalsWithVehicleIDs.isEmpty else {
            // Some feeds (notably DLR) do not expose vehicle IDs. Their board
            // cannot safely be matched to one estimated marker.
            return progress
        }

        let vehicleID = normalizedVehicleID(train.vehicleID)
        guard let boardArrival = arrivalsWithVehicleIDs.first(where: {
            normalizedVehicleID($0.vehicleId) == vehicleID
        }) else {
            return nil
        }

        if let boardSeconds = remainingSeconds(
            for: boardArrival,
            snapshotUpdatedAt: stationBoard.updatedAt,
            at: date
        ) {
            let markerSeconds = max(0, Double(train.secondsToNextStation) - elapsed)
            guard abs(boardSeconds - markerSeconds) <= maximumBoardSkew else {
                // Both feeds name the same vehicle but disagree too much for
                // the inferred segment position to be credible.
                return nil
            }
        }

        return progress
    }

    private static func remainingSeconds(
        for arrival: TfLArrivalPrediction,
        snapshotUpdatedAt: Date,
        at date: Date
    ) -> TimeInterval? {
        if let expectedArrival = arrival.expectedArrival {
            return max(0, expectedArrival.timeIntervalSince(date))
        }
        guard let timeToStation = arrival.timeToStation else { return nil }
        let snapshotAge = max(0, date.timeIntervalSince(snapshotUpdatedAt))
        return max(0, Double(timeToStation) - snapshotAge)
    }

    private static func normalizedVehicleID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}
