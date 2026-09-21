import Foundation

/// `tubetrack://` links used by the widgets to open the app in context.
///
/// - `tubetrack://status` — the map with every disruption highlighted
/// - `tubetrack://line/central` — one line's status
/// - `tubetrack://station/940GZZLUOXC?line=central` — a station's departures
public enum DeepLink: Equatable, Sendable {
    public static let scheme = "tubetrack"

    case status
    case line(TubeLineID)
    case station(id: String, line: TubeLineID?)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else {
            return nil
        }
        let segments = components.path.split(separator: "/").map(String.init)
        switch host {
        case "status" where segments.isEmpty:
            self = .status
        case "line":
            guard segments.count == 1, let lineID = TubeLineID(rawValue: segments[0]) else {
                return nil
            }
            self = .line(lineID)
        case "station":
            guard segments.count == 1, !segments[0].isEmpty else { return nil }
            let lineID = components.queryItems?
                .first(where: { $0.name == "line" })?
                .value
                .flatMap(TubeLineID.init(rawValue:))
            self = .station(id: segments[0], line: lineID)
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .status:
            components.host = "status"
        case let .line(lineID):
            components.host = "line"
            components.path = "/\(lineID.rawValue)"
        case let .station(id, lineID):
            components.host = "station"
            components.path = "/\(id)"
            if let lineID {
                components.queryItems = [URLQueryItem(name: "line", value: lineID.rawValue)]
            }
        }
        // Every component is a known-safe identifier, so this cannot fail.
        return components.url!
    }
}
