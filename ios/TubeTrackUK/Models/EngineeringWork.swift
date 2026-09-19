import Foundation

enum EngineeringWorkSource: String, Codable, Sendable {
    case unifiedAPI
    case plannedTrackClosuresPDF
    case tubeThisWeekend
    case cached

    var title: String {
        switch self {
        case .unifiedAPI: "TfL future status"
        case .plannedTrackClosuresPDF: "TfL six-month closure schedule"
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

    var isDateOnly: Bool { source == .plannedTrackClosuresPDF }

    /// PDF dates are inclusive, while `endDate` is stored as an exclusive
    /// boundary so date filtering remains correct.
    var displayEndDate: Date {
        isDateOnly ? endDate.addingTimeInterval(-1) : endDate
    }
}

struct PlannedWorksV2Data: Decodable, Sendable {
    let works: [PlannedWorkV2]
    let coverage: PlannedWorksV2Coverage
}

struct PlannedWorksV2Coverage: Decodable, Sendable {
    let publishedThrough: String
}

struct PlannedWorkV2: Decodable, Sendable {
    struct DateRange: Decodable, Sendable {
        let start: String
        let end: String
    }

    struct Source: Decodable, Sendable {
        let kind: String
    }

    let id: String
    let lineId: TubeLineID
    let title: String
    let description: String
    let dateRange: DateRange
    let validFrom: Date?
    let validTo: Date?
    let timingPrecision: String
    let provisional: Bool
    let severity: Int?
    let affectedRoutes: [TfLDisruptedRoute]
    let affectedStops: [TfLStopPoint]
    let sources: [Source]
}
