import SwiftUI

struct WorkDetailView: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let work: EngineeringWork

    private var affectedStationNames: [String] {
        guard let graph = appState.graph else { return [] }
        return graph.stations
            .filter { work.affectedStationIDs.contains($0.id) }
            .map(\.name)
            .sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 7) {
                        ForEach(work.lineIDs) { LineBadge(lineID: $0) }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(work.title)
                            .font(.title2.bold())
                        Text(work.detail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    GlassPanel {
                        VStack(spacing: 12) {
                            LabeledContent("From", value: work.startDate.formatted(date: .abbreviated, time: .shortened))
                            Divider()
                            LabeledContent("Until", value: work.endDate.formatted(date: .abbreviated, time: .shortened))
                            Divider()
                            LabeledContent("Source", value: work.source.title)
                            Divider()
                            LabeledContent("Map resolution", value: work.confidence.userDescription)
                        }
                        .font(.subheadline)
                    }

                    if !affectedStationNames.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Affected stations").font(.headline)
                            ForEach(affectedStationNames, id: \.self) { name in
                                Label(name, systemImage: "smallcircle.filled.circle")
                                    .font(.subheadline)
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        Button {
                            appState.focus(on: work, in: .map)
                            dismiss()
                        } label: {
                            Label("View on map", systemImage: "map")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            appState.focus(on: work, in: .realWorld)
                            dismiss()
                        } label: {
                            Label("View on real-world map", systemImage: "globe.europe.africa")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Engineering Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
