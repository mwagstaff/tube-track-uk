import SwiftUI

struct StationDetailCard: View {
    @Environment(TubeAppState.self) private var appState
    let station: TubeStation

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(station.name)
                            .font(.headline)
                        Text(station.interchange ? "Interchange station" : "Underground station")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") {
                        appState.clearStationSelection()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(station.lineIDs) { lineID in
                            Button {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    appState.selectedLineID = lineID
                                }
                            } label: {
                                LineBadge(lineID: lineID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                Divider()

                if let issue = appState.disruptions.first(where: { $0.affectedStationIDs.contains(station.id) }) {
                    Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(issue.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if appState.isRefreshingStationArrivals {
                    ProgressView("Loading live departures…")
                        .font(.caption)
                } else if appState.stationArrivals.isEmpty {
                    Text(appState.stationArrivalsError ?? "No imminent departures reported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(appState.stationArrivals.prefix(3)) { arrival in
                            arrivalRow(arrival)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: station.id) {
            if appState.stationArrivals.isEmpty {
                await appState.refreshArrivals(for: station.id)
            }
        }
    }

    private func arrivalRow(_ arrival: TfLArrivalPrediction) -> some View {
        HStack(spacing: 9) {
            if let line = TubeLineID(rawValue: arrival.lineId) {
                Circle().fill(Color.tubeLine(line)).frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(arrival.destinationName ?? arrival.towards ?? "Check platform")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(arrival.platformName ?? "Live TfL prediction")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(departureTime(arrival.timeToStation))
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        }
    }

    private func departureTime(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds < 45 { return "Due" }
        return "\(max(1, seconds / 60)) min"
    }
}

struct TrainFilterBar: View {
    @Environment(TubeAppState.self) private var appState

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                Button {
                    appState.setTrainFilter(nil)
                } label: {
                    Text("All")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(appState.trainLineFilter.isEmpty ? Color.blue : Color.secondary.opacity(0.16), in: .capsule)
                        .foregroundStyle(appState.trainLineFilter.isEmpty ? .white : .primary)
                }
                .buttonStyle(.plain)

                ForEach(TubeLineID.allCases) { lineID in
                    Button {
                        appState.setTrainFilter(lineID)
                    } label: {
                        LineBadge(lineID: lineID, showsName: true)
                            .overlay {
                                if appState.trainLineFilter.contains(lineID) {
                                    Capsule().stroke(Color.blue, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
    }
}

struct LineDetailCard: View {
    @Environment(TubeAppState.self) private var appState
    let lineID: TubeLineID

    private var status: TfLStatusEntry? {
        appState.statuses.first { $0.id == lineID }?.lineStatuses.first
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    LineBadge(lineID: lineID)
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") {
                        appState.selectedLineID = nil
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }

                Label(
                    status?.statusSeverityDescription ?? "Status updating",
                    systemImage: status?.isGoodService == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(status?.isGoodService == true ? .green : .orange)

                if let reason = status?.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Button {
                    appState.setTrainFilter(lineID)
                    appState.setLiveTrains(true)
                } label: {
                    Label("Show estimated live trains", systemImage: "tram.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
