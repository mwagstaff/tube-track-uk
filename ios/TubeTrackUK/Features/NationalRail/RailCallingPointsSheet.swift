import SwiftUI
import TubeTrackCore

struct SelectedRailDeparture: Identifiable {
    let arrival: TfLArrivalPrediction
    var id: String { arrival.id }
}

@MainActor @Observable
final class RailCallingPointsStore {
    var details: RailCallingPoints?
    var failed = false

    func load(_ arrival: TfLArrivalPrediction) async {
        failed = false
        do {
            let value = try await RailCallingPointsService.shared.fetch(for: arrival)
            try Task.checkCancellation()
            details = value
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

struct RailCallingPointsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = RailCallingPointsStore()
    @State private var attempt = 0
    let arrival: TfLArrivalPrediction

    var body: some View {
        NavigationStack {
            Group {
                if let details = store.details {
                    RailCallingPointsList(arrival: arrival, details: details)
                } else if store.failed {
                    ContentUnavailableView {
                        Label("Calling points unavailable", systemImage: "train.side.front.car")
                    } description: {
                        Text("We couldn’t load the stops for this train. Check your connection and try again.")
                    } actions: {
                        Button("Try again") { attempt += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("Loading calling points…")
                }
            }
            .navigationTitle("Calling points")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: attempt) { await store.load(arrival) }
        }
        .foregroundStyle(.primary)
        .tint(Color.departureAccent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct RailCallingPointsList: View {
    let arrival: TfLArrivalPrediction
    let details: RailCallingPoints

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("To \(StationDepartureMetadata.destinationLabel(for: arrival))")
                        .font(.appHeadline())
                    Text(arrival.operatorName ?? "Thameslink").font(.appSubheadline())
                    if arrival.isCancelled || details.isCancelled == true {
                        Label("Train cancelled", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Text("Scheduled and live times shown in UK local time.")
            }
            Section("Departs from") { point(details.boardingPoint) }
            let groups = details.subsequentCallingPoints ?? []
            if groups.isEmpty {
                Section {
                    Text("No onward calling points are available for this train.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                Section(groups.count > 1 ? "Calling at · Part \(index + 1)" : "Calling at") {
                    if group.serviceChangeRequired == true {
                        Label("Change trains for these stops", systemImage: "arrow.triangle.swap")
                    }
                    if group.assocIsCancelled == true {
                        Label("This portion is cancelled", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    ForEach(Array(group.callingPoint.enumerated()), id: \.offset) { _, call in
                        point(call)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func point(_ call: RailCallingPoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(call.locationName).font(.appBody(.medium))
                .strikethrough(call.isCancelled == true)
            Text(call.timing).font(.appSubheadline()).monospacedDigit()
                .foregroundStyle(call.isCancelled == true ? Color.red : .secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
