import SwiftUI

enum StationSearch {
    static func suggestions(
        in stations: [TubeStation],
        matching query: String,
        limit: Int? = nil
    ) -> [TubeStation] {
        let normalizedQuery = normalized(query)
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)

        let matches = stations.compactMap { station -> (station: TubeStation, score: Int)? in
            let name = normalized(station.name)
            let aliases = station.searchAliases.map(normalized)
            let searchableText = ([name] + aliases).joined(separator: " ")

            guard queryTokens.allSatisfy(searchableText.contains) else { return nil }

            let score: Int
            if normalizedQuery.isEmpty || name == normalizedQuery {
                score = 0
            } else if name.hasPrefix(normalizedQuery) {
                score = 1
            } else if name.split(separator: " ").contains(where: {
                $0.hasPrefix(normalizedQuery)
            }) {
                score = 2
            } else if name.contains(normalizedQuery) {
                score = 3
            } else if aliases.contains(normalizedQuery) {
                score = 4
            } else if aliases.contains(where: { $0.hasPrefix(normalizedQuery) }) {
                score = 5
            } else {
                score = 6
            }
            return (station, score)
        }
        .sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            let nameOrder = $0.station.name.localizedStandardCompare($1.station.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.station.id < $1.station.id
        }
        .map(\.station)

        guard let limit else { return matches }
        return Array(matches.prefix(limit))
    }

    static func suggestions(
        in graph: TubeGraph,
        matching query: String,
        selectedStationID: String? = nil,
        limit: Int? = nil
    ) -> [TubeStation] {
        let ranked = suggestions(in: graph.stations, matching: query)
        var orderedHubIDs: [String] = []
        var representativeByHubID: [String: TubeStation] = [:]

        for station in ranked {
            let hubID = station.hubID ?? station.id
            if representativeByHubID[hubID] == nil {
                orderedHubIDs.append(hubID)
                representativeByHubID[hubID] = station
            }
            if station.id == selectedStationID {
                representativeByHubID[hubID] = station
            }
        }

        let matches = orderedHubIDs.compactMap { representativeByHubID[$0] }
        guard let limit else { return matches }
        return Array(matches.prefix(limit))
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

struct StationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchIsPresented = true

    let graph: TubeGraph
    let selectedStationID: String?
    let onSelect: (TubeStation) -> Void

    private var suggestions: [TubeStation] {
        StationSearch.suggestions(
            in: graph,
            matching: query,
            selectedStationID: selectedStationID,
            limit: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : 40
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if suggestions.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(suggestions) { station in
                        let lineIDs = graph.lineIDs(at: station)
                        Button {
                            onSelect(station)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(station.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    StationLineLegend(lineIDs: lineIDs)
                                }

                                Spacer(minLength: 8)

                                if selectedStationID == station.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(station.name)
                        .accessibilityValue(lineIDs.map(\.displayName).joined(separator: ", "))
                        .accessibilityHint("Selects and focuses this station on the map")
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Find a station")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                isPresented: $searchIsPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Station name"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { searchIsPresented = true }
    }
}

private struct StationLineLegend: View {
    let lineIDs: [TubeLineID]

    var body: some View {
        StationLineFlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(lineIDs) { lineID in
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.tubeLine(lineID))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)

                    Text(lineID.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
    }
}

private struct StationLineFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrangement(for: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrangement(for: subviews, width: bounds.width)
        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func arrangement(for subviews: Subviews, width: CGFloat) -> Arrangement {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            origins.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return Arrangement(
            origins: origins,
            size: CGSize(width: contentWidth, height: y + rowHeight)
        )
    }

    private struct Arrangement {
        let origins: [CGPoint]
        let size: CGSize
    }
}
