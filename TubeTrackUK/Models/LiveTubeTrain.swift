import Foundation

struct LiveTubeTrain: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let vehicleID: String
    let lineID: TubeLineID
    let destination: String?
    let direction: String?
    let previousStationID: String
    let nextStationID: String
    let segmentID: String
    let progress: Double
    let secondsToNextStation: Int
    let updatedAt: Date

    func projectedProgress(at date: Date) -> Double {
        guard secondsToNextStation > 0 else { return progress }
        let elapsed = max(0, date.timeIntervalSince(updatedAt))
        let remainingProgress = max(0, 1 - progress)
        return min(
            1,
            progress + remainingProgress * elapsed / Double(secondsToNextStation)
        )
    }
}
