import SwiftUI

struct StationDetailCard: View {
    @Environment(TubeAppState.self) private var appState
    @State private var presentedDisruption: ResolvedDisruption?
    let station: TubeStation
    var onClose: (() -> Void)? = nil

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(station.name)
                            .font(.headline)
                        Text(station.interchange ? "Interchange station" : station.lineIDs.first?.modeName == "tube" ? "Underground station" : "Rail station")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") {
                        if let onClose {
                            onClose()
                        } else {
                            appState.clearStationSelection()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityHint("Closes station details")
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(appState.graph?.lineIDs(at: station) ?? station.lineIDs) { lineID in
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

                if let issue = appState.visibleDisruptions.first(where: { $0.affectedStationIDs.contains(station.id) }) {
                    Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(issue.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Button("Read full disruption", systemImage: "doc.text.magnifyingglass") {
                        presentedDisruption = issue
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
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
        .sheet(item: $presentedDisruption) { disruption in
            DisruptionDetailSheet(disruption: disruption)
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

struct DisruptionDetailCard: View {
    @Environment(TubeAppState.self) private var appState
    @State private var presentedDisruption: ResolvedDisruption?
    let disruption: ResolvedDisruption

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) {
                    LineBadge(lineID: disruption.lineID)
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") {
                        appState.clearMapSelection()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }

                Label(disruption.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)

                Text(disruption.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                HStack {
                    Button("Read full disruption", systemImage: "doc.text.magnifyingglass") {
                        presentedDisruption = disruption
                    }
                    .font(.caption.weight(.semibold))

                    Spacer()

                    Text(disruption.confidence.userDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .sheet(item: $presentedDisruption) { disruption in
            DisruptionDetailSheet(disruption: disruption)
        }
    }
}

struct PlannedWorkDetailCard: View {
    @Environment(TubeAppState.self) private var appState
    @State private var presentsDetails = false
    let work: EngineeringWork

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(work.lineIDs) { LineBadge(lineID: $0) }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Spacer(minLength: 8)

                    Button("Close", systemImage: "xmark.circle.fill") {
                        appState.clearMapSelection()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }

                Label(work.title, systemImage: "wrench.and.screwdriver.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                Text(work.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                HStack(alignment: .firstTextBaseline) {
                    Button("View details", systemImage: "doc.text.magnifyingglass") {
                        presentsDetails = true
                    }
                    .font(.caption.weight(.semibold))

                    Spacer(minLength: 8)

                    Label(validityLabel, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .sheet(isPresented: $presentsDetails) {
            WorkDetailView(work: work)
        }
    }

    private var validityLabel: String {
        let start = LondonRailDate.formatted(work.startDate, dateFormat: "EEE d MMM")
        let end = LondonRailDate.formatted(work.endDate, dateFormat: "EEE d MMM")
        return LondonRailDate.calendar.isDate(work.startDate, inSameDayAs: work.endDate)
            ? start
            : "\(start) – \(end)"
    }
}

private struct DisruptionDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let disruption: ResolvedDisruption

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LineBadge(lineID: disruption.lineID)

                    Label(disruption.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text(disruption.reason)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Label(disruption.confidence.userDescription, systemImage: "map")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Disruption details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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

                ForEach(TubeLineID.allCases.filter(\.supportsEstimatedTrains)) { lineID in
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
