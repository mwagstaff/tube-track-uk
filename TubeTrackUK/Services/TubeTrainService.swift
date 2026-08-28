import Foundation

protocol LiveTrainFetching: Sendable {
    func fetch(lineIDs: Set<TubeLineID>) async throws -> [LiveTubeTrain]
}

actor TubeTrainService: LiveTrainFetching {
    private let client: TfLClient
    private let repository: TubeNetworkRepository
    private var tramContextsByVehicleID: [String: TramVehicleRouteContext] = [:]

    init(client: TfLClient, repository: TubeNetworkRepository) {
        self.client = client
        self.repository = repository
    }

    func fetch(lineIDs: Set<TubeLineID>) async throws -> [LiveTubeTrain] {
        let requestedLines = TubeTrainRequestBatcher.requestedLines(for: lineIDs)
        guard !requestedLines.isEmpty else { return [] }

        let requested = Set(requestedLines)
        var nearestByVehicle: [LiveVehicleKey: NearestLivePrediction] = [:]
        nearestByVehicle.reserveCapacity(512)
        var tramPredictionsByVehicleID: [String: [TfLLiveTrainPrediction]] = [:]
        var dlrPredictions: [TfLLiveTrainPrediction] = []

        for batch in TubeTrainRequestBatcher.batches(from: requestedLines) {
            try Task.checkCancellation()
            let pathIDs = batch.map(\.rawValue).joined(separator: ",")
            let predictions: [TfLLiveTrainPrediction] = try await client.get(
                "/Line/\(pathIDs)/Arrivals",
                priority: .background
            )
            try Task.checkCancellation()

            for prediction in predictions {
                guard let lineID = TubeLineID(rawValue: prediction.lineId),
                      requested.contains(lineID),
                      let nextStationID = prediction.naptanId,
                      let seconds = prediction.timeToStation,
                      seconds >= 0 else {
                    continue
                }

                if lineID == .dlr {
                    dlrPredictions.append(prediction)
                    continue
                }
                guard let vehicleID = prediction.vehicleId, !vehicleID.isEmpty else { continue }
                let key = LiveVehicleKey(lineID: lineID, vehicleID: vehicleID)
                if lineID == .tram {
                    tramPredictionsByVehicleID[vehicleID, default: []].append(prediction)
                    continue
                }
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
        }
        try Task.checkCancellation()
        let now = Date.now

        var trains: [LiveTubeTrain] = nearestByVehicle.values.compactMap { nearest in
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

        tramContextsByVehicleID = tramContextsByVehicleID.filter {
            now.timeIntervalSince($0.value.updatedAt) <= TramVehicleRouteResolver.contextLifetime
        }
        for vehicleID in tramPredictionsByVehicleID.keys.sorted() {
            guard let predictions = tramPredictionsByVehicleID[vehicleID],
                  let resolution = TramVehicleRouteResolver.resolve(
                      vehicleID: vehicleID,
                      predictions: predictions,
                      repository: repository,
                      previousContext: tramContextsByVehicleID[vehicleID],
                      now: now
                  ) else {
                continue
            }
            trains.append(resolution.train)
            tramContextsByVehicleID[vehicleID] = resolution.context
        }
        trains.append(contentsOf: DLRPredictionResolver.resolve(
            predictions: dlrPredictions,
            repository: repository,
            now: now
        ))

        return trains.sorted { $0.id < $1.id }
    }
}

struct TramVehicleRouteContext: Equatable, Sendable {
    let routeIndex: Int
    let previousStationID: String
    let nextStationID: String
    let updatedAt: Date
}

struct TramVehicleResolution: Sendable {
    let train: LiveTubeTrain
    let context: TramVehicleRouteContext
}

enum TramVehicleRouteResolver {
    static let contextLifetime: TimeInterval = 180

    static func resolve(
        vehicleID: String,
        predictions: [TfLLiveTrainPrediction],
        repository: TubeNetworkRepository,
        previousContext: TramVehicleRouteContext?,
        now: Date
    ) -> TramVehicleResolution? {
        guard let line = repository.graph.line(.tram) else { return nil }

        let usable = predictions.compactMap { prediction -> TramObservation? in
            guard prediction.lineId == TubeLineID.tram.rawValue,
                  let stationID = prediction.naptanId,
                  let seconds = prediction.timeToStation,
                  seconds >= 0 else {
                return nil
            }
            return TramObservation(prediction: prediction, stationID: stationID, seconds: seconds)
        }
        guard let nearest = usable.min(by: observationOrder) else { return nil }
        guard nearest.seconds <= LiveTrainMarkerPolicy.maximumLightRailSecondsToNearestStation else {
            return nil
        }

        // TfL can briefly return stale predictions for the same vehicle after a
        // destination changes. Route matching only one coherent journey avoids
        // turning that overlap into a branch jump.
        let journeyIdentity = destinationIdentity(for: nearest.prediction)
        let coherent = journeyIdentity == nil
            ? usable
            : usable.filter { destinationIdentity(for: $0.prediction) == journeyIdentity }
        let observations = closestObservationPerStation(coherent)

        let namedDestinationID = nearest.prediction.destinationName
            .flatMap { repository.station(named: $0, on: .tram)?.id }
            ?? nearest.prediction.towards.flatMap { repository.station(named: $0, on: .tram)?.id }
        let destinationStationID = nearest.prediction.destinationNaptanId ?? namedDestinationID

        var candidates = line.routes.enumerated().compactMap { routeIndex, route in
            TramRouteCandidate(
                routeIndex: routeIndex,
                route: route,
                nearest: nearest,
                observations: observations,
                repository: repository
            )
        }
        guard !candidates.isEmpty else { return nil }

        if let destinationStationID {
            let destinationMatches = candidates.filter {
                guard let destinationIndex = $0.route.firstIndex(of: destinationStationID) else { return false }
                return destinationIndex >= $0.nearestIndex
            }
            if !destinationMatches.isEmpty {
                candidates = destinationMatches
            }
        }

        let maximumMatches = candidates.map(\.matchedObservationCount).max() ?? 0
        candidates = candidates.filter { $0.matchedObservationCount == maximumMatches }

        let chosen: TramRouteCandidate
        if let previousContext,
           now.timeIntervalSince(previousContext.updatedAt) <= contextLifetime,
           let contextual = candidates.first(where: { $0.routeIndex == previousContext.routeIndex }) {
            chosen = contextual
        } else {
            let maximumOrderedMatches = candidates.map(\.orderedObservationCount).max() ?? 0
            let finalists = candidates.filter { $0.orderedObservationCount == maximumOrderedMatches }
            let proposals = Set(finalists.map(\.proposal))
            guard proposals.count == 1,
                  let deterministic = finalists.min(by: { $0.routeIndex < $1.routeIndex }) else {
                // At joins such as Sandilands, future-stop data alone cannot
                // always identify the inbound branch. Hiding one marker is
                // safer than displaying it on the wrong track.
                return nil
            }
            chosen = deterministic
        }

        let proposal = chosen.proposal
        guard let segment = repository.segment(
            between: proposal.previousStationID,
            and: proposal.nextStationID,
            on: .tram
        ) else {
            return nil
        }

        let startsAtRouteOrigin = chosen.nearestIndex == 0
        let secondsToNextStation: Int
        let progress: Double
        if startsAtRouteOrigin {
            secondsToNextStation = observations.first(where: {
                $0.stationID == proposal.nextStationID
            })?.seconds ?? max(nearest.seconds + 45, 1)
            progress = 0.05
        } else {
            secondsToNextStation = max(nearest.seconds, 1)
            progress = estimatedProgress(
                seconds: nearest.seconds,
                currentLocation: nearest.prediction.currentLocation
            )
        }

        let train = LiveTubeTrain(
            id: "\(TubeLineID.tram.rawValue):\(vehicleID)",
            vehicleID: vehicleID,
            lineID: .tram,
            destination: nearest.prediction.destinationName ?? nearest.prediction.towards,
            direction: nearest.prediction.direction ?? nearest.prediction.platformName,
            previousStationID: proposal.previousStationID,
            nextStationID: proposal.nextStationID,
            segmentID: segment.id,
            progress: progress,
            secondsToNextStation: max(secondsToNextStation, 1),
            updatedAt: now
        )
        return TramVehicleResolution(
            train: train,
            context: TramVehicleRouteContext(
                routeIndex: chosen.routeIndex,
                previousStationID: proposal.previousStationID,
                nextStationID: proposal.nextStationID,
                updatedAt: now
            )
        )
    }

    private static func closestObservationPerStation(_ observations: [TramObservation]) -> [TramObservation] {
        var closest: [String: TramObservation] = [:]
        for observation in observations {
            if let current = closest[observation.stationID],
               !observationOrder(observation, current) {
                continue
            }
            closest[observation.stationID] = observation
        }
        return closest.values.sorted(by: observationOrder)
    }

    private static func destinationIdentity(for prediction: TfLLiveTrainPrediction) -> String? {
        if let destinationNaptanId = prediction.destinationNaptanId, !destinationNaptanId.isEmpty {
            return "id:\(destinationNaptanId)"
        }
        if let destinationName = prediction.destinationName, !destinationName.isEmpty {
            return "name:\(destinationName.lowercased())"
        }
        if let towards = prediction.towards, !towards.isEmpty {
            return "towards:\(towards.lowercased())"
        }
        return nil
    }

    private static func observationOrder(_ left: TramObservation, _ right: TramObservation) -> Bool {
        if left.seconds != right.seconds { return left.seconds < right.seconds }
        return left.stationID < right.stationID
    }

    private static func estimatedProgress(seconds: Int, currentLocation: String?) -> Double {
        let baselineDuration = max(75, min(180, seconds + 45))
        if currentLocation?.localizedCaseInsensitiveContains("at platform") == true {
            return 1
        }
        return max(0.05, min(0.95, 1 - Double(seconds) / Double(baselineDuration)))
    }
}

private struct TramObservation: Sendable {
    let prediction: TfLLiveTrainPrediction
    let stationID: String
    let seconds: Int
}

private struct TramRouteProposal: Hashable, Sendable {
    let previousStationID: String
    let nextStationID: String
}

private struct TramRouteCandidate: Sendable {
    let routeIndex: Int
    let route: [String]
    let nearestIndex: Int
    let matchedObservationCount: Int
    let orderedObservationCount: Int
    let proposal: TramRouteProposal

    init?(
        routeIndex: Int,
        route: [String],
        nearest: TramObservation,
        observations: [TramObservation],
        repository: TubeNetworkRepository
    ) {
        guard let nearestIndex = route.firstIndex(of: nearest.stationID) else { return nil }

        let routeIndices = observations.compactMap { observation -> Int? in
            guard let index = route.firstIndex(of: observation.stationID), index >= nearestIndex else {
                return nil
            }
            return index
        }
        var lastIndex = nearestIndex
        var orderedObservationCount = 0
        for index in routeIndices where index >= lastIndex {
            orderedObservationCount += 1
            lastIndex = index
        }

        let proposal: TramRouteProposal
        if nearestIndex == 0 {
            guard route.count > 1,
                  repository.segment(between: route[0], and: route[1], on: .tram) != nil else {
                return nil
            }
            proposal = TramRouteProposal(previousStationID: route[0], nextStationID: route[1])
        } else {
            guard repository.segment(
                between: route[nearestIndex - 1],
                and: route[nearestIndex],
                on: .tram
            ) != nil else {
                return nil
            }
            proposal = TramRouteProposal(
                previousStationID: route[nearestIndex - 1],
                nextStationID: route[nearestIndex]
            )
        }

        self.routeIndex = routeIndex
        self.route = route
        self.nearestIndex = nearestIndex
        self.matchedObservationCount = routeIndices.count
        self.orderedObservationCount = orderedObservationCount
        self.proposal = proposal
    }
}

enum DLRPredictionResolver {
    static func resolve(
        predictions: [TfLLiveTrainPrediction],
        repository: TubeNetworkRepository,
        now: Date
    ) -> [LiveTubeTrain] {
        guard let line = repository.graph.line(.dlr) else { return [] }

        let directionalRoutes = line.routes.enumerated().flatMap { routeIndex, route in
            [
                DLRDirectionalRoute(id: routeIndex * 2, stationIDs: route),
                DLRDirectionalRoute(id: routeIndex * 2 + 1, stationIDs: route.reversed()),
            ]
        }
        var seenPredictions: Set<DLRPredictionKey> = []
        let observations = predictions.enumerated().compactMap { sourceIndex, prediction -> DLRObservation? in
            guard prediction.lineId == TubeLineID.dlr.rawValue,
                  let stationID = prediction.naptanId,
                  let destinationStationID = prediction.destinationNaptanId,
                  let seconds = prediction.timeToStation,
                  (0 ... LiveTrainMarkerPolicy.maximumLightRailSecondsToNearestStation).contains(seconds) else {
                return nil
            }
            let key = DLRPredictionKey(
                stationID: stationID,
                destinationStationID: destinationStationID,
                seconds: seconds
            )
            guard seenPredictions.insert(key).inserted else { return nil }
            return DLRObservation(
                sourceIndex: sourceIndex,
                prediction: prediction,
                stationID: stationID,
                destinationStationID: destinationStationID,
                seconds: seconds
            )
        }

        var output: [LiveTubeTrain] = []
        var emittedOrigins: Set<DLROriginKey> = []
        for destinationStationID in Set(observations.map(\.destinationStationID)).sorted() {
            let group = observations
                .filter { $0.destinationStationID == destinationStationID }
                .sorted(by: dlrObservationOrder)
            let candidatesBySourceIndex = Dictionary(uniqueKeysWithValues: group.map { observation in
                let candidates = directionalRoutes.compactMap { route in
                    DLRRouteCandidate(
                        route: route,
                        observation: observation,
                        repository: repository
                    )
                }
                return (observation.sourceIndex, candidates)
            })

            let shadowed = Set(group.compactMap { observation -> Int? in
                guard let candidates = candidatesBySourceIndex[observation.sourceIndex] else { return nil }
                let predecessorIDs = Set(candidates.compactMap(\.predecessorStationID))
                guard !predecessorIDs.isEmpty else { return nil }
                let hasEarlierPrediction = group.contains { earlier in
                    guard predecessorIDs.contains(earlier.stationID),
                          earlier.seconds < observation.seconds else {
                        return false
                    }
                    let interval = observation.seconds - earlier.seconds
                    return (15 ... 240).contains(interval)
                }
                return hasEarlierPrediction ? observation.sourceIndex : nil
            })

            for observation in group where !shadowed.contains(observation.sourceIndex) {
                guard let candidates = candidatesBySourceIndex[observation.sourceIndex],
                      let chosen = unambiguousCandidate(from: candidates) else {
                    continue
                }
                let proposal = chosen.proposal
                if chosen.stationIndex == 0 {
                    let originKey = DLROriginKey(
                        stationID: observation.stationID,
                        destinationStationID: destinationStationID
                    )
                    // Countdown boards include several future departures at a
                    // terminal. Only the first can represent a vehicle that is
                    // currently at, or about to leave, that platform.
                    guard emittedOrigins.insert(originKey).inserted else { continue }
                }
                guard let segment = repository.segment(
                    between: proposal.previousStationID,
                    and: proposal.nextStationID,
                    on: .dlr
                ) else {
                    continue
                }

                let startsAtRouteOrigin = chosen.stationIndex == 0
                let secondsToNextStation: Int
                let progress: Double
                if startsAtRouteOrigin {
                    secondsToNextStation = group.first(where: {
                        $0.stationID == proposal.nextStationID && $0.seconds > observation.seconds
                    })?.seconds ?? max(observation.seconds + 45, 1)
                    progress = 0.05
                } else {
                    secondsToNextStation = max(observation.seconds, 1)
                    progress = estimatedDLRProgress(
                        seconds: observation.seconds,
                        currentLocation: observation.prediction.currentLocation
                    )
                }

                // DLR predictions do not currently expose vehicle IDs. The
                // station, destination and absolute arrival slot provide a
                // stable identity while a vehicle approaches its next stop.
                let absoluteArrivalSlot = Int(
                    (now.timeIntervalSince1970 + Double(observation.seconds)) / 30
                )
                let syntheticID = [
                    TubeLineID.dlr.rawValue,
                    destinationStationID,
                    observation.stationID,
                    String(absoluteArrivalSlot),
                ].joined(separator: ":")
                output.append(LiveTubeTrain(
                    id: syntheticID,
                    vehicleID: "DLR-\(absoluteArrivalSlot)",
                    lineID: .dlr,
                    destination: observation.prediction.destinationName ?? observation.prediction.towards,
                    direction: observation.prediction.direction ?? observation.prediction.platformName,
                    previousStationID: proposal.previousStationID,
                    nextStationID: proposal.nextStationID,
                    segmentID: segment.id,
                    progress: progress,
                    secondsToNextStation: max(secondsToNextStation, 1),
                    updatedAt: now
                ))
            }
        }
        return output.sorted { $0.id < $1.id }
    }

    private static func unambiguousCandidate(from candidates: [DLRRouteCandidate]) -> DLRRouteCandidate? {
        let proposals = Set(candidates.map(\.proposal))
        guard proposals.count == 1 else { return nil }
        return candidates.min { $0.route.id < $1.route.id }
    }

    private static func dlrObservationOrder(_ left: DLRObservation, _ right: DLRObservation) -> Bool {
        if left.seconds != right.seconds { return left.seconds < right.seconds }
        if left.stationID != right.stationID { return left.stationID < right.stationID }
        return left.sourceIndex < right.sourceIndex
    }

    private static func estimatedDLRProgress(seconds: Int, currentLocation: String?) -> Double {
        let baselineDuration = max(75, min(180, seconds + 45))
        if currentLocation?.localizedCaseInsensitiveContains("at platform") == true {
            return 1
        }
        return max(0.05, min(0.95, 1 - Double(seconds) / Double(baselineDuration)))
    }
}

private struct DLRPredictionKey: Hashable {
    let stationID: String
    let destinationStationID: String
    let seconds: Int
}

private struct DLROriginKey: Hashable {
    let stationID: String
    let destinationStationID: String
}

private struct DLRObservation: Sendable {
    let sourceIndex: Int
    let prediction: TfLLiveTrainPrediction
    let stationID: String
    let destinationStationID: String
    let seconds: Int
}

private struct DLRDirectionalRoute: Sendable {
    let id: Int
    let stationIDs: [String]

    init(id: Int, stationIDs: some Sequence<String>) {
        self.id = id
        self.stationIDs = Array(stationIDs)
    }
}

private struct DLRRouteCandidate: Sendable {
    let route: DLRDirectionalRoute
    let stationIndex: Int
    let predecessorStationID: String?
    let proposal: TramRouteProposal

    init?(
        route: DLRDirectionalRoute,
        observation: DLRObservation,
        repository: TubeNetworkRepository
    ) {
        guard let stationIndex = route.stationIDs.firstIndex(of: observation.stationID),
              let destinationIndex = route.stationIDs.firstIndex(of: observation.destinationStationID),
              destinationIndex >= stationIndex else {
            return nil
        }

        let proposal: TramRouteProposal
        if stationIndex == 0 {
            guard route.stationIDs.count > 1,
                  repository.segment(
                      between: route.stationIDs[0],
                      and: route.stationIDs[1],
                      on: .dlr
                  ) != nil else {
                return nil
            }
            proposal = TramRouteProposal(
                previousStationID: route.stationIDs[0],
                nextStationID: route.stationIDs[1]
            )
        } else {
            guard repository.segment(
                between: route.stationIDs[stationIndex - 1],
                and: route.stationIDs[stationIndex],
                on: .dlr
            ) != nil else {
                return nil
            }
            proposal = TramRouteProposal(
                previousStationID: route.stationIDs[stationIndex - 1],
                nextStationID: route.stationIDs[stationIndex]
            )
        }

        self.route = route
        self.stationIndex = stationIndex
        self.predecessorStationID = stationIndex > 0 ? route.stationIDs[stationIndex - 1] : nil
        self.proposal = proposal
    }
}

enum TubeTrainRequestBatcher {
    static let maximumBatchSize = 3

    static func requestedLines(for lineIDs: Set<TubeLineID>) -> [TubeLineID] {
        (lineIDs.isEmpty ? TubeLineID.allCases : Array(lineIDs))
            .filter(\.supportsEstimatedTrains)
            .sorted { $0.rawValue < $1.rawValue }
    }

    static func batches(from requestedLines: [TubeLineID]) -> [[TubeLineID]] {
        guard !requestedLines.isEmpty else { return [] }
        return stride(from: 0, to: requestedLines.count, by: maximumBatchSize).map { start in
            let end = min(start + maximumBatchSize, requestedLines.count)
            return Array(requestedLines[start ..< end])
        }
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
