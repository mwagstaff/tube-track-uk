import AppIntents
import TubeTrackCore

/// A rail line, offered when configuring the line status widget.
struct RailLineEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Line")
    static let defaultQuery = RailLineQuery()

    let id: String

    init(lineID: TubeLineID) {
        id = lineID.rawValue
    }

    var lineID: TubeLineID? { TubeLineID(rawValue: id) }

    var displayRepresentation: DisplayRepresentation {
        guard let lineID else { return DisplayRepresentation(title: "\(id)") }
        let mode = lineID.widgetModeDescription
        guard mode != lineID.displayName else { return DisplayRepresentation(title: "\(lineID.displayName)") }
        return DisplayRepresentation(title: "\(lineID.displayName)", subtitle: "\(mode)")
    }
}

struct RailLineQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RailLineEntity] {
        identifiers.compactMap(TubeLineID.init(rawValue:)).map(RailLineEntity.init(lineID:))
    }

    func suggestedEntities() async throws -> [RailLineEntity] {
        TubeLineID.widgetDisplayOrder.map(RailLineEntity.init(lineID:))
    }
}

extension TubeLineID {
    var widgetModeDescription: String {
        switch modeName {
        case "tube": "Underground"
        case "dlr": "DLR"
        case "elizabeth-line": "Elizabeth line"
        case "overground": "Overground"
        case "tram": "Trams"
        default: modeName
        }
    }

}
