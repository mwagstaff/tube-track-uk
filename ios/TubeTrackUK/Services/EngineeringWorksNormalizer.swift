import Foundation

struct EngineeringWorksNormalizer: Sendable {
    func deduplicatedAndSorted(_ works: [EngineeringWork]) -> [EngineeringWork] {
        let grouped = Dictionary(grouping: works, by: deduplicationKey)
        return grouped.values.compactMap(preferredWork).sorted { left, right in
            if left.startDate != right.startDate { return left.startDate < right.startDate }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private func deduplicationKey(_ work: EngineeringWork) -> String {
        let normalizedDetail = work.detail.lowercased().filter(\.isLetter)
        let lines = work.lineIDs.map(\.rawValue).sorted().joined(separator: ",")
        let start = LondonRailDate.dateIdentifier(for: work.startDate)
        let end = LondonRailDate.dateIdentifier(for: work.endDate)
        return "\(lines):\(normalizedDetail.prefix(80)):\(start):\(end)"
    }

    private func preferredWork(_ candidates: [EngineeringWork]) -> EngineeringWork? {
        candidates.max { left, right in
            let leftScore = sourceScore(left.source) + confidenceScore(left.confidence)
            let rightScore = sourceScore(right.source) + confidenceScore(right.confidence)
            if leftScore != rightScore { return leftScore < rightScore }
            return left.fetchedAt < right.fetchedAt
        }
    }

    private func sourceScore(_ source: EngineeringWorkSource) -> Int {
        switch source {
        case .unifiedAPI: 30
        case .tubeThisWeekend: 20
        case .cached: 0
        }
    }

    private func confidenceScore(_ confidence: ResolutionConfidence) -> Int {
        switch confidence {
        case .exact: 3
        case .inferred: 2
        case .lineOnly: 1
        }
    }
}
