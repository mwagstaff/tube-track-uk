import Foundation

enum EngineeringWorkSource: String, Codable, Sendable {
    case unifiedAPI
    case tubeThisWeekend
    case cached

    var title: String {
        switch self {
        case .unifiedAPI: "TfL future status"
        case .tubeThisWeekend: "Tube This Weekend"
        case .cached: "Saved TfL data"
        }
    }
}

struct EngineeringWork: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let lineIDs: [TubeLineID]
    let affectedStationIDs: Set<String>
    let affectedSegmentIDs: Set<String>
    let startDate: Date
    let endDate: Date
    let source: EngineeringWorkSource
    let fetchedAt: Date
    let confidence: ResolutionConfidence
}

