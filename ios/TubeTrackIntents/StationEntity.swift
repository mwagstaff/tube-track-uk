import AppIntents
import TubeTrackCore

/// A station hub the passenger can choose for the departures widget.
struct StationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Station")
    static let defaultQuery = StationQuery()

    let id: String
    let name: String
    let lineIDs: [TubeLineID]

    init(hub: StationHub) {
        id = hub.id
        name = hub.name
        lineIDs = hub.lineIDs
    }

    var displayRepresentation: DisplayRepresentation {
        let lines = lineIDs
            .sorted { $0.widgetDisplayRank < $1.widgetDisplayRank }
            .map(\.displayName)
            .joined(separator: ", ")
        return DisplayRepresentation(title: "\(name)", subtitle: "\(lines)")
    }
}

struct StationQuery: EntityStringQuery {
    private static let fallbackSuggestions = [
        "HUBKGX", "940GZZLUOXC", "HUBBAN", "HUBWAT", "HUBVIC", "HUBLST", "HUBPAD", "HUBSRA",
    ]

    func entities(for identifiers: [String]) async throws -> [StationEntity] {
        identifiers.compactMap { StationIndex.bundled.hub(containing: $0) }.map(StationEntity.init(hub:))
    }

    /// Stations the passenger opened in the app recently, then busy hubs.
    func suggestedEntities() async throws -> [StationEntity] {
        var identifiers = AppGroup.recentStationIDs
        for fallback in Self.fallbackSuggestions where !identifiers.contains(fallback) {
            identifiers.append(fallback)
        }
        var seen = Set<String>()
        return identifiers
            .compactMap { StationIndex.bundled.hub(containing: $0) }
            .filter { seen.insert($0.id).inserted }
            .prefix(10)
            .map(StationEntity.init(hub:))
    }

    func entities(matching string: String) async throws -> [StationEntity] {
        StationIndex.bundled.search(string, limit: 20).map(StationEntity.init(hub:))
    }
}

/// A line serving the chosen station. Kept separate from `RailLineEntity`
/// so its options can depend on the station parameter.
struct StationLineEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Line")
    static let defaultQuery = StationLineQuery()

    let id: String

    init(lineID: TubeLineID) {
        id = lineID.rawValue
    }

    var lineID: TubeLineID? { TubeLineID(rawValue: id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(lineID?.displayName ?? id)")
    }
}

struct StationLineQuery: EntityQuery {
    @IntentParameterDependency<StationDeparturesConfigurationIntent>(\.$station)
    var departures

    func entities(for identifiers: [String]) async throws -> [StationLineEntity] {
        identifiers.compactMap(TubeLineID.init(rawValue:)).map(StationLineEntity.init(lineID:))
    }

    func suggestedEntities() async throws -> [StationLineEntity] {
        guard let station = departures?.station else { return [] }
        return station.lineIDs
            .sorted { $0.widgetDisplayRank < $1.widgetDisplayRank }
            .map(StationLineEntity.init(lineID:))
    }
}
