import Foundation

/// A direction a passenger can pin a departure board to.
///
/// The cases mirror the labels `StationDepartureMetadata.directionLabel`
/// produces from TfL platform names, so a widget configured last week still
/// matches predictions arriving today. Kept free of AppIntents so it can be
/// tested and reused away from the configuration UI.
public enum DepartureDirectionFilter: String, CaseIterable, Sendable, Codable {
    case any
    case northbound
    case southbound
    case eastbound
    case westbound
    case inbound
    case outbound

    public var displayName: String {
        switch self {
        case .any: "Any direction"
        case .northbound: "Northbound"
        case .southbound: "Southbound"
        case .eastbound: "Eastbound"
        case .westbound: "Westbound"
        case .inbound: "Inbound"
        case .outbound: "Outbound"
        }
    }

    /// Whether a group's direction label belongs to this filter.
    public func matches(_ directionLabel: String) -> Bool {
        guard self != .any else { return true }
        return directionLabel.compare(displayName, options: .caseInsensitive) == .orderedSame
    }

    /// The filter a board's own direction label belongs to, or `.any` when the
    /// station labels its platforms in some way we don't have a case for
    /// ("Platform 3", "Towards Wimbledon"). Callers that persist a direction
    /// need this: storing only the label would leave a later re-projection
    /// guessing.
    public static func resolve(label: String) -> DepartureDirectionFilter {
        allCases.first { $0 != .any && $0.matches(label) } ?? .any
    }

    /// The filters worth offering for a set of live predictions — used to keep
    /// the picker honest where we do have data to hand.
    public static func available(in arrivals: [TfLArrivalPrediction]) -> [DepartureDirectionFilter] {
        let labels = Set(arrivals.map(StationDepartureMetadata.directionLabel))
        let matched = allCases.filter { filter in
            filter != .any && labels.contains { filter.matches($0) }
        }
        return [.any] + matched
    }
}

public extension Array where Element == StationDepartureGroup {
    /// The groups heading one way. `.any` (or `nil`) leaves the board untouched.
    ///
    /// Strict on purpose: callers need to be able to tell "no trains that way"
    /// from "this station doesn't label platforms that way", and decide for
    /// themselves whether to fall back to the full board.
    func matching(_ direction: DepartureDirectionFilter?) -> [StationDepartureGroup] {
        guard let direction, direction != .any else { return self }
        return filter { direction.matches($0.direction) }
    }
}
