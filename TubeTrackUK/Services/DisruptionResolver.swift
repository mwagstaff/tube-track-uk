import Foundation

struct DisruptionResolver: Sendable {
    private let repository: TubeNetworkRepository

    init(repository: TubeNetworkRepository) {
        self.repository = repository
    }

    func resolve(_ lineStatus: TfLLineStatus) -> [ResolvedDisruption] {
        lineStatus.lineStatuses.compactMap { status in
            guard status.isActionableIssue else { return nil }
            return resolve(status, lineID: lineStatus.id)
        }
    }

    func resolve(_ status: TfLStatusEntry, lineID: TubeLineID) -> ResolvedDisruption {
        let reason = status.reason ?? status.disruption?.description ?? status.statusSeverityDescription
        let baseID = "\(lineID.rawValue):\(status.id):\(status.statusSeverity)"

        if let exact = exactStructuredResolution(status, lineID: lineID), !exact.segments.isEmpty {
            return ResolvedDisruption(
                id: baseID,
                lineID: lineID,
                title: status.statusSeverityDescription,
                reason: reason,
                severity: status.statusSeverity,
                affectedStationIDs: exact.stations,
                affectedSegmentIDs: exact.segments,
                confidence: .exact
            )
        }

        let mentionedStations = stationsMentioned(in: reason, lineID: lineID)
        if mentionedStations.count >= 2,
           let path = repository.shortestSegmentPath(
               from: mentionedStations[0].id,
               to: mentionedStations[1].id,
               on: lineID
           ),
           !path.isEmpty {
            var stationIDs = Set([mentionedStations[0].id, mentionedStations[1].id])
            path.forEach {
                stationIDs.insert($0.fromStationID)
                stationIDs.insert($0.toStationID)
            }
            return ResolvedDisruption(
                id: baseID,
                lineID: lineID,
                title: status.statusSeverityDescription,
                reason: reason,
                severity: status.statusSeverity,
                affectedStationIDs: stationIDs,
                affectedSegmentIDs: Set(path.map(\.id)),
                confidence: .inferred
            )
        }

        let segments = repository.graph.segments(for: lineID)
        return ResolvedDisruption(
            id: baseID,
            lineID: lineID,
            title: status.statusSeverityDescription,
            reason: reason,
            severity: status.statusSeverity,
            affectedStationIDs: Set(segments.flatMap { [$0.fromStationID, $0.toStationID] }),
            affectedSegmentIDs: Set(segments.map(\.id)),
            confidence: .lineOnly
        )
    }

    private func exactStructuredResolution(
        _ status: TfLStatusEntry,
        lineID: TubeLineID
    ) -> (stations: Set<String>, segments: Set<String>)? {
        let partialRoutes = status.disruption?.affectedRoutes?.filter { $0.isEntireRouteSection == false } ?? []
        guard !partialRoutes.isEmpty else { return nil }

        var stationIDs: Set<String> = []
        var segmentIDs: Set<String> = []
        for route in partialRoutes {
            let ids = route.routeSectionNaptanEntrySequence?.compactMap {
                $0.stopPoint?.naptanId ?? $0.stopPoint?.id
            } ?? []
            stationIDs.formUnion(ids)
            for pair in zip(ids, ids.dropFirst()) {
                if let segment = repository.segment(between: pair.0, and: pair.1, on: lineID) {
                    segmentIDs.insert(segment.id)
                }
            }
        }
        return (stationIDs, segmentIDs)
    }

    private func stationsMentioned(in reason: String, lineID: TubeLineID) -> [TubeStation] {
        let normalizedReason = normalize(reason)
        return repository.graph.stations
            .filter { $0.lineIDs.contains(lineID) }
            .compactMap { station -> (station: TubeStation, range: Range<String.Index>)? in
                let name = normalize(station.name)
                guard let range = normalizedReason.range(of: name) else { return nil }
                return (station, range)
            }
            .sorted { first, second in
                first.range.lowerBound < second.range.lowerBound
            }
            .reduce(into: [TubeStation]()) { result, entry in
                if !result.contains(where: { $0.id == entry.station.id }) {
                    result.append(entry.station)
                }
            }
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " underground station", with: "")
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: ".", with: "")
    }
}

