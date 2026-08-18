import Foundation

enum ResolutionConfidence: String, Codable, Sendable {
    case exact
    case inferred
    case lineOnly

    var userDescription: String {
        switch self {
        case .exact: "Affected section confirmed"
        case .inferred: "Affected section estimated"
        case .lineOnly: "Whole line shown"
        }
    }
}

struct ResolvedDisruption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let lineID: TubeLineID
    let title: String
    let reason: String
    let severity: Int
    let affectedStationIDs: Set<String>
    let affectedSegmentIDs: Set<String>
    let confidence: ResolutionConfidence
}

