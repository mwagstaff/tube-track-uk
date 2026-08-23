import CoreLocation
import Foundation

struct NearbyStation: Identifiable, Sendable {
    let station: TubeStation
    let distance: CLLocationDistance

    var id: String { station.id }
}

enum NearbyStationFinder {
    static func stationsByDistance(
        to location: CLLocation,
        in stations: [TubeStation]
    ) -> [NearbyStation] {
        Dictionary(grouping: stations) { $0.hubID ?? $0.id }
            .values
            .compactMap { colocatedStations -> NearbyStation? in
                colocatedStations
                    .map { station in
                        NearbyStation(
                            station: station,
                            distance: location.distance(from: CLLocation(
                                latitude: station.latitude,
                                longitude: station.longitude
                            ))
                        )
                    }
                    .min { left, right in
                        if left.distance != right.distance {
                            return left.distance < right.distance
                        }
                        return left.station.id < right.station.id
                    }
            }
            .sorted { left, right in
                if left.distance != right.distance {
                    return left.distance < right.distance
                }
                if left.station.name != right.station.name {
                    return left.station.name < right.station.name
                }
                return left.station.id < right.station.id
            }
    }

    static func nearestStations(
        to location: CLLocation,
        in stations: [TubeStation],
        limit: Int = 3
    ) -> [NearbyStation] {
        guard limit > 0 else { return [] }
        return stationsByDistance(to: location, in: stations)
            .prefix(limit)
            .map { $0 }
    }
}

enum NearbyDistanceFormatter {
    static func string(from distance: CLLocationDistance) -> String {
        if distance < 1_000 {
            return "\(max(1, Int(distance.rounded()))) m"
        }
        return String(format: "%.1f km", distance / 1_000)
    }
}

enum LineServiceCondition: Equatable, Sendable {
    case good(String)
    case minorDisruption(String)
    case majorDisruption(String)
    case updating

    var accessibilityDescription: String {
        switch self {
        case let .good(description),
             let .minorDisruption(description),
             let .majorDisruption(description):
            description
        case .updating:
            "Status updating"
        }
    }

    static func condition(for status: TfLLineStatus?) -> Self {
        guard let entries = status?.lineStatuses, !entries.isEmpty else { return .updating }

        if let entry = entries.first(where: {
            $0.isActionableIssue && $0.statusSeverity != 9
        }) {
            return .majorDisruption(entry.statusSeverityDescription)
        }
        if let entry = entries.first(where: { $0.isActionableIssue }) {
            return .minorDisruption(entry.statusSeverityDescription)
        }
        let description = entries.first?.statusSeverityDescription ?? "Good service"
        return .good(description)
    }
}

struct NearbyDepartureGroup: Identifiable, Sendable {
    let lineID: TubeLineID
    let direction: String
    let arrivals: [TfLArrivalPrediction]

    var id: String { "\(lineID.rawValue):\(direction.lowercased())" }

    static func groups(from arrivals: [TfLArrivalPrediction]) -> [Self] {
        let validArrivals = arrivals.compactMap { arrival -> (Key, TfLArrivalPrediction)? in
            guard let lineID = TubeLineID(rawValue: arrival.lineId) else { return nil }
            let direction = directionLabel(for: arrival)
            return (Key(lineID: lineID, direction: direction), arrival)
        }

        return Dictionary(grouping: validArrivals, by: \.0)
            .map { key, values in
                NearbyDepartureGroup(
                    lineID: key.lineID,
                    direction: key.direction,
                    arrivals: values.map(\.1).sorted(by: arrivesSooner)
                )
            }
            .sorted { left, right in
                if left.lineID.displayName != right.lineID.displayName {
                    return left.lineID.displayName < right.lineID.displayName
                }
                return left.direction < right.direction
            }
    }

    private static func directionLabel(for arrival: TfLArrivalPrediction) -> String {
        let cardinalDirections = ["northbound", "southbound", "eastbound", "westbound"]
        if let platformName = arrival.platformName?.lowercased(),
           let direction = cardinalDirections.first(where: { platformName.contains($0) }) {
            return direction.capitalized
        }
        if let direction = arrival.direction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direction.isEmpty {
            return direction.capitalized
        }
        return "All directions"
    }

    private static func arrivesSooner(
        _ left: TfLArrivalPrediction,
        _ right: TfLArrivalPrediction
    ) -> Bool {
        if left.timeToStation != right.timeToStation {
            return (left.timeToStation ?? .max) < (right.timeToStation ?? .max)
        }
        return left.id < right.id
    }

    private struct Key: Hashable {
        let lineID: TubeLineID
        let direction: String
    }
}
