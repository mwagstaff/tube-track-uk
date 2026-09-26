import Foundation
import TubeTrackCore

/// The card and Live Activity use the same eligibility and ordering rules.
enum RiverDepartureBoard {
    static func departures(in board: RiverBoardSnapshot, pierID: String, lineID: String? = nil,
                           at date: Date) -> [RiverPrediction] {
        guard date.timeIntervalSince(board.updatedAt) <= 90 else { return [] }
        return board.predictions.filter {
            $0.pierId == pierID && !$0.terminatesHere && $0.isCurrent(at: date)
                && (lineID == nil || $0.lineId == lineID)
        }.sorted {
            if $0.expectedArrival != $1.expectedArrival { return $0.expectedArrival < $1.expectedArrival }
            return $0.id < $1.id
        }
    }

    static func contentState(board: RiverBoardSnapshot, pierID: String, lineID: String,
                             statuses: [RiverLineStatus], sequence: Int, now: Date = .now)
        -> DepartureActivityAttributes.ContentState {
        let entries = statuses.first { $0.id == lineID }?.entries ?? []
        let issue = entries.first { $0.severity != 10 && $0.severity != 18 && $0.severity != 9 }
            ?? entries.first { $0.severity == 9 }
        return .init(
            departures: departures(in: board, pierID: pierID, lineID: lineID, at: now)
                .prefix(DepartureActivityAttributes.ContentState.maximumDepartures).map {
                    .init(id: $0.id, destination: $0.destinationName ?? "Destination unavailable",
                          platform: nil, expectedAt: $0.expectedArrival)
                },
            updatedAt: board.updatedAt,
            conditionRank: issue.map { $0.severity == 9 ? 1 : 0 } ?? (entries.isEmpty ? 3 : 4),
            conditionHeadline: issue?.description,
            sequence: sequence
        )
    }
}
