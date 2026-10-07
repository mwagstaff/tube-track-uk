import Foundation

/// Turns live predictions into the four rows a Live Activity carries.
///
/// The server computes the same projection when it pushes an update, so this
/// is the reference implementation: grouping, direction matching and ordering
/// all have to agree, or a pushed board will disagree with the one the app
/// produced a second earlier.
public enum DepartureActivityBoard {
    public static func nationalRailContentState(
        from arrivals: [TfLArrivalPrediction], operatorID: String,
        updatedAt: Date, sequence: Int, direction: DepartureDirectionFilter = .any
    ) -> DepartureActivityAttributes.ContentState {
        let rows = arrivals.filter { $0.isNationalRailOperator && $0.lineId == operatorID
            && direction.matches(StationDepartureMetadata.directionLabel(for: $0)) }
            .sorted {
                let left = $0.expectedArrival ?? $0.scheduledDeparture ?? .distantFuture
                let right = $1.expectedArrival ?? $1.scheduledDeparture ?? .distantFuture
                return left == right ? $0.id < $1.id : left < right
            }
        var seen = Set<String>()
        let departures = rows.compactMap { arrival -> DepartureActivityAttributes.ContentState.Departure? in
            guard let time = arrival.expectedArrival ?? arrival.scheduledDeparture,
                  seen.insert(arrival.id).inserted else { return nil }
            return .init(id: arrival.id, destination: StationDepartureMetadata.destinationLabel(for: arrival),
                platform: StationDepartureMetadata.compactPlatformLabel(for: arrival), expectedAt: time,
                status: arrival.serviceStatus, hasExpectedTime: arrival.expectedArrival != nil)
        }
        let condition: LineServiceCondition = rows.contains(where: \.isCancelled)
            ? .minorDisruption("Cancellations")
            : rows.contains { $0.serviceStatus == .delayed } ? .minorDisruption("Delays")
            : rows.isEmpty || rows.contains { $0.expectedArrival == nil }
                ? .updating : .good("Departures on time")
        return .init(departures: departures, updatedAt: updatedAt, conditionRank: condition.severityRank,
            conditionHeadline: condition.headline, sequence: sequence)
    }

    public static func contentState(
        from arrivals: [TfLArrivalPrediction],
        lineID: TubeLineID,
        direction: DepartureDirectionFilter,
        condition: LineServiceCondition?,
        updatedAt: Date,
        sequence: Int
    ) -> DepartureActivityAttributes.ContentState {
        let groups = StationDepartureGroup.groups(from: arrivals, for: lineID).matching(direction)
        let departures = groups
            .flatMap(\.arrivals)
            .sorted { left, right in
                let leftTime = left.expectedArrival ?? .distantFuture
                let rightTime = right.expectedArrival ?? .distantFuture
                if leftTime != rightTime { return leftTime < rightTime }
                return left.id < right.id
            }
            .prefix(DepartureActivityAttributes.ContentState.maximumDepartures)
            .compactMap { arrival -> DepartureActivityAttributes.ContentState.Departure? in
                guard let expected = arrival.expectedArrival else { return nil }
                return .init(
                    id: arrival.vehicleId ?? arrival.id,
                    destination: StationDepartureMetadata.destinationLabel(for: arrival),
                    platform: StationDepartureMetadata.compactPlatformLabel(for: arrival),
                    expectedAt: expected,
                    status: arrival.serviceStatus
                )
            }

        return DepartureActivityAttributes.ContentState(
            departures: Array(departures),
            updatedAt: updatedAt,
            conditionRank: condition?.severityRank ?? LineServiceCondition.updating.severityRank,
            conditionHeadline: condition?.hasIssue == true ? condition?.headline : nil,
            sequence: sequence
        )
    }
}
