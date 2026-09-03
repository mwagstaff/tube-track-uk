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
