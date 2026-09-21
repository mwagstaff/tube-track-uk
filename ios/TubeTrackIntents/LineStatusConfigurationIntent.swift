import AppIntents
import TubeTrackCore

struct LineStatusConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Line Status"
    static let description = IntentDescription("Choose which lines to keep an eye on.")

    @Parameter(title: "Lines", default: [])
    var lines: [RailLineEntity]

    @Parameter(title: "Disrupted lines first", default: true)
    var disruptionsFirst: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Status for \(\.$lines)") {
            \.$disruptionsFirst
        }
    }

    /// Selected lines in display order; an empty selection means every line.
    var selectedLineIDs: [TubeLineID] {
        let chosen = lines.compactMap(\.lineID)
        guard !chosen.isEmpty else { return TubeLineID.widgetDisplayOrder }
        return chosen.sorted { $0.widgetDisplayRank < $1.widgetDisplayRank }
    }
}
