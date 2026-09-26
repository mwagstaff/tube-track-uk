import Foundation

/// Turns live predictions into the four rows a Live Activity carries.
///
/// The server computes the same projection when it pushes an update, so this
/// is the reference implementation: grouping, direction matching and ordering
/// all have to agree, or a pushed board will disagree with the one the app
/// produced a second earlier.
public enum DepartureActivityBoard {
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
                    expectedAt: expected
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
