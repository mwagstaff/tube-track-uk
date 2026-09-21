import AppIntents
import TubeTrackCore

struct StationDeparturesConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Station Departures"
    static let description = IntentDescription("Choose a station, and optionally one of its lines.")

    @Parameter(title: "Station")
    var station: StationEntity?

    @Parameter(title: "Line")
    var line: StationLineEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$station, .hasAnyValue) {
            Summary("Departures from \(\.$station)") {
                \.$line
            }
        } otherwise: {
            Summary("Departures from \(\.$station)")
        }
    }

    /// The chosen line, ignored when it does not serve the chosen station
    /// (the passenger may have changed station after picking a line).
    var selectedLineID: TubeLineID? {
        guard let lineID = line?.lineID, let station else { return nil }
        return station.lineIDs.contains(lineID) ? lineID : nil
    }
}
