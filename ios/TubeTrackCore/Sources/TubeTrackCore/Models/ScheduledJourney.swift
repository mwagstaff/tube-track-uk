import Foundation

public struct ScheduledBoard: Codable, Hashable, Sendable {
    public var hubId: String
    public var stationName: String
    public var lineId: String
    public var direction: DepartureDirectionFilter
    public var stopIds: [String]

    public init(hub: StationHub, line: TubeLineID, direction: DepartureDirectionFilter = .any) {
        hubId = hub.id
        stationName = hub.name
        lineId = line.rawValue
        self.direction = direction
        stopIds = hub.stopIDs
    }
}

public struct ScheduledJourneyWindow: Codable, Hashable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public var board: ScheduledBoard

    public init(startMinute: Int, endMinute: Int, board: ScheduledBoard) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.board = board
    }

    public var isValid: Bool {
        startMinute >= 0 && endMinute < 1440 && endMinute > startMinute && endMinute - startMinute <= 120
    }

    public var timeSummary: String {
        "\(Self.time(startMinute))–\(Self.time(endMinute))"
    }

    private static func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

public struct ScheduledJourney: Codable, Identifiable, Hashable, Sendable {
    public static let maximumCount = 3
    public static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    public var id: String
    public var name: String
    public var enabled: Bool
    /// ISO weekdays: Monday = 1, Sunday = 7. Times always use Europe/London.
    public var days: [Int]
    public var morning: ScheduledJourneyWindow?
    public var afternoon: ScheduledJourneyWindow?

    public init(id: String = UUID().uuidString, name: String = "", enabled: Bool = true,
                days: [Int] = [1, 2, 3, 4, 5], morning: ScheduledJourneyWindow? = nil,
                afternoon: ScheduledJourneyWindow? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.days = days
        self.morning = morning
        self.afternoon = afternoon
    }

    public var title: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Scheduled journey" : name
    }

    public var daysSummary: String {
        let selected = Set(days)
        if selected == Set(1...5) { return "Weekdays" }
        if selected == Set([6, 7]) { return "Weekends" }
        if selected == Set(1...7) { return "Every day" }
        return days.sorted().filter { (1...7).contains($0) }
            .map { String(Self.dayNames[$0 - 1].prefix(3)) }.joined(separator: ", ")
    }

    /// Validate an edit by replacing its saved version, never by comparing the
    /// draft against that same version as if it were a second journey.
    public static func validationError(for candidate: Self, existing: [Self], maximum: Int = maximumCount) -> String? {
        validationError(for: [candidate] + existing.filter { $0.id != candidate.id }, maximum: maximum)
    }

    public func conflictingJourneys(in existing: [Self]) -> [Self] {
        guard enabled else { return [] }
        let windows = [morning, afternoon].compactMap { $0 }
        return existing.filter { other in
            other.id != id && other.enabled && !Set(days).isDisjoint(with: other.days)
                && windows.contains { window in
                    [other.morning, other.afternoon].compactMap { $0 }.contains {
                        window.startMinute < $0.endMinute && $0.startMinute < window.endMinute
                    }
                }
        }
    }

    /// Includes stations and both windows so unnamed journeys are identifiable,
    /// and users can see everything that will be removed by replacement.
    public var replacementSummary: String {
        ([name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? daysSummary : "“\(name)” · \(daysSummary)"] + [
            morning.map { "Morning: \($0.board.stationName) · \($0.timeSummary)" },
            afternoon.map { "Afternoon: \($0.board.stationName) · \($0.timeSummary)" }
        ].compactMap { $0 }).joined(separator: "\n")
    }

    public static func validationError(for journeys: [Self], maximum: Int = maximumCount) -> String? {
        if journeys.count > maximum { return "You can save up to \(maximum) journeys." }
        for journey in journeys {
            if journey.days.isEmpty { return "Choose at least one day." }
            if journey.days.contains(where: { !(1...7).contains($0) }) { return "Choose valid days." }
            if journey.name.count > 60 { return "Keep the journey name under 60 characters." }
            let windows = [journey.morning, journey.afternoon].compactMap { $0 }
            if windows.isEmpty { return "Add a morning or afternoon window." }
            if windows.contains(where: { !$0.isValid }) {
                return "Each window must end later on the same day and last no more than two hours."
            }
        }
        let slots: [ValidationSlot] = journeys.filter(\.enabled).flatMap { journey in
            [("Morning", journey.morning), ("Afternoon", journey.afternoon)].compactMap { period, window in
                window.map { ValidationSlot(journey: journey, period: period, window: $0) }
            }
        }
        for i in slots.indices {
            for k in slots.indices where k > i {
                let first = slots[i]
                let second = slots[k]
                let sharedDays = Set(first.journey.days).intersection(second.journey.days).sorted()
                if !sharedDays.isEmpty,
                   first.window.startMinute < second.window.endMinute,
                   second.window.startMinute < first.window.endMinute {
                    let days = sharedDays.map { String(dayNames[$0 - 1].prefix(3)) }.joined(separator: ", ")
                    if first.journey.id == second.journey.id {
                        return "\(first.description) overlaps with \(second.description.lowercasedFirstLetter) on \(days). Change one of these windows."
                    }
                    return "\(first.description) overlaps with another enabled journey: “\(second.journey.title)” — \(second.description.lowercasedFirstLetter), on \(days). Edit or pause that journey in Profile → Scheduled journeys, or choose different days or times."
                }
            }
        }
        return nil
    }

    private struct ValidationSlot {
        let journey: ScheduledJourney
        let period: String
        let window: ScheduledJourneyWindow
        var description: String { "\(period) at \(window.board.stationName) (\(window.timeSummary))" }
    }
}

private extension String {
    var lowercasedFirstLetter: String { prefix(1).lowercased() + dropFirst() }
}
