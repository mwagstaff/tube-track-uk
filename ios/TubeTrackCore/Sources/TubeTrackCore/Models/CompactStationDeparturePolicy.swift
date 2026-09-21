import Foundation

public enum CompactStationDeparturePolicy {
    public static let maximumInformationLines = 6
    public static let maximumDeparturesPerGroup = 2

    public static func groups(
        from arrivals: [TfLArrivalPrediction],
        for selectedLineID: TubeLineID?,
        maximumInformationLines: Int = maximumInformationLines
    ) -> [StationDepartureGroup] {
        guard maximumInformationLines >= 2 else { return [] }
        let availableGroups = StationDepartureGroup.groups(
            from: arrivals,
            for: selectedLineID
        )
        let groupCount = min(
            availableGroups.count,
            maximumInformationLines / 2
        )
        guard groupCount > 0 else { return [] }

        let chosenGroups = Array(availableGroups.prefix(groupCount))
        var departureCounts = chosenGroups.map { $0.arrivals.isEmpty ? 0 : 1 }
        var usedLines = groupCount + departureCounts.reduce(0, +)

        while usedLines < maximumInformationLines {
            var addedDeparture = false
            for index in chosenGroups.indices where usedLines < maximumInformationLines {
                let availableCount = min(
                    maximumDeparturesPerGroup,
                    chosenGroups[index].arrivals.count
                )
                guard departureCounts[index] < availableCount else { continue }
                departureCounts[index] += 1
                usedLines += 1
                addedDeparture = true
            }
            if !addedDeparture { break }
        }

        return chosenGroups.indices.map { index in
            let group = chosenGroups[index]
            return StationDepartureGroup(
                lineID: group.lineID,
                direction: group.direction,
                arrivals: Array(group.arrivals.prefix(departureCounts[index]))
            )
        }
    }
}
