import Foundation

struct EngineeringWorksBuilder: Sendable {
    private let repository: TubeNetworkRepository

    init(repository: TubeNetworkRepository) {
        self.repository = repository
    }

    func works(
        from statuses: [TfLLineStatus],
        fetchedAt: Date = .now
    ) -> [EngineeringWork] {
        let resolver = DisruptionResolver(repository: repository)
        var works: [EngineeringWork] = []

        for line in statuses {
            for status in line.lineStatuses where status.isPlannedEngineeringWork {
                let resolved = resolver.resolve(status, lineID: line.id)
                for validity in status.validityPeriods ?? [] {
                    guard let startDate = validity.fromDate,
                          let endDate = validity.toDate,
                          endDate > startDate else {
                        continue
                    }

                    works.append(
                        EngineeringWork(
                            id: [
                                resolved.id,
                                LondonRailDate.dateIdentifier(for: startDate),
                                LondonRailDate.dateIdentifier(for: endDate),
                            ].joined(separator: ":"),
                            title: status.statusSeverityDescription,
                            detail: status.reason
                                ?? status.disruption?.description
                                ?? status.statusSeverityDescription,
                            lineIDs: [line.id],
                            affectedStationIDs: resolved.affectedStationIDs,
                            affectedSegmentIDs: resolved.affectedSegmentIDs,
                            startDate: startDate,
                            endDate: endDate,
                            source: .unifiedAPI,
                            fetchedAt: fetchedAt,
                            confidence: resolved.confidence
                        )
                    )
                }
            }
        }

        return works
    }

    func works(
        from records: [PlannedWorkV2],
        fetchedAt: Date = .now
    ) -> [EngineeringWork] {
        let resolver = DisruptionResolver(repository: repository)
        return records.compactMap { record in
            let startDate: Date
            let endDate: Date
            let source: EngineeringWorkSource
            if let validFrom = record.validFrom,
               let validTo = record.validTo,
               validTo > validFrom {
                startDate = validFrom
                endDate = validTo
                source = .unifiedAPI
            } else if let start = Self.dateOnly(record.dateRange.start),
                      let inclusiveEnd = Self.dateOnly(record.dateRange.end),
                      let exclusiveEnd = LondonRailDate.calendar.date(
                        byAdding: .day,
                        value: 1,
                        to: inclusiveEnd
                      ),
                      exclusiveEnd > start {
                startDate = start
                endDate = exclusiveEnd
                source = .plannedTrackClosuresPDF
            } else {
                return nil
            }

            let status = TfLStatusEntry(
                id: 0,
                statusSeverity: record.severity ?? 5,
                statusSeverityDescription: record.title,
                reason: record.description,
                validityPeriods: [TfLValidityPeriod(
                    fromDate: startDate,
                    toDate: endDate,
                    isNow: false
                )],
                disruption: TfLDisruption(
                    category: "PlannedWork",
                    categoryDescription: "PlannedWork",
                    description: record.description,
                    affectedRoutes: record.affectedRoutes,
                    affectedStops: record.affectedStops,
                    closureText: "plannedClosure"
                )
            )
            let resolved = resolver.resolve(status, lineID: record.lineId)
            return EngineeringWork(
                id: record.id,
                title: record.title,
                detail: record.description,
                lineIDs: [record.lineId],
                affectedStationIDs: resolved.affectedStationIDs,
                affectedSegmentIDs: resolved.affectedSegmentIDs,
                startDate: startDate,
                endDate: endDate,
                source: source,
                fetchedAt: fetchedAt,
                confidence: resolved.confidence
            )
        }
    }

    private static func dateOnly(_ value: String) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return LondonRailDate.calendar.date(from: DateComponents(
            timeZone: LondonRailDate.timeZone,
            year: components[0],
            month: components[1],
            day: components[2]
        ))
    }
}

extension TfLStatusEntry {
    var isPlannedEngineeringWork: Bool {
        let metadata = [
            disruption?.category,
            disruption?.categoryDescription,
            disruption?.closureText,
            statusSeverityDescription,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        return metadata.contains("planned work")
            || metadata.contains("plannedwork")
            || metadata.contains("planned closure")
            || metadata.contains("plannedclosure")
    }
}
