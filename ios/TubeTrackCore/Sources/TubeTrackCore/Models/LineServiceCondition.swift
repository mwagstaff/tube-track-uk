import SwiftUI

public enum LineServiceCondition: Equatable, Sendable {
    case good(String)
    case minorDisruption(String)
    case majorDisruption(String)
    case overnightClosure(String)
    case updating

    public var accessibilityDescription: String {
        switch self {
        case let .good(description),
             let .minorDisruption(description),
             let .majorDisruption(description),
             let .overnightClosure(description):
            description
        case .updating:
            "Status updating"
        }
    }

    public static func condition(for status: TfLLineStatus?) -> Self {
        guard let entries = status?.lineStatuses, !entries.isEmpty else { return .updating }

        if let entry = entries.first(where: \.isOvernightClosure) {
            return .overnightClosure(entry.statusSeverityDescription)
        }
        if let entry = entries.first(where: {
            $0.isActionableIssue && $0.statusSeverity != 9
        }) {
            return .majorDisruption(entry.statusSeverityDescription)
        }
        if let entry = entries.first(where: { $0.isActionableIssue }) {
            return .minorDisruption(entry.statusSeverityDescription)
        }
        let description = entries.first?.statusSeverityDescription ?? "Good service"
        return .good(description)
    }
}

extension LineServiceCondition {
    /// Shared status palette for the app's departure boards and the widgets.
    /// Colour is never the only cue: `symbolName` carries the same meaning.
    public var tint: Color {
        switch self {
        case .good: .green
        case .minorDisruption: .orange
        case .majorDisruption: .red
        case .overnightClosure: .indigo
        case .updating: .secondary
        }
    }

    public var symbolName: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .minorDisruption: "exclamationmark.triangle.fill"
        case .majorDisruption: "exclamationmark.octagon.fill"
        case .overnightClosure: "moon.zzz.fill"
        case .updating: "arrow.clockwise"
        }
    }

    public var headline: String {
        switch self {
        case let .good(description),
             let .minorDisruption(description),
             let .majorDisruption(description),
             let .overnightClosure(description):
            description
        case .updating:
            "Updating"
        }
    }

    public var hasIssue: Bool {
        switch self {
        case .minorDisruption, .majorDisruption, .overnightClosure: true
        case .good, .updating: false
        }
    }

    /// Lower ranks are more disruptive. Used to surface the worst line first.
    public var severityRank: Int {
        switch self {
        case .majorDisruption: 0
        case .minorDisruption: 1
        case .overnightClosure: 2
        case .updating: 3
        case .good: 4
        }
    }
}
