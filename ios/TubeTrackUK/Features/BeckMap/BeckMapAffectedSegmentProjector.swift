import Foundation

/// Projects graph-backed disruption state onto an authored Beck document.
///
/// The semantic graph remains the source for live status resolution. When its
/// affected segments form one unambiguous station-to-station chain, this type
/// asks the authored route catalog for the equivalent artwork segments. It
/// deliberately falls back to exact shared IDs whenever the authored routes
/// are ambiguous or incomplete.
struct BeckMapAffectedSegmentProjector: Sendable {
    let document: BeckMapDocument
    let graph: TubeGraph

    func projectedSegmentIDs(for disruption: ResolvedDisruption) -> Set<String> {
        projectedSegmentIDs(
            for: disruption.affectedSegmentIDs,
            on: disruption.lineID,
            confidence: disruption.confidence
        )
    }

    func projectedSegmentIDs(
        for affectedSegmentIDs: Set<String>,
        on lineID: TubeLineID,
        confidence: ResolutionConfidence
    ) -> Set<String> {
        let authoredSegments = document.segments.filter { $0.lineID == lineID }
        let authoredSegmentIDs = Set(authoredSegments.map(\.id))
        let exactMatches = affectedSegmentIDs.intersection(authoredSegmentIDs)

        if confidence == .lineOnly {
            return authoredSegmentIDs
        }

        let graphSegmentsByID = Dictionary(uniqueKeysWithValues: graph.segments(for: lineID).map { ($0.id, $0) })
        let affectedGraphSegments = affectedSegmentIDs.compactMap { graphSegmentsByID[$0] }
        guard let endpoints = simpleChainEndpoints(for: affectedGraphSegments) else {
            return exactMatches
        }

        do {
            let projected = try BeckMapRouteResolver(document: document).segmentIDs(
                on: lineID,
                from: endpoints.start,
                to: endpoints.end
            )
            let authoredOnlyMatches = exactMatches.filter { graphSegmentsByID[$0] == nil }
            return projected.union(authoredOnlyMatches)
        } catch BeckMapRouteResolutionError.ambiguousRoute {
            return exactMatches
        } catch {
            return exactMatches
        }
    }

    private func simpleChainEndpoints(
        for segments: [TubeSegment]
    ) -> (start: String, end: String)? {
        guard !segments.isEmpty else { return nil }

        var adjacency: [String: Set<String>] = [:]
        for segment in segments {
            guard segment.fromStationID != segment.toStationID else { return nil }
            adjacency[segment.fromStationID, default: []].insert(segment.toStationID)
            adjacency[segment.toStationID, default: []].insert(segment.fromStationID)
        }

        guard adjacency.values.allSatisfy({ $0.count <= 2 }) else { return nil }
        let endpoints = adjacency
            .filter { $0.value.count == 1 }
            .map(\.key)
            .sorted()
        guard endpoints.count == 2 else { return nil }

        var visited: Set<String> = []
        var pending = [endpoints[0]]
        while let stationID = pending.popLast() {
            guard visited.insert(stationID).inserted else { continue }
            pending.append(contentsOf: adjacency[stationID, default: []].subtracting(visited))
        }
        guard visited.count == adjacency.count else { return nil }

        return (endpoints[0], endpoints[1])
    }
}
