import Foundation
import TubeTrackCore

enum WatchCircularSlot: Int, CaseIterable, Identifiable {
    case one = 1
    case two
    case three

    var id: Int { rawValue }
    var title: String { "Circle \(rawValue)" }
    var kind: String {
        rawValue == 1 ? "WatchCircularLineStatus" : "WatchCircularLineStatus\(rawValue)"
    }
    var defaultLine: TubeLineID {
        switch self {
        case .one: .central
        case .two: .bakerloo
        case .three: .victoria
        }
    }
}

/// Watch-local choices shared by the Watch app and its widget extension.
enum WatchWidgetPreferences {
    private static let rectangularKey = "watchRectangularLines"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppGroup.suiteName) ?? .standard
    }

    static var rectangularLines: [TubeLineID] {
        let saved = defaults.stringArray(forKey: rectangularKey)?
            .compactMap(TubeLineID.init(rawValue:)) ?? []
        let unique = saved.reduce(into: [TubeLineID]()) { lines, line in
            if !lines.contains(line) { lines.append(line) }
        }
        return unique.isEmpty ? [.central] : Array(unique.prefix(3))
    }

    /// Every line represented by a Watch widget, without duplicates.
    static var selectedLines: [TubeLineID] {
        let choices = rectangularLines + WatchCircularSlot.allCases.map(circularLine(for:))
        return Array(Set(choices)).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func setRectangularLines(_ lines: [TubeLineID]) {
        let unique = lines.reduce(into: [TubeLineID]()) { chosen, line in
            if !chosen.contains(line) { chosen.append(line) }
        }
        guard !unique.isEmpty else { return }
        defaults.set(Array(unique.prefix(3)).map(\.rawValue), forKey: rectangularKey)
    }

    static func circularLine(for slot: WatchCircularSlot) -> TubeLineID {
        defaults.string(forKey: circularKey(for: slot))
            .flatMap(TubeLineID.init(rawValue:)) ?? slot.defaultLine
    }

    static func setCircularLine(_ line: TubeLineID, for slot: WatchCircularSlot) {
        defaults.set(line.rawValue, forKey: circularKey(for: slot))
    }

    private static func circularKey(for slot: WatchCircularSlot) -> String {
        slot == .one ? "watchCircularLine" : "watchCircularLine\(slot.rawValue)"
    }
}
