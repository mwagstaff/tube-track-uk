import Foundation

public struct StationDepartureGroup: Identifiable, Sendable {
    public let lineID: TubeLineID
    public let direction: String
    public let arrivals: [TfLArrivalPrediction]

    public init(
        lineID: TubeLineID,
        direction: String,
        arrivals: [TfLArrivalPrediction]
    ) {
        self.lineID = lineID
        self.direction = direction
        self.arrivals = arrivals
    }

    public var id: String { "\(lineID.rawValue):\(direction.lowercased())" }
    public var collapsedArrivals: ArraySlice<TfLArrivalPrediction> { arrivals.prefix(3) }

    public static func groups(
        from arrivals: [TfLArrivalPrediction],
        for selectedLineID: TubeLineID? = nil
    ) -> [Self] {
        let validArrivals = arrivals.compactMap { arrival -> (Key, TfLArrivalPrediction)? in
            guard let lineID = TubeLineID(rawValue: arrival.lineId),
                  selectedLineID == nil || lineID == selectedLineID else {
                return nil
            }
            let direction = StationDepartureMetadata.directionLabel(for: arrival)
            return (Key(lineID: lineID, direction: direction), arrival)
        }

        return Dictionary(grouping: validArrivals, by: \.0)
            .map { key, values in
                StationDepartureGroup(
                    lineID: key.lineID,
                    direction: key.direction,
                    arrivals: values.map(\.1).sorted(by: arrivesSooner)
                )
            }
            .sorted { left, right in
                if left.lineID.displayName != right.lineID.displayName {
                    return left.lineID.displayName < right.lineID.displayName
                }
                let leftRank = directionRank(left.direction)
                let rightRank = directionRank(right.direction)
                if leftRank != rightRank { return leftRank < rightRank }
                return left.direction < right.direction
            }
    }

    private static func arrivesSooner(
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
        if left.destinationName != right.destinationName {
            return (left.destinationName ?? "") < (right.destinationName ?? "")
        }
        if left.platformName != right.platformName {
            return (left.platformName ?? "") < (right.platformName ?? "")
        }
        return left.id < right.id
    }

    private static func directionRank(_ direction: String) -> Int {
        switch direction.lowercased() {
        case "northbound": 0
        case "southbound": 1
        case "eastbound": 2
        case "westbound": 3
        case "inbound": 4
        case "outbound": 5
        case "all directions": 6
        default: 7
        }
    }

    private struct Key: Hashable {
        let lineID: TubeLineID
        let direction: String
    }
}
