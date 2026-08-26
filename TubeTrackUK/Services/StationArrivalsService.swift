import Foundation

actor StationArrivalsService {
    private static let destinationCacheLifetime: TimeInterval = 15 * 60
    private static let destinationFailureCacheLifetime: TimeInterval = 60
    private static let arrivalDepartureLineIDs: Set<String> = [
        TubeLineID.elizabeth.rawValue,
        TubeLineID.liberty.rawValue,
        TubeLineID.lioness.rawValue,
        TubeLineID.mildmay.rawValue,
        TubeLineID.suffragette.rawValue,
        TubeLineID.weaver.rawValue,
        TubeLineID.windrush.rawValue,
    ]

    private let client: TfLClient
    private var destinationsByLineAndStation: [DepartureDestinationKey: CachedDepartureDestination] = [:]

    init(client: TfLClient) {
        self.client = client
    }

    func fetch(stationIDs: [String]) async throws -> [TfLArrivalPrediction] {
        var predictions: [TfLArrivalPrediction] = []
        for stationID in Set(stationIDs).sorted() {
            let arrivals: [TfLArrivalPrediction] = try await client.get("/StopPoint/\(stationID)/Arrivals")
            predictions.append(
                contentsOf: try await correctingSelfReferentialDestinations(
                    in: arrivals,
                    requestedStationID: stationID
                )
            )
        }

        var seenPredictions = Set<TfLArrivalPrediction.DepartureIdentity>()
        let uniquePredictions = predictions.filter { prediction in
            TubeLineID(rawValue: prediction.lineId) != nil
                && seenPredictions.insert(prediction.departureIdentity).inserted
        }

        return coalescedCanaryWharfDLRPlatformFaces(in: uniquePredictions)
            .sorted(by: arrivesSooner)
    }

    /// TfL's arrivals feed includes vehicles that terminate at the requested
    /// station. A departure board must never present those as services to the
    /// same station. Prefer TfL's dedicated rail departure feed when it exists,
    /// retain genuine outbound predictions and one copy of each unknown train,
    /// and use the timetable only when it exposes one unambiguous destination.
    private func correctingSelfReferentialDestinations(
        in predictions: [TfLArrivalPrediction],
        requestedStationID: String
    ) async throws -> [TfLArrivalPrediction] {
        guard let stationID = Self.normalizedID(requestedStationID) else {
            return predictions.map { prediction in
                isSelfReferential(prediction, requestedStationID: requestedStationID)
                    ? prediction.replacingDestination(nil)
                    : prediction
            }
        }
        let affectedLineIDs = Set(predictions.compactMap { prediction -> String? in
            guard TubeLineID(rawValue: prediction.lineId) != nil,
                  isSelfReferential(prediction, requestedStationID: stationID) else {
                return nil
            }
            return prediction.lineId
        })
        guard !affectedLineIDs.isEmpty else { return predictions }

        var corrected = predictions
        for lineID in affectedLineIDs.sorted() {
            let predictionsForLine = corrected.filter { $0.lineId == lineID }
            let predictionsForOtherLines = corrected.filter { $0.lineId != lineID }

            if Self.arrivalDepartureLineIDs.contains(lineID),
               let departures = try await arrivalDeparturePredictions(
                   lineID: lineID,
                   stationID: stationID
               ),
               !departures.isEmpty {
                corrected = predictionsForOtherLines + departures
                continue
            }

            let outboundPredictions = predictionsForLine.filter {
                !isSelfReferential($0, requestedStationID: stationID)
            }
            let terminatingPredictions = coalescedTerminatingPredictions(
                predictionsForLine.filter {
                    isSelfReferential($0, requestedStationID: stationID)
                }
            )
            if !outboundPredictions.isEmpty {
                corrected = predictionsForOtherLines
                    + outboundPredictions
                    + terminatingPredictions.map { $0.replacingDestination(nil) }
                continue
            }

            let destination = try await departureDestination(
                lineID: lineID,
                stationID: stationID
            )
            corrected = predictionsForOtherLines + terminatingPredictions.map { prediction in
                prediction.replacingDestination(destination)
            }
        }
        return corrected
    }

    private func isSelfReferential(
        _ prediction: TfLArrivalPrediction,
        requestedStationID: String
    ) -> Bool {
        let predictionStationID = Self.normalizedID(prediction.naptanId)
            ?? requestedStationID

        if let destinationID = Self.normalizedID(prediction.destinationNaptanId),
           destinationID == predictionStationID {
            return true
        }

        guard let stationName = Self.normalizedStopName(prediction.stationName) else {
            return false
        }
        return [prediction.destinationName, prediction.towards].contains { value in
            guard let candidate = Self.normalizedStopName(value) else { return false }
            return candidate == stationName || candidate.hasPrefix("\(stationName) via ")
        }
    }

    private func arrivalDeparturePredictions(
        lineID: String,
        stationID: String
    ) async throws -> [TfLArrivalPrediction]? {
        do {
            let entries: [TfLArrivalDeparture] = try await client.get(
                "/StopPoint/\(stationID)/ArrivalDepartures",
                queryItems: [URLQueryItem(name: "lineIds", value: lineID)]
            )
            let now = Date.now
            return entries.compactMap {
                $0.departurePrediction(lineID: lineID, now: now)
            }.filter {
                !isSelfReferential($0, requestedStationID: stationID)
            }
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func departureDestination(
        lineID: String,
        stationID: String
    ) async throws -> DepartureDestination? {
        let key = DepartureDestinationKey(lineID: lineID, stationID: stationID)
        let now = Date.now
        if let cached = destinationsByLineAndStation[key],
           cached.expiresAt > now {
            return cached.destination
        }

        do {
            let response: TfLTimetableResponse = try await client.get(
                "/Line/\(lineID)/Timetable/\(stationID)"
            )
            let destination = response.canonicalDestination(excluding: stationID)
            cache(
                destination,
                for: key,
                now: now,
                lifetime: destination == nil
                    ? Self.destinationFailureCacheLifetime
                    : Self.destinationCacheLifetime
            )
            return destination
        } catch {
            try Task.checkCancellation()
            cache(nil, for: key, now: now, lifetime: Self.destinationFailureCacheLifetime)
            return nil
        }
    }

    private func cache(
        _ destination: DepartureDestination?,
        for key: DepartureDestinationKey,
        now: Date,
        lifetime: TimeInterval
    ) {
        destinationsByLineAndStation[key] = CachedDepartureDestination(
            destination: destination,
            expiresAt: now.addingTimeInterval(lifetime)
        )
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.uppercased()
    }

    private static func normalizedStopName(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        for suffix in [" Underground Station", " DLR Station", " Tram Stop", " Rail Station"]
            where value.lowercased().hasSuffix(suffix.lowercased()) {
            value.removeLast(suffix.count)
            break
        }
        return value.lowercased()
    }

    /// Canary Wharf's DLR feed publishes a single logical train against both
    /// faces of an island platform. Keeping both copies can use two of the
    /// three visible departure slots, so combine only the known mirrored
    /// platform pairs while retaining an honest combined platform label.
    private func coalescedCanaryWharfDLRPlatformFaces(
        in predictions: [TfLArrivalPrediction]
    ) -> [TfLArrivalPrediction] {
        var passthrough: [TfLArrivalPrediction] = []
        var clustersByKey: [MirroredDLRDepartureKey: [MirroredDLRDepartureCluster]] = [:]

        for prediction in predictions.sorted(by: arrivesSooner) {
            guard let platform = MirroredDLRPlatform(prediction: prediction) else {
                passthrough.append(prediction)
                continue
            }

            let key = MirroredDLRDepartureKey(
                prediction: prediction,
                platformPair: platform.pair
            )
            var clusters = clustersByKey[key, default: []]

            if let index = clusters.firstIndex(where: {
                !$0.platforms.contains(platform.number)
                    && departuresCoincide($0.prediction, prediction)
            }) {
                clusters[index].platforms.insert(platform.number)
            } else {
                clusters.append(
                    MirroredDLRDepartureCluster(
                        prediction: prediction,
                        platforms: [platform.number]
                    )
                )
            }
            clustersByKey[key] = clusters
        }

        let coalesced = clustersByKey.values.flatMap { clusters in
            clusters.map { cluster in
                guard cluster.platforms.count > 1 else {
                    return cluster.prediction
                }
                let platformNumbers = cluster.platforms
                    .sorted()
                    .map(String.init)
                    .joined(separator: " & ")
                return cluster.prediction.replacingPlatformName(
                    "Platforms \(platformNumbers)"
                )
            }
        }
        return passthrough + coalesced
    }

    private func departuresCoincide(
        _ left: TfLArrivalPrediction,
        _ right: TfLArrivalPrediction
    ) -> Bool {
        if let leftArrival = left.expectedArrival,
           let rightArrival = right.expectedArrival {
            return abs(leftArrival.timeIntervalSince(rightArrival)) <= 2
        }
        if let leftSeconds = left.timeToStation,
           let rightSeconds = right.timeToStation {
            return abs(leftSeconds - rightSeconds) <= 2
        }
        return false
    }

    /// Some terminus feeds publish one incoming train against every platform
    /// it could use. Collapse those alternatives into one train and retain only
    /// the shared direction because TfL has not assigned a platform yet.
    private func coalescedTerminatingPredictions(
        _ predictions: [TfLArrivalPrediction]
    ) -> [TfLArrivalPrediction] {
        var retained: [TfLArrivalPrediction] = []
        for prediction in predictions.sorted(by: arrivesSooner) {
            guard let index = retained.firstIndex(where: {
                sameTerminatingTrain($0, prediction)
            }) else {
                retained.append(prediction)
                continue
            }
            retained[index] = retained[index].replacingPlatformName(
                commonDirectionalPlatform(
                    retained[index].platformName,
                    prediction.platformName
                )
            )
        }
        return retained
    }

    private func sameTerminatingTrain(
        _ left: TfLArrivalPrediction,
        _ right: TfLArrivalPrediction
    ) -> Bool {
        let leftID = left.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rightID = right.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let leftVehicleID = Self.normalizedID(left.vehicleId)
        let rightVehicleID = Self.normalizedID(right.vehicleId)
        let sameSource = !leftID.isEmpty && leftID == rightID
        let sameTrainIdentifier: Bool
        if leftVehicleID != nil || rightVehicleID != nil {
            sameTrainIdentifier = leftVehicleID != nil && leftVehicleID == rightVehicleID
        } else {
            sameTrainIdentifier = sameSource
        }
        return left.lineId == right.lineId
            && sameTrainIdentifier
            && departuresCoincide(left, right)
    }

    private func commonDirectionalPlatform(_ left: String?, _ right: String?) -> String? {
        let directions = ["northbound", "southbound", "eastbound", "westbound"]
        let left = left?.lowercased() ?? ""
        let right = right?.lowercased() ?? ""
        return directions.first(where: { left.contains($0) && right.contains($0) })?
            .capitalized
    }

    private func arrivesSooner(
        _ left: TfLArrivalPrediction,
        _ right: TfLArrivalPrediction
    ) -> Bool {
        if left.timeToStation != right.timeToStation {
            return (left.timeToStation ?? .max) < (right.timeToStation ?? .max)
        }
        if left.expectedArrival != right.expectedArrival {
            return (left.expectedArrival ?? .distantFuture)
                < (right.expectedArrival ?? .distantFuture)
        }
        if left.lineId != right.lineId { return left.lineId < right.lineId }
        if left.destinationName != right.destinationName {
            return (left.destinationName ?? "") < (right.destinationName ?? "")
        }
        if left.platformName != right.platformName {
            return (left.platformName ?? "") < (right.platformName ?? "")
        }
        return left.departureIdentity.sourceID < right.departureIdentity.sourceID
    }
}

private struct DepartureDestinationKey: Hashable, Sendable {
    let lineID: String
    let stationID: String
}

private struct CachedDepartureDestination: Sendable {
    let destination: DepartureDestination?
    let expiresAt: Date
}

private struct DepartureDestination: Sendable {
    let id: String
    let name: String
}

private struct TfLTimetableResponse: Decodable, Sendable {
    let stops: [Stop]
    let timetable: Timetable

    func canonicalDestination(excluding stationID: String) -> DepartureDestination? {
        let normalizedStationID = stationID.uppercased()
        let destinationIDs = Set(timetable.routes
            .flatMap(\.stationIntervals)
            .compactMap { interval -> String? in
                guard let destinationID = interval.intervals.last?.stopId.uppercased(),
                      destinationID != normalizedStationID else {
                    return nil
                }
                return destinationID
            })
        guard destinationIDs.count == 1,
              let destinationID = destinationIDs.first,
              let stop = stops.first(where: {
                  $0.id.uppercased() == destinationID
                      || $0.stationId?.uppercased() == destinationID
              }),
              let destinationName = Self.passengerFacingName(stop.name) else {
            return nil
        }
        return DepartureDestination(id: destinationID, name: destinationName)
    }

    private static func passengerFacingName(_ rawName: String?) -> String? {
        guard var name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        for suffix in [" Underground Station", " DLR Station", " Tram Stop", " Rail Station"]
            where name.lowercased().hasSuffix(suffix.lowercased()) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    struct Stop: Decodable, Sendable {
        let id: String
        let stationId: String?
        let name: String?
    }

    struct Timetable: Decodable, Sendable {
        let routes: [Route]
    }

    struct Route: Decodable, Sendable {
        let stationIntervals: [StationInterval]
    }

    struct StationInterval: Decodable, Sendable {
        let intervals: [Interval]
    }

    struct Interval: Decodable, Sendable {
        let stopId: String
    }
}

private struct TfLArrivalDeparture: Decodable, Sendable {
    let platformName: String?
    let destinationNaptanId: String?
    let destinationName: String?
    let naptanId: String?
    let stationName: String?
    let estimatedTimeOfDeparture: Date?
    let scheduledTimeOfDeparture: Date?
    let minutesAndSecondsToDeparture: String?

    func departurePrediction(
        lineID: String,
        now: Date
    ) -> TfLArrivalPrediction? {
        guard let departureTime = estimatedTimeOfDeparture ?? scheduledTimeOfDeparture,
              let stationID = Self.normalized(naptanId),
              let destinationID = Self.normalized(destinationNaptanId),
              let destinationName = Self.normalized(destinationName) else {
            return nil
        }
        let seconds = Self.departureSeconds(minutesAndSecondsToDeparture)
            ?? max(0, Int(departureTime.timeIntervalSince(now)))
        let platform = Self.normalized(platformName)
        let sourceID = [
            "departure",
            lineID,
            stationID,
            destinationID,
            String(Int(departureTime.timeIntervalSince1970)),
            platform ?? "",
        ].joined(separator: ":")

        return TfLArrivalPrediction(
            id: sourceID,
            vehicleId: nil,
            lineId: lineID,
            stationName: Self.normalized(stationName),
            naptanId: stationID,
            platformName: platform,
            direction: nil,
            destinationName: destinationName,
            destinationNaptanId: destinationID,
            towards: destinationName,
            expectedArrival: departureTime,
            timeToStation: seconds,
            currentLocation: nil
        )
    }

    private static func departureSeconds(_ value: String?) -> Int? {
        guard let value = normalized(value) else { return nil }
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let minutes = Int(components[0]),
              let seconds = Int(components[1]),
              minutes >= 0,
              (0..<60).contains(seconds) else {
            return nil
        }
        return minutes * 60 + seconds
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct MirroredDLRDepartureCluster {
    let prediction: TfLArrivalPrediction
    var platforms: Set<Int>
}

private struct MirroredDLRDepartureKey: Hashable {
    let sourceID: String
    let vehicleID: String?
    let direction: String?
    let destinationID: String?
    let destinationName: String?
    let towards: String?
    let platformPair: MirroredDLRPlatform.Pair

    init(
        prediction: TfLArrivalPrediction,
        platformPair: MirroredDLRPlatform.Pair
    ) {
        sourceID = prediction.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        vehicleID = Self.normalized(prediction.vehicleId)
        direction = Self.normalized(prediction.direction)
        destinationID = Self.normalized(prediction.destinationNaptanId)
        destinationName = Self.normalized(prediction.destinationName)
        towards = Self.normalized(prediction.towards)
        self.platformPair = platformPair
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}

private struct MirroredDLRPlatform {
    enum Pair: Hashable {
        case oneAndTwo
        case threeAndFour
        case fiveAndSix
    }

    let number: Int
    let pair: Pair

    init?(prediction: TfLArrivalPrediction) {
        guard prediction.lineId == TubeLineID.dlr.rawValue,
              prediction.naptanId?.uppercased() == "940GZZDLCAN" else {
            return nil
        }

        switch prediction.platformName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "platform 1":
            number = 1
            pair = .oneAndTwo
        case "platform 2":
            number = 2
            pair = .oneAndTwo
        case "platform 3":
            number = 3
            pair = .threeAndFour
        case "platform 4":
            number = 4
            pair = .threeAndFour
        case "platform 5":
            number = 5
            pair = .fiveAndSix
        case "platform 6":
            number = 6
            pair = .fiveAndSix
        default:
            return nil
        }
    }
}

private extension TfLArrivalPrediction {
    func replacingDestination(_ destination: DepartureDestination?) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: id,
            vehicleId: vehicleId,
            lineId: lineId,
            stationName: stationName,
            naptanId: naptanId,
            platformName: platformName,
            direction: direction,
            destinationName: destination?.name,
            destinationNaptanId: destination?.id,
            towards: destination?.name,
            expectedArrival: expectedArrival,
            timeToStation: timeToStation,
            currentLocation: currentLocation
        )
    }

    func replacingPlatformName(_ platformName: String?) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: id,
            vehicleId: vehicleId,
            lineId: lineId,
            stationName: stationName,
            naptanId: naptanId,
            platformName: platformName,
            direction: direction,
            destinationName: destinationName,
            destinationNaptanId: destinationNaptanId,
            towards: towards,
            expectedArrival: expectedArrival,
            timeToStation: timeToStation,
            currentLocation: currentLocation
        )
    }
}
