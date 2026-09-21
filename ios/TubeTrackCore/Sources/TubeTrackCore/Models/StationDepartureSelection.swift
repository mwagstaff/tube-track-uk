import Foundation

public enum StationDepartureSelection {
    public static func resolved(
        controlled: TubeLineID?,
        requested: TubeLineID?,
        usesControlledSelection: Bool,
        preferred: TubeLineID? = nil,
        lineIDs: [TubeLineID],
        arrivals: [TfLArrivalPrediction]
    ) -> TubeLineID? {
        resolved(
            current: usesControlledSelection ? controlled : requested,
            preferred: preferred,
            lineIDs: lineIDs,
            arrivals: arrivals
        )
    }

    public static func resolved(
        current: TubeLineID?,
        preferred: TubeLineID? = nil,
        lineIDs: [TubeLineID],
        arrivals: [TfLArrivalPrediction]
    ) -> TubeLineID? {
        if let current, lineIDs.contains(current) {
            return current
        }
        if let preferred, lineIDs.contains(preferred) {
            return preferred
        }

        let linesWithPredictions = Set(arrivals.compactMap {
            TubeLineID(rawValue: $0.lineId)
        })
        return lineIDs.first(where: linesWithPredictions.contains) ?? lineIDs.first
    }
}
