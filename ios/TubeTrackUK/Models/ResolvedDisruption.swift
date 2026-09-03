import Foundation

enum DisruptionCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case closures
    case minorDelays
    case severeDelays
    case other

    static let defaultHighlighted: Set<Self> = [.closures, .severeDelays]

    var id: Self { self }

    var title: String {
        switch self {
        case .closures: "Closures"
        case .minorDelays: "Minor delays"
        case .severeDelays: "Severe delays"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .closures: "xmark.octagon"
        case .minorDelays: "clock"
        case .severeDelays: "exclamationmark.triangle"
        case .other: "ellipsis.circle"
        }
    }
}

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

    var category: DisruptionCategory {
        switch severity {
        // TfL groups closed, suspended, planned/part closure, part closed,
        // not running, and non-routine service closed statuses together here.
        case 1, 2, 3, 4, 5, 11, 16, 20: .closures
        case 6: .severeDelays
        case 9: .minorDelays
        default: .other
        }
    }

    var isMinorDelay: Bool {
        category == .minorDelays
    }

    var isMajorIssue: Bool {
        !isMinorDelay
    }
}
