import CoreLocation
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

    func remainingSecondsToNextStation(at date: Date) -> Int {
        guard progress < LiveTrainMarkerPolicy.arrivalProgressThreshold else {
            return 0
        }
        let elapsedSeconds = max(0, Int(date.timeIntervalSince(updatedAt)))
        return max(0, secondsToNextStation - elapsedSeconds)
    }

    func estimatedNextStopArrival(at date: Date) -> Date {
        date.addingTimeInterval(Double(remainingSecondsToNextStation(at: date)))
    }

    func rebased(
        progress: Double,
        secondsToNextStation: Int,
        updatedAt: Date,
        retainingRouteFrom routeSource: LiveTubeTrain? = nil
    ) -> LiveTubeTrain {
        let routeSource = routeSource ?? self
        return LiveTubeTrain(
            id: id,
            vehicleID: vehicleID,
            lineID: lineID,
            destination: routeSource.destination,
            direction: routeSource.direction,
            previousStationID: routeSource.previousStationID,
            nextStationID: routeSource.nextStationID,
            segmentID: routeSource.segmentID,
            progress: min(1, max(0, progress)),
            secondsToNextStation: max(1, secondsToNextStation),
            updatedAt: updatedAt
        )
    }

}

enum LiveTrainDirection {
    static func resolved(direction: String?, platformName: String?) -> String? {
        cardinalDisplayName(for: platformName)
            ?? cardinalDisplayName(for: direction)
            ?? displayName(for: direction)
            ?? displayName(for: platformName)
    }

    static func displayName(for value: String?) -> String? {
        cardinalDisplayName(for: value) ?? generalDisplayName(for: value)
    }

    private static func cardinalDisplayName(for value: String?) -> String? {
        guard let normalized = normalized(value) else { return nil }

        if normalized.contains("northbound") { return "Northbound" }
        if normalized.contains("southbound") { return "Southbound" }
        if normalized.contains("eastbound") { return "Eastbound" }
        if normalized.contains("westbound") { return "Westbound" }
        if normalized.contains("anti clockwise") || normalized.contains("anticlockwise") {
            return "Anti-clockwise"
        }
        if normalized.contains("counterclockwise") || normalized.contains("counter clockwise") {
            return "Anti-clockwise"
        }
        if normalized.contains("clockwise") { return "Clockwise" }
        return nil
    }

    private static func generalDisplayName(for value: String?) -> String? {
        guard let normalized = normalized(value) else { return nil }
        if normalized.contains("inbound") { return "Inbound" }
        if normalized.contains("outbound") { return "Outbound" }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

enum LiveTrainSnapshotReconciler {
    static let continuityLifetime: TimeInterval = 75
    static let missingSnapshotGrace: TimeInterval = 45
    static let maximumCorrectionDuration: TimeInterval = 30
    static let maximumDisplaySpeedMetresPerSecond = 160.0 / 3.6
    static let fallbackCorrectionDuration: TimeInterval = 30

    static func reconcile(
        previous: [LiveTubeTrain],
        incoming: [LiveTubeTrain],
        at date: Date,
        segmentsByID: [String: TubeSegment],
        requestedLineIDs: Set<TubeLineID> = []
    ) -> [LiveTubeTrain] {
        let previous = deduplicated(previous)
        let incoming = deduplicated(incoming)
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let incomingIDs = Set(incoming.map(\.id))
        var output = incoming.map { train in
            guard let previousTrain = previousByID[train.id],
                  isFresh(previousTrain, at: date) else {
                return train
            }
            return reconcile(
                previous: previousTrain,
                incoming: train,
                at: date,
                segmentsByID: segmentsByID
            )
        }

        for train in previous where !incomingIDs.contains(train.id) {
            guard requestedLineIDs.isEmpty || requestedLineIDs.contains(train.lineID),
                  date.timeIntervalSince(train.updatedAt) <= missingSnapshotGrace else {
                continue
            }
            output.append(retainedMissingTrain(train, at: date))
        }

        return output.sorted { $0.id < $1.id }
    }

    private static func deduplicated(_ trains: [LiveTubeTrain]) -> [LiveTubeTrain] {
        var trainsByID: [String: LiveTubeTrain] = [:]
        for train in trains {
            guard let current = trainsByID[train.id] else {
                trainsByID[train.id] = train
                continue
            }

            if train.updatedAt > current.updatedAt
                || (train.updatedAt == current.updatedAt
                    && train.secondsToNextStation < current.secondsToNextStation) {
                trainsByID[train.id] = train
            }
        }
        return Array(trainsByID.values)
    }

    static func isContinuousJourney(
        from previous: LiveTubeTrain,
        to incoming: LiveTubeTrain,
        at date: Date
    ) -> Bool {
        guard previous.id == incoming.id, isFresh(previous, at: date) else {
            return false
        }
        return isSameLeg(previous, incoming) || isConnectedLeg(previous, incoming)
    }

    private static func reconcile(
        previous: LiveTubeTrain,
        incoming: LiveTubeTrain,
        at date: Date,
        segmentsByID: [String: TubeSegment]
    ) -> LiveTubeTrain {
        let displayedProgress = previous.projectedProgress(at: date)

        if isSameLeg(previous, incoming) {
            if displayedProgress >= LiveTrainMarkerPolicy.arrivalProgressThreshold {
                return incoming.rebased(
                    progress: 1,
                    secondsToNextStation: incoming.secondsToNextStation,
                    updatedAt: incoming.updatedAt
                )
            }
            let minimumSeconds = correctionDuration(
                segment: segmentsByID[incoming.segmentID],
                remainingProgress: 1 - displayedProgress
            )
            return incoming.rebased(
                progress: displayedProgress,
                secondsToNextStation: max(incoming.secondsToNextStation, minimumSeconds),
                updatedAt: incoming.updatedAt
            )
        }

        if isConnectedLeg(previous, incoming) {
            guard displayedProgress >= LiveTrainMarkerPolicy.arrivalProgressThreshold else {
                let minimumSeconds = correctionDuration(
                    segment: segmentsByID[previous.segmentID],
                    remainingProgress: 1 - displayedProgress
                )
                return previous.rebased(
                    progress: displayedProgress,
                    secondsToNextStation: minimumSeconds,
                    updatedAt: incoming.updatedAt
                )
            }
            let minimumSeconds = correctionDuration(
                segment: segmentsByID[incoming.segmentID],
                remainingProgress: 1
            )
            return incoming.rebased(
                progress: 0,
                secondsToNextStation: max(incoming.secondsToNextStation, minimumSeconds),
                updatedAt: incoming.updatedAt
            )
        }

        // A fresh vehicle ID that suddenly moves to an unrelated section is
        // usually a feed correction or identifier reuse. Hold the old marker
        // briefly instead of visibly teleporting it across the network.
        return retainedMissingTrain(previous, at: date)
    }

    private static func retainedMissingTrain(
        _ train: LiveTubeTrain,
        at date: Date
    ) -> LiveTubeTrain {
        let displayedProgress = train.projectedProgress(at: date)
        guard displayedProgress >= LiveTrainMarkerPolicy.arrivalProgressThreshold else {
            return train
        }
        return train.rebased(
            progress: 1,
            secondsToNextStation: train.secondsToNextStation,
            updatedAt: train.updatedAt
        )
    }

    private static func isFresh(_ train: LiveTubeTrain, at date: Date) -> Bool {
        let age = date.timeIntervalSince(train.updatedAt)
        return age >= 0 && age <= continuityLifetime
    }

    private static func isSameLeg(
        _ previous: LiveTubeTrain,
        _ incoming: LiveTubeTrain
    ) -> Bool {
        previous.lineID == incoming.lineID
            && previous.segmentID == incoming.segmentID
            && previous.previousStationID == incoming.previousStationID
            && previous.nextStationID == incoming.nextStationID
    }

    private static func isConnectedLeg(
        _ previous: LiveTubeTrain,
        _ incoming: LiveTubeTrain
    ) -> Bool {
        previous.lineID == incoming.lineID
            && previous.nextStationID == incoming.previousStationID
    }

    private static func correctionDuration(
        segment: TubeSegment?,
        remainingProgress: Double
    ) -> Int {
        let clampedProgress = min(1, max(0, remainingProgress))
        let rawDuration: TimeInterval
        if let segment {
            rawDuration = segmentLength(segment) * clampedProgress
                / maximumDisplaySpeedMetresPerSecond
        } else {
            rawDuration = fallbackCorrectionDuration * clampedProgress
        }
        return max(1, Int(ceil(min(maximumCorrectionDuration, rawDuration))))
    }

    private static func segmentLength(_ segment: TubeSegment) -> CLLocationDistance {
        zip(segment.geographicPoints, segment.geographicPoints.dropFirst())
            .reduce(0) { distance, pair in
                distance + CLLocation(
                    latitude: pair.0.latitude,
                    longitude: pair.0.longitude
                ).distance(from: CLLocation(
                    latitude: pair.1.latitude,
                    longitude: pair.1.longitude
                ))
            }
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

enum LiveTrainServicePresentation: Equatable, Sendable {
    case lineOpen
    case lineClosed

    static let closedLineMarkerSystemName = "ghost.fill"

    static func resolve(
        lineID: TubeLineID,
        closedLineIDs: Set<TubeLineID>
    ) -> Self {
        closedLineIDs.contains(lineID) ? .lineClosed : .lineOpen
    }

    var markerSystemName: String? {
        self == .lineClosed ? Self.closedLineMarkerSystemName : nil
    }

    func informationalNote(for lineID: TubeLineID) -> String? {
        guard self == .lineClosed else { return nil }
        let lineName = lineID.isUnderground
            ? "\(lineID.displayName) line"
            : lineID.displayName
        return "This train is unlikely to be in service because the \(lineName) is closed. It is shown only because TfL data says it is here."
    }
}

enum LiveTrainMarkerPolicy {
    /// Tram and DLR stops are close enough that a much longer countdown is
    /// commonly a future scheduled working, for which placing a physical
    /// marker on the preceding segment is false precision. This intentionally
    /// does not constrain heavy-rail lines with longer inter-station runs.
    static let maximumLightRailSecondsToNearestStation = 5 * 60

    static let arrivalProgressThreshold = 0.98

    private static let arrivalGrace: TimeInterval = 10
    private static let stationLatchLifetime: TimeInterval = 45
    private static let stationBoardLifetime: TimeInterval = 75
    private static let maximumBoardSkew: TimeInterval = 90

    static func projectedProgress(
        for train: LiveTubeTrain,
        at date: Date,
        stationBoard: LiveTrainStationBoardSnapshot?
    ) -> Double? {
        let elapsed = max(0, date.timeIntervalSince(train.updatedAt))
        let projectionLifetime = train.progress >= arrivalProgressThreshold
            ? max(stationLatchLifetime, Double(train.secondsToNextStation) + arrivalGrace)
            : Double(train.secondsToNextStation) + arrivalGrace
        guard elapsed <= projectionLifetime else {
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
