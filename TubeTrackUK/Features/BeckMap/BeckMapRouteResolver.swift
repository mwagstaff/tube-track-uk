import Foundation

enum BeckMapRouteResolutionError: Error, Equatable, Sendable {
    case unknownRoute(String)
    case stationsNotConnected(lineID: TubeLineID, fromStationID: String, toStationID: String)
    case ambiguousRoute(lineID: TubeLineID, fromStationID: String, toStationID: String)
}

/// Resolves a named/identified station range to immutable artwork segment IDs.
///
/// Geometry is never inspected. Branch and loop ambiguity is surfaced to the
/// caller so product code can ask for an explicit route rather than guessing.
struct BeckMapRouteResolver: Sendable {
    let document: BeckMapDocument

    func segmentIDs(
        on lineID: TubeLineID,
        from fromStationID: String,
        to toStationID: String,
        routeID: String? = nil
    ) throws -> Set<String> {
        let candidateRoutes: [BeckMapRouteRecord]
        if let routeID {
            guard let route = document.routes.first(where: { $0.id == routeID && $0.lineID == lineID }) else {
                throw BeckMapRouteResolutionError.unknownRoute(routeID)
            }
            candidateRoutes = [route]
        } else {
            candidateRoutes = document.routes.filter { $0.lineID == lineID }
        }

        let candidates = candidateRoutes.compactMap { route -> Set<String>? in
            guard let fromIndex = route.stationIDs.firstIndex(of: fromStationID),
                  let toIndex = route.stationIDs.firstIndex(of: toStationID),
                  fromIndex != toIndex else { return nil }

            let lower = min(fromIndex, toIndex)
            let upper = max(fromIndex, toIndex)
            guard route.segmentIDs.indices.contains(lower), upper <= route.segmentIDs.count else { return nil }
            return Set(route.segmentIDs[lower..<upper])
        }

        let distinctCandidates = Array(Set(candidates))
        guard let onlyCandidate = distinctCandidates.first else {
            throw BeckMapRouteResolutionError.stationsNotConnected(
                lineID: lineID,
                fromStationID: fromStationID,
                toStationID: toStationID
            )
        }
        guard distinctCandidates.count == 1 else {
            throw BeckMapRouteResolutionError.ambiguousRoute(
                lineID: lineID,
                fromStationID: fromStationID,
                toStationID: toStationID
            )
        }
        return onlyCandidate
    }

}
