import Foundation

enum JourneyTimeMode: String, CaseIterable, Identifiable, Sendable {
    case now, departAt, arriveBy
    var id: Self { self }
    var title: String {
        switch self {
        case .now: "Leave now"
        case .departAt: "Depart at"
        case .arriveBy: "Arrive by"
        }
    }
}

enum JourneyAccessibility: String, CaseIterable, Identifiable, Sendable {
    case none, platform, train
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "No preference"
        case .platform: "Step-free to platform"
        case .train: "Step-free to train"
        }
    }
}

struct JourneyRequest: Equatable, Sendable {
    let from: String
    let to: String
    let timeMode: JourneyTimeMode
    let time: Date
    let accessibility: JourneyAccessibility

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "timeMode", value: timeMode.rawValue),
            URLQueryItem(name: "accessibility", value: accessibility.rawValue)
        ]
        if timeMode != .now {
            items.append(URLQueryItem(name: "time", value: time.ISO8601Format()))
        }
        return items
    }
}

struct JourneyPlan: Decodable, Sendable {
    let from: JourneyStation
    let to: JourneyStation
    let timeMode: String
    let requestedAt: Date
    let accessibility: String
    let journeys: [PlannedJourney]
    let messages: [String]
    let expiresAt: Date
    let attribution: String
}

struct JourneyStation: Decodable, Sendable {
    let id: String
    let name: String
}

struct PlannedJourney: Decodable, Identifiable, Sendable {
    let id: String
    let departureTime: Date
    let arrivalTime: Date
    let durationMinutes: Int
    let changes: Int
    let walkingMinutes: Int
    let waitingMinutes: Int
    let warnings: [JourneyWarning]
    let legs: [JourneyLeg]
    let labels: [String]

    var recommendation: String? {
        if labels.contains("earliestArrival") { return "Earliest estimated arrival" }
        if labels.contains("latestDeparture") { return "Latest departure to arrive on time" }
        if labels.contains("lessDisrupted") { return "Less reported disruption" }
        return nil
    }

    var severeWarnings: [JourneyWarning] { warnings.filter { $0.severity == "severe" } }
}

struct JourneyLeg: Decodable, Identifiable, Sendable {
    let id: String
    let mode: String
    let instruction: String
    let from: JourneyPoint
    let to: JourneyPoint
    let lines: [JourneyLine]
    let departureTime: Date
    let arrivalTime: Date
    let scheduledDepartureTime: Date?
    let scheduledArrivalTime: Date?
    let timing: String
    let durationMinutes: Int
    let warnings: [JourneyWarning]
    let stops: [JourneyStation]
}

struct JourneyPoint: Decodable, Sendable {
    let id: String
    let name: String
    let platform: String?
}

struct JourneyLine: Decodable, Sendable {
    let id: String
    let name: String
    let direction: String
}

struct JourneyWarning: Decodable, Identifiable, Sendable {
    let id: String
    let message: String
    let kind: String
    let severity: String
}

enum JourneyFormatting {
    static func time(_ date: Date) -> String {
        LondonRailDate.formatted(date, dateFormat: "HH:mm")
    }

    static func date(_ date: Date) -> String {
        LondonRailDate.formatted(date, dateFormat: "EEE d MMM, HH:mm")
    }
}


extension JourneyLine {
    var tubeLineID: TubeLineID? {
        let key = id.lowercased()
        if let line = TubeLineID(rawValue: key) { return line }
        if key == "elizabeth-line" { return .elizabeth }
        if key == "london-trams" { return .tram }
        // Some Journey Planner responses use route IDs instead of line IDs.
        let normalizedName = name.lowercased().replacingOccurrences(of: " line", with: "")
        return TubeLineID.allCases.first {
            $0.displayName.lowercased().replacingOccurrences(of: " line", with: "") == normalizedName
        }
    }
}

extension PlannedJourney {
    var distinctLines: [JourneyLine] {
        var seen = Set<String>()
        return legs.filter { $0.mode != "walking" }.flatMap(\.lines).filter {
            seen.insert($0.tubeLineID?.rawValue ?? $0.id + $0.name).inserted
        }
    }
}
