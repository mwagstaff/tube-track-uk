import AppIntents
import TubeTrackCore

/// The direction picker in the departures widget configuration.
///
/// A fixed list rather than an entity query: the configuration UI has no live
/// predictions to enumerate real directions from, and a station's platforms are
/// labelled the same way all week. Unmatched directions fall back to the whole
/// board, so an unusual station never yields an empty widget.
enum DepartureDirection: String, AppEnum {
    case any
    case northbound
    case southbound
    case eastbound
    case westbound
    case inbound
    case outbound

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Direction")

    static let caseDisplayRepresentations: [DepartureDirection: DisplayRepresentation] = [
        .any: "Any direction",
        .northbound: "Northbound",
        .southbound: "Southbound",
        .eastbound: "Eastbound",
        .westbound: "Westbound",
        .inbound: "Inbound",
        .outbound: "Outbound",
    ]

    var filter: DepartureDirectionFilter {
        DepartureDirectionFilter(rawValue: rawValue) ?? .any
    }
}
