import Foundation

/// The same request is used by in-app boards and frozen into a Live Activity.
public struct DepartureBoardRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: String { [originID, destinationIDs.joined(separator: ","), lineIDs.joined(separator: ","), direction ?? ""].joined(separator: "|") }
    public var originID: String
    public var destinationIDs: [String]
    public var lineIDs: [String]
    public var direction: String?

    public init(originID: String, destinationIDs: [String] = [], lineIDs: [String] = [], direction: String? = nil) {
        self.direction = direction
        self.originID = originID
        self.destinationIDs = Array(Set(destinationIDs.filter { $0 != originID })).sorted()
        self.lineIDs = Array(Set(lineIDs)).sorted()
    }
}

public struct DepartureStop: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let stopIDs: [String]
    public let lineIDs: [String]
    public let railCodes: [String]
    public var mode: String = "rail"

    public init(id: String, name: String, latitude: Double, longitude: Double,
                stopIDs: [String], lineIDs: [String], railCodes: [String] = [], mode: String = "rail") {
        self.id = id; self.name = name; self.latitude = latitude; self.longitude = longitude
        self.stopIDs = stopIDs; self.lineIDs = lineIDs; self.railCodes = railCodes; self.mode = mode
    }

    public static let bundled: [Self] = {
        guard let url = Bundle.module.url(forResource: "DepartureStops", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let stops = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return stops
    }()
}

public struct DepartureFavourite: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var outbound: DepartureBoardRequest
    /// Stable endpoint IDs identify return legs for future scheduling.
    public var returnLineIDs: [String]
    public var manualOriginID: String?
    public var lastOriginID: String
    /// Optional for compatibility with favourites saved before direction filters.
    public var directionFilters: [DepartureBoardRequest]?

    public init(id: UUID = UUID(), name: String = "", outbound: DepartureBoardRequest) {
        self.id = id; self.name = name; self.outbound = outbound
        returnLineIDs = outbound.lineIDs; lastOriginID = outbound.originID
    }

    public var endpointIDs: [String] { [outbound.originID] + outbound.destinationIDs }

    public func request(from originID: String) -> DepartureBoardRequest {
        guard originID != outbound.originID, outbound.destinationIDs.contains(originID) else { return outbound }
        return .init(originID: originID, destinationIDs: [outbound.originID], lineIDs: returnLineIDs)
    }

    public func request(from originID: String, serviceID: String?, direction: String) -> DepartureBoardRequest {
        var request = request(from: originID)
        if let serviceID { request.lineIDs = [serviceID] }
        request.direction = direction
        return directionFilters?.first {
            $0.originID == originID && $0.lineIDs == request.lineIDs && $0.direction == direction
        } ?? request
    }

    public mutating func setDirectionFilter(_ request: DepartureBoardRequest) {
        var filters = directionFilters ?? []
        filters.removeAll {
            $0.originID == request.originID && $0.lineIDs == request.lineIDs && $0.direction == request.direction
        }
        filters.append(request)
        directionFilters = filters
    }

    /// Distances are metres. Require a meaningful improvement before switching.
    public func resolvedOrigin(distances: [String: Double], switchMargin: Double = 150) -> String {
        if let manualOriginID, endpointIDs.contains(manualOriginID) { return manualOriginID }
        let previous = endpointIDs.contains(lastOriginID) ? lastOriginID : outbound.originID
        guard let nearest = endpointIDs.filter({ distances[$0] != nil }).min(by: {
            let lhs = distances[$0]!, rhs = distances[$1]!
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }) else { return previous }
        guard let previousDistance = distances[previous] else { return nearest }
        return distances[nearest]! + switchMargin < previousDistance ? nearest : previous
    }

    public mutating func reverse(distances: [String: Double]) {
        let current = resolvedOrigin(distances: distances)
        if current != outbound.originID {
            manualOriginID = outbound.originID
        } else {
            manualOriginID = outbound.destinationIDs.min {
                let lhs = distances[$0] ?? .infinity, rhs = distances[$1] ?? .infinity
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
        }
        lastOriginID = manualOriginID ?? current
    }
}

public struct CustomDepartureBoard: Codable, Sendable {
    public let arrivals: [TfLArrivalPrediction]
    public let updatedAt: Date
    public let unavailableSources: Int
    public let unverifiedCount: Int
    public let stale: Bool
    public let conditionRank: Int?
    public let conditionHeadline: String?

    /// Freeze the last snapshot during interruptions rather than aging every row off screen.
    public func displayReferenceDate(at now: Date, interrupted: Bool = false) -> Date {
        interrupted || stale || unavailableSources > 0 || now.timeIntervalSince(updatedAt) > 90
            ? updatedAt : now
    }

    public func retainingLastAvailable(_ previous: Self?) -> Self {
        guard arrivals.isEmpty, stale || unavailableSources > 0,
              let previous, !previous.arrivals.isEmpty else { return self }
        return .init(arrivals: previous.arrivals, updatedAt: previous.updatedAt,
                     unavailableSources: unavailableSources, unverifiedCount: previous.unverifiedCount,
                     stale: true, conditionRank: conditionRank, conditionHeadline: conditionHeadline)
    }

    public func upcoming(at now: Date) -> [TfLArrivalPrediction] {
        arrivals.filter {
            ($0.expectedArrival ?? $0.scheduledDeparture ?? .distantPast) > now.addingTimeInterval(-15)
                || ($0.serviceStatus == .delayed && $0.expectedArrival == nil)
        }
    }

    public func selecting(_ rows: [TfLArrivalPrediction]) -> Self {
        .init(arrivals: rows, updatedAt: updatedAt, unavailableSources: unavailableSources,
              unverifiedCount: unverifiedCount, stale: stale, conditionRank: conditionRank,
              conditionHeadline: conditionHeadline)
    }

    public func activityState(sequence: Int) -> DepartureActivityAttributes.ContentState {
        .init(departures: arrivals.compactMap { arrival in
            guard let date = arrival.expectedArrival ?? arrival.scheduledDeparture else { return nil }
            return .init(id: arrival.id, destination: StationDepartureMetadata.destinationLabel(for: arrival),
                         platform: StationDepartureMetadata.compactPlatformLabel(for: arrival), expectedAt: date,
                         status: arrival.serviceStatus, hasExpectedTime: arrival.expectedArrival != nil, lineIDRaw: arrival.lineId,
                         direction: DepartureDirectionFilter.resolve(label: StationDepartureMetadata.directionLabel(for: arrival)))
        }, updatedAt: updatedAt, conditionRank: unavailableSources > 0 || stale ? 3 : conditionRank ?? 4,
              conditionHeadline: unavailableSources > 0 ? "Some services unavailable" : conditionHeadline, sequence: sequence)
    }
}

/// Direction sections combine operators while keeping opposing services separate.
public struct DepartureBoardDirectionGroup: Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let arrivals: [TfLArrivalPrediction]

    public init(title: String, arrivals: [TfLArrivalPrediction]) {
        self.title = title
        self.arrivals = arrivals
    }

    public static func groups(from arrivals: [TfLArrivalPrediction], origin: DepartureStop?,
                              stops: [DepartureStop] = DepartureStop.bundled) -> [Self] {
        let grouped = Dictionary(grouping: arrivals) { arrival in
            let reported = StationDepartureMetadata.directionLabel(for: arrival)
            // DLR predictions often supply only a platform number or inbound/outbound.
            // Use a known terminus to name these directions, as on railway boards.
            if arrival.lineId == TubeLineID.dlr.rawValue,
               !["Northbound", "Southbound", "Eastbound", "Westbound"].contains(reported),
               let origin, let destination = destination(for: arrival, stops: stops),
               let direction = bearing(from: origin, to: destination) {
                return direction
            }
            if reported != "All directions" { return reported }
            if let platform = StationDepartureMetadata.platformLabel(for: arrival) {
                return platform.lowercased().contains("platform") ? platform : "Platform \(platform)"
            }
            return "Other departures"
        }
        let order = ["Northbound", "Southbound", "Eastbound", "Westbound", "Inbound", "Outbound"]
        return grouped.map { Self(title: $0.key, arrivals: $0.value.sorted {
            let lhs = $0.expectedArrival ?? $0.scheduledDeparture ?? .distantFuture
            let rhs = $1.expectedArrival ?? $1.scheduledDeparture ?? .distantFuture
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }) }.sorted {
            let lhs = order.firstIndex(of: $0.title) ?? order.count
            let rhs = order.firstIndex(of: $1.title) ?? order.count
            return lhs == rhs ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : lhs < rhs
        }
    }

    private static func destination(for arrival: TfLArrivalPrediction, stops: [DepartureStop]) -> DepartureStop? {
        if let id = arrival.destinationNaptanId,
           let stop = stops.first(where: { $0.id == id || $0.stopIDs.contains(id) || $0.railCodes.contains(id) }) {
            return stop
        }
        let name = StationDepartureMetadata.destinationLabel(for: arrival)
        let matches = stops.filter { $0.lineIDs.contains(arrival.lineId) && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches.first : nil
    }

    private static func bearing(from start: DepartureStop, to end: DepartureStop) -> String? {
        guard start.latitude != end.latitude || start.longitude != end.longitude else { return nil }
        let latitude = start.latitude * .pi / 180
        let destinationLatitude = end.latitude * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let east = sin(longitudeDelta) * cos(destinationLatitude)
        let north = cos(latitude) * sin(destinationLatitude)
            - sin(latitude) * cos(destinationLatitude) * cos(longitudeDelta)
        let degrees = (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        switch degrees {
        case 67.5..<112.5: return "Eastbound"
        case 112.5..<247.5: return "Southbound"
        case 247.5..<292.5: return "Westbound"
        default: return "Northbound"
        }
    }
}
