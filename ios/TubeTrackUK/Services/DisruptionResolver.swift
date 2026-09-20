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
        // TfL commonly returns several current entries with id == 0 and the same
        // severity. SwiftUI requires every live-status row to keep a genuinely
        // unique identity, so include a deterministic fingerprint of the entry.
        let baseID = "\(lineID.rawValue):\(status.id):\(status.statusSeverity):\(fingerprint(status, reason: reason))"

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
        let inferredPath: [TubeSegment]? = if mentionedStations.count >= 2 {
            if lineID == .tram {
                repository.orderedSegmentPath(
                    from: mentionedStations[0].id,
                    to: mentionedStations[1].id,
                    on: lineID
                ) ?? repository.shortestSegmentPath(
                    from: mentionedStations[0].id,
                    to: mentionedStations[1].id,
                    on: lineID
                )
            } else {
                repository.shortestSegmentPath(
                    from: mentionedStations[0].id,
                    to: mentionedStations[1].id,
                    on: lineID
                )
            }
        } else {
            nil
        }

        if let path = inferredPath, !path.isEmpty {
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
            .replacingOccurrences(of: " dlr station", with: "")
            .replacingOccurrences(of: " tram stop", with: "")
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: ".", with: "")
    }

    private func fingerprint(_ status: TfLStatusEntry, reason: String) -> String {
        let validity = status.validityPeriods?.map { period in
            "\(period.fromDate?.timeIntervalSince1970 ?? 0):\(period.toDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|") ?? ""
        let routes = status.disruption?.affectedRoutes?.map { route in
            let stops = route.routeSectionNaptanEntrySequence?.compactMap {
                $0.stopPoint?.naptanId ?? $0.stopPoint?.id
            }.joined(separator: ",") ?? ""
            return "\(route.id ?? ""):\(route.name ?? ""):\(stops)"
        }.joined(separator: "|") ?? ""
        let value = [status.statusSeverityDescription, reason, validity, routes].joined(separator: "\u{1f}")

        // FNV-1a is deliberately used instead of Hasher, whose seed changes on
        // every process launch. Stable IDs prevent rows being replaced mid-tap
        // when the 30-second status refresh completes.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
