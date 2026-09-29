import SwiftUI
import TubeTrackCore

/// Other National Rail operators with a current problem, beneath the lines
/// the app draws itself. Good service is not listed.
struct NationalRailStatusRows: View {
    @Environment(TubeAppState.self) private var appState

    var body: some View {
        let disrupted = appState.nationalRail.disruptedOperators
        if !disrupted.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other National Rail operators")
                    .font(.appCaption(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(disrupted) { status in
                    NationalRailOperatorRow(status: status, showsReason: true)
                }
                if appState.nationalRail.isStale || appState.isOffline {
                    Text("National Rail status may be out of date")
                        .font(.appCaption2())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The operators that share a station, for its detail card.
struct StationNationalRailOperators: View {
    @Environment(TubeAppState.self) private var appState
    let stationIDs: [String]

    var body: some View {
        let operators = appState.nationalRail.operators(atStationIDs: stationIDs)
        if !operators.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Also at this station")
                    .font(.appCaption2(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(operators) { status in
                    NationalRailOperatorRow(status: status, showsReason: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NationalRailOperatorRow: View {
    let status: NationalRailOperatorStatus
    let showsReason: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "tram.fill")
                    .font(.appCaption2())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(status.name)
                    .font(.appCaption(.semibold))
                Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(status.lineStatuses.isEmpty ? "Status unavailable" : status.headline)
                    .font(.appCaption())
                    .foregroundStyle(status.issue == nil ? Color.secondary : Color.orange)
            }
            if showsReason, let reason = status.issue?.reason, !reason.isEmpty {
                Text(reason)
                    .font(.appCaption2())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
