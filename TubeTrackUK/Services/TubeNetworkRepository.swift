import Foundation

struct TubeNetworkRepository: Sendable {
    let graph: TubeGraph
    private let segmentsByConnection: [SegmentConnection: TubeSegment]

    init(graph: TubeGraph) {
        self.graph = graph
        self.segmentsByConnection = graph.segments.reduce(into: [:]) { result, segment in
            let connection = SegmentConnection(
                lineID: segment.lineID,
                firstStationID: segment.fromStationID,
                secondStationID: segment.toStationID
            )
            // Match the previous linear lookup's first-segment-wins behavior if
            // malformed source data ever contains the same connection twice.
            if result[connection] == nil {
                result[connection] = segment
            }
        }
    }

    func station(named rawName: String, on lineID: TubeLineID? = nil) -> TubeStation? {
        let normalized = normalize(rawName)
        return graph.stations
            .filter { lineID == nil || $0.lineIDs.contains(lineID!) }
            .sorted { $0.name.count > $1.name.count }
            .first { station in
                station.searchAliases.contains { normalize($0) == normalized }
                    || normalize(station.name) == normalized
                    || normalized.hasPrefix(normalize(station.name))
            }
    }

    func shortestSegmentPath(from startID: String, to endID: String, on lineID: TubeLineID) -> [TubeSegment]? {
        guard startID != endID else { return [] }
        let candidates = graph.segments.filter { $0.lineID == lineID }
        var adjacency: [String: [(stationID: String, segment: TubeSegment)]] = [:]
        for segment in candidates {
            adjacency[segment.fromStationID, default: []].append((segment.toStationID, segment))
            adjacency[segment.toStationID, default: []].append((segment.fromStationID, segment))
        }

        var queue = [startID]
        var visited: Set<String> = [startID]
        var previous: [String: (stationID: String, segment: TubeSegment)] = [:]
        var index = 0

        while index < queue.count {
            let current = queue[index]
            index += 1
            for edge in adjacency[current, default: []] where !visited.contains(edge.stationID) {
                visited.insert(edge.stationID)
                previous[edge.stationID] = (current, edge.segment)
                if edge.stationID == endID {
                    var path: [TubeSegment] = []
                    var cursor = endID
                    while cursor != startID, let step = previous[cursor] {
                        path.append(step.segment)
                        cursor = step.stationID
                    }
                    return path.reversed()
                }
                queue.append(edge.stationID)
            }
        }
        return nil
    }

    /// Resolves a section along TfL's ordered route variants. This matters for
    /// one-way networks such as the central Croydon tram loop, where an
    /// undirected shortest path can select the geographically shorter but
    /// operationally impossible side of the loop.
    func orderedSegmentPath(from startID: String, to endID: String, on lineID: TubeLineID) -> [TubeSegment]? {
        guard startID != endID, let line = graph.line(lineID) else { return startID == endID ? [] : nil }

        let candidates = line.routes.compactMap { route -> [TubeSegment]? in
            guard let startIndex = route.firstIndex(of: startID),
                  let endIndex = route.firstIndex(of: endID),
                  startIndex < endIndex else {
                return nil
            }

            let stationIDs = Array(route[startIndex ... endIndex])
            let segments = zip(stationIDs, stationIDs.dropFirst()).compactMap {
                segment(between: $0.0, and: $0.1, on: lineID)
            }
            return segments.count == stationIDs.count - 1 ? segments : nil
        }

        return candidates.min { left, right in
            if left.count != right.count { return left.count < right.count }
            return left.map(\.id).lexicographicallyPrecedes(right.map(\.id))
        }
    }

    func segment(between firstID: String, and secondID: String, on lineID: TubeLineID) -> TubeSegment? {
        segmentsByConnection[
            SegmentConnection(
                lineID: lineID,
                firstStationID: firstID,
                secondStationID: secondID
            )
        ]
    }

    func neighboringStation(
        for stationID: String,
        on lineID: TubeLineID,
        direction: String?,
        destinationStationID: String? = nil
    ) -> String? {
        guard let line = graph.line(lineID) else { return nil }
        let isInbound = direction?.lowercased() == "inbound"
        let routes = line.routes.sorted { left, right in
            let leftMatches = destinationStationID.map(left.contains) ?? false
            let rightMatches = destinationStationID.map(right.contains) ?? false
            return leftMatches && !rightMatches
        }
        for route in routes {
            guard let index = route.firstIndex(of: stationID) else { continue }
            if let destinationStationID,
               let destinationIndex = route.firstIndex(of: destinationStationID),
               destinationIndex != index {
                if destinationIndex > index, index > 0 { return route[index - 1] }
                if destinationIndex < index, index + 1 < route.count { return route[index + 1] }
            }
            if isInbound, index + 1 < route.count { return route[index + 1] }
            if !isInbound, index > 0 { return route[index - 1] }
            if index > 0 { return route[index - 1] }
            if index + 1 < route.count { return route[index + 1] }
        }
        return nil
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " underground station", with: "")
            .replacingOccurrences(of: " tram stop", with: "")
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SegmentConnection: Hashable, Sendable {
    let lineID: TubeLineID
    let firstStationID: String
    let secondStationID: String

    init(lineID: TubeLineID, firstStationID: String, secondStationID: String) {
        self.lineID = lineID
        if firstStationID <= secondStationID {
            self.firstStationID = firstStationID
            self.secondStationID = secondStationID
        } else {
            self.firstStationID = secondStationID
            self.secondStationID = firstStationID
        }
    }
}
