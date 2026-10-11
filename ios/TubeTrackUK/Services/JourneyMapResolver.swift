import Foundation

struct JourneyMapHighlight: Sendable {
    var segmentIDs: Set<String> = []
    var stationIDs: Set<String> = []
    var unmappedLegCount = 0
}

/// Only draw a unique operator/line path through the supplied calling points.
/// Express trains may skip mapped stops; ambiguous branches remain undrawn.
struct JourneyGeographicGeometry: Sendable {
    struct Route: Identifiable, Sendable {
        let id: String
        let points: [GeographicPoint]
    }
    var routes: [Route] = []
    var stations: [TubeStation] = []
    var unmappedLegCount = 0

    private struct Edge {
        let id: String
        let from: String
        let to: String
        let points: [GeographicPoint]
    }

    static func resolve(_ journey: PlannedJourney, graph: TubeGraph, rail: NationalRailMap) -> Self {
        var result = Self()
        func canonical(_ id: String) -> String { graph.stationsByID[id]?.hubID ?? id }
        func station(_ id: String) -> TubeStation? {
            graph.stationsByID[id] ?? graph.stations.first { $0.hubID == id }
        }
        var seenStations = Set<String>()
        var seenRoutes = Set<String>()
        for leg in journey.legs {
            for point in [leg.from, leg.to] {
                if let stop = station(point.id), seenStations.insert(canonical(stop.id)).inserted {
                    result.stations.append(stop)
                }
            }
            guard !["walking", "transfer", "replacement-bus"].contains(leg.mode) else {
                if leg.mode != "transfer" { result.unmappedLegCount += 1 }
                continue
            }
            let edges: [Edge]
            if leg.mode == "national-rail" {
                let operators = Set(leg.lines.map(\.id))
                edges = rail.routes.filter { operators.contains($0.operatorID) }.map {
                    Edge(id: $0.id, from: canonical($0.fromStationID), to: canonical($0.toStationID), points: $0.geographicPoints)
                }
            } else {
                let lines = Set(leg.lines.compactMap(\.tubeLineID))
                edges = graph.segments.filter { lines.contains($0.lineID) }.map {
                    Edge(id: $0.id, from: canonical($0.fromStationID), to: canonical($0.toStationID), points: $0.geographicPoints)
                }
            }
            let ids = ([leg.from.id] + leg.stops.map(\.id) + [leg.to.id]).map(canonical)
            var checkpoints: [String] = []
            for id in ids where checkpoints.last != id { checkpoints.append(id) }
            var missing = checkpoints.count < 2
            for (from, to) in zip(checkpoints, checkpoints.dropFirst()) {
                guard let path = uniquePath(from: from, to: to, edges: edges) else { missing = true; continue }
                for edge in path where seenRoutes.insert(edge.id).inserted {
                    result.routes.append(Route(id: edge.id, points: edge.points))
                }
            }
            if missing { result.unmappedLegCount += 1 }
        }
        return result
    }

    private static func uniquePath(from: String, to: String, edges: [Edge]) -> [Edge]? {
        var neighbours: [String: [Edge]] = [:]
        for edge in edges where edge.from != edge.to {
            neighbours[edge.from, default: []].append(edge)
            neighbours[edge.to, default: []].append(edge)
        }
        var solutions: [[Edge]] = []
        var operations = 0
        var truncated = false
        func visit(_ current: String, _ visited: Set<String>, _ path: [Edge]) {
            operations += 1
            if operations > 5_000 || path.count > 48 { truncated = true; return }
            if current == to { solutions.append(path); return }
            guard solutions.count < 2 else { return }
            for edge in neighbours[current] ?? [] {
                let next = edge.from == current ? edge.to : edge.from
                guard !visited.contains(next) else { continue }
                visit(next, visited.union([next]), path + [edge])
                if solutions.count > 1 || truncated { return }
            }
        }
        visit(from, [from], [])
        return !truncated && solutions.count == 1 ? solutions[0] : nil
    }
}

/// Matches provider stops to the immutable network artwork. Ambiguous paths
/// remain unhighlighted; a shortest-path guess could show the wrong branch.
struct JourneyMapResolver {
    let graph: TubeGraph
    let document: BeckMapDocument

    func resolve(_ journey: PlannedJourney) -> JourneyMapHighlight {
        var highlight = JourneyMapHighlight()
        let resolver = BeckMapRouteResolver(document: document)
        for leg in journey.legs {
            for endpoint in [JourneyStation(id: leg.from.id, name: leg.from.name), JourneyStation(id: leg.to.id, name: leg.to.name)] {
                highlight.stationIDs.formUnion(stationIDs(for: endpoint))
            }
            guard leg.mode != "walking" else { continue }
            let points = [JourneyStation(id: leg.from.id, name: leg.from.name)] + leg.stops
                + [JourneyStation(id: leg.to.id, name: leg.to.name)]
            let lines = Set(leg.lines.compactMap(\.tubeLineID))
            var candidates: Set<Set<String>> = []
            let checkpoints = points.map { stationIDs(for: $0) }
            for line in lines {
                // Graph routes span the entire service, whereas some artwork
                // route records are split into separately authored sections.
                for route in graph.line(line)?.routes ?? [] {
                    for ordered in [route, Array(route.reversed())] {
                        for start in ordered.indices where checkpoints.first?.contains(ordered[start]) == true {
                            for end in ordered.indices where end > start && checkpoints.last?.contains(ordered[end]) == true {
                                let section = Array(ordered[start...end])
                                var cursor = 0
                                let followsStops = checkpoints.allSatisfy { checkpoint in
                                    guard let next = section.indices.dropFirst(cursor).first(where: { checkpoint.contains(section[$0]) }) else { return false }
                                    cursor = next
                                    return true
                                }
                                guard followsStops else { continue }
                                var segments: Set<String> = []
                                var complete = true
                                for (from, to) in zip(section, section.dropFirst()) {
                                    let matches = document.segments.filter {
                                        $0.lineID == line && (($0.fromStationID == from && $0.toStationID == to)
                                            || ($0.fromStationID == to && $0.toStationID == from))
                                    }
                                    if !matches.isEmpty {
                                        segments.formUnion(matches.map(\.id))
                                    } else if let resolved = try? resolver.segmentIDs(on: line, from: from, to: to) {
                                        segments.formUnion(resolved)
                                    } else {
                                        complete = false
                                        break
                                    }
                                }
                                if complete { candidates.insert(segments) }
                            }
                        }
                    }
                }
            }
            if candidates.count == 1, let segments = candidates.first {
                highlight.segmentIDs.formUnion(segments)
            } else {
                highlight.unmappedLegCount += 1
            }
        }
        let visibleStations = Set(document.stationMarkers.map(\.stationID))
        highlight.stationIDs.formIntersection(visibleStations)
        return highlight
    }

    private func stationIDs(for point: JourneyStation) -> Set<String> {
        var stations = graph.stations.filter { $0.id == point.id || $0.hubID == point.id }
        // TfL occasionally omits NaPTAN IDs (e.g. Liverpool Street on the
        // Elizabeth line). Only accept an exact normalized name at one hub.
        if stations.isEmpty, !point.name.isEmpty {
            let name = normalized(point.name)
            let matches = graph.stations.filter {
                ([$0.name] + $0.searchAliases).contains { normalized($0) == name }
            }
            if Set(matches.map { $0.hubID ?? $0.id }).count == 1 { stations = matches }
        }
        return Set([point.id] + stations.flatMap { graph.stations(inSamePlaceAs: $0).map(\.id) })
    }

    private func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .replacingOccurrences(of: #"\b(rail|underground|dlr|station)\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }
}
