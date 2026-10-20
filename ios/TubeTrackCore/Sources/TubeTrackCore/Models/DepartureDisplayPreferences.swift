import Foundation
import SwiftUI

public enum DepartureTransitType: String, CaseIterable, Identifiable, Codable, Sendable {
    case underground, overground, elizabeth, dlr, tram, nationalRail, riverBus

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .underground: "Underground"
        case .overground: "Overground"
        case .elizabeth: "Elizabeth line"
        case .dlr: "DLR"
        case .tram: "Trams"
        case .nationalRail: "National Rail"
        case .riverBus: "River Bus"
        }
    }

    public init(lineID: String) {
        if lineID.hasPrefix("national-rail:") { self = .nationalRail }
        else if lineID.hasPrefix("rb") { self = .riverBus }
        else {
            switch TubeLineID(rawValue: lineID)?.modeName {
            case "national-rail": self = .nationalRail
            case "overground": self = .overground
            case "elizabeth-line": self = .elizabeth
            case "dlr": self = .dlr
            case "tram": self = .tram
            default: self = .underground
            }
        }
    }

    public var defaultFormat: DepartureTimeFormat { self == .nationalRail ? .clock : .minutes }
}

public enum DepartureTimeFormat: String, Codable, CaseIterable, Sendable {
    case clock, minutes
    public var title: String { self == .clock ? "HH:mm" : "Minutes" }
}

public struct DepartureDisplayPreferences: Codable, Hashable, Sendable {
    public var matchesRealWorld = true
    public var usesClockOverOneHour = true
    public var overrides: [String: DepartureTimeFormat] = [:]

    public init() {}

    public subscript(type: DepartureTransitType) -> DepartureTimeFormat {
        get { overrides[type.rawValue] ?? type.defaultFormat }
        set { overrides[type.rawValue] = newValue }
    }

    public func format(for type: DepartureTransitType, seconds: TimeInterval) -> DepartureTimeFormat {
        if usesClockOverOneHour && seconds > 3600 { return .clock }
        return matchesRealWorld ? type.defaultFormat : self[type]
    }
}

/// One shared preference value invalidates app and widget views when it changes.
/// Reading at render time also applies preferences to remotely started activities.
@MainActor
@propertyWrapper
public struct DepartureDisplayStorage: DynamicProperty {
    public static let key = "departureDisplayPreferences"
    @AppStorage private var encoded: String

    public init(store: UserDefaults? = AppGroup.defaults) {
        _encoded = AppStorage(wrappedValue: "", Self.key, store: store)
    }

    public var wrappedValue: DepartureDisplayPreferences {
        get {
            guard let data = encoded.data(using: .utf8),
                  let value = try? JSONDecoder().decode(DepartureDisplayPreferences.self, from: data)
            else { return .init() }
            return value
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let value = String(data: data, encoding: .utf8) else { return }
            encoded = value
        }
    }

    public var projectedValue: Binding<DepartureDisplayPreferences> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
