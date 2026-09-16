import Foundation

struct JourneyMapHighlight: Sendable {
    var segmentIDs: Set<String> = []
    var stationIDs: Set<String> = []
    var unmappedLegCount = 0
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
