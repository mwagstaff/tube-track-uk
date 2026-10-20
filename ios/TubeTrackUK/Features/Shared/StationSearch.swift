import SwiftUI

enum StationSearch {
    /// Immutable, graph-scoped data shared by both pickers and all subsequent
    /// presentations. Graph loading prepares it off the main actor.
    final class Index: Sendable {
        private struct Entry: Sendable {
            let station: TubeStation
            let name: String
            let words: [Substring]
            let aliases: [String]
            let searchableText: String
        }

        private let entries: [Entry]
        private let allStations: [TubeStation]
        private let hubStations: [TubeStation]
        private let stationsByID: [String: TubeStation]
        private let hubOffsets: [String: Int]
        private let linesByHub: [String: [TubeLineID]]

        init(stations: [TubeStation]) {
            let sorted = stations.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            allStations = sorted
            entries = sorted.map { station in
                let name = StationSearch.normalized(station.name)
                let aliases = station.searchAliases.map(StationSearch.normalized)
                return Entry(station: station, name: name, words: name.split(separator: " "),
                             aliases: aliases, searchableText: ([name] + aliases).joined(separator: " "))
            }
            stationsByID = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
            var hubs: [TubeStation] = []
            var offsets: [String: Int] = [:]
            var lines: [String: Set<TubeLineID>] = [:]
            for station in sorted {
                let hub = station.hubID ?? station.id
                if offsets[hub] == nil {
                    offsets[hub] = hubs.count
                    hubs.append(station)
                }
                lines[hub, default: []].formUnion(station.lineIDs)
            }
            hubStations = hubs
            hubOffsets = offsets
            linesByHub = lines.mapValues { $0.sorted { $0.displayName < $1.displayName } }
        }

        func lineIDs(at station: TubeStation) -> [TubeLineID] {
            linesByHub[station.hubID ?? station.id] ?? station.lineIDs
        }

        func suggestions(
            matching query: String,
            selectedStationID: String? = nil,
            deduplicatesHubs: Bool = true,
            includesNationalRail: Bool = true,
            limit: Int? = nil
        ) -> [TubeStation] {
            let query = StationSearch.normalized(query)
            let ranked: [TubeStation]
            if query.isEmpty {
                // The initial list needs no normalization, ranking or hub scan.
                var cached = deduplicatesHubs ? hubStations : allStations
                if deduplicatesHubs, let selectedStationID,
                   let station = stationsByID[selectedStationID],
                   let offset = hubOffsets[station.hubID ?? station.id] {
                    cached[offset] = station
                }
                if !includesNationalRail {
                    cached = cached.filter { !NationalRailMap.isExclusiveStation($0.id) }
                }
                guard let limit else { return cached }
                return Array(cached.prefix(max(0, limit)))
            } else {
                let tokens = query.split(separator: " ").map(String.init)
                // Entries are already alphabetized. Buckets preserve that order
                // without another localized sort on every keystroke.
                var buckets = Array(repeating: [TubeStation](), count: 7)
                for entry in entries {
                    guard tokens.allSatisfy(entry.searchableText.contains) else { continue }
                    let score: Int
                    if entry.name == query { score = 0 }
                    else if entry.name.hasPrefix(query) { score = 1 }
                    else if entry.words.contains(where: { $0.hasPrefix(query) }) { score = 2 }
                    else if entry.name.contains(query) { score = 3 }
                    else if entry.aliases.contains(query) { score = 4 }
                    else if entry.aliases.contains(where: { $0.hasPrefix(query) }) { score = 5 }
                    else { score = 6 }
                    buckets[score].append(entry.station)
                }
                ranked = buckets.flatMap { $0 }
            }

            var matches: [TubeStation] = []
            var offsets: [String: Int] = [:]
            // Filter before applying the result limit so excluded rail stations
            // cannot crowd eligible stations out of the first 40 results.
            for station in ranked {
                guard includesNationalRail || !NationalRailMap.isExclusiveStation(station.id) else { continue }
                let hub = station.hubID ?? station.id
                if deduplicatesHubs, let offset = offsets[hub] {
                    if station.id == selectedStationID { matches[offset] = station }
                } else {
                    offsets[hub] = matches.count
                    matches.append(station)
                }
            }
            guard let limit else { return matches }
            return Array(matches.prefix(max(0, limit)))
        }
    }

    static func suggestions(
        in stations: [TubeStation], matching query: String, limit: Int? = nil
    ) -> [TubeStation] {
        Index(stations: stations).suggestions(matching: query, deduplicatesHubs: false, limit: limit)
    }

    static func suggestions(
        in graph: TubeGraph, matching query: String,
        selectedStationID: String? = nil, limit: Int? = nil
    ) -> [TubeStation] {
        graph.stationSearchIndex.suggestions(
            matching: query, selectedStationID: selectedStationID, limit: limit
        )
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

struct StationSearchSheet: View {
    let graph: TubeGraph
    let selectedStationID: String?
    var title: String = "Find a station"
    var selectionHint: String = "Selects and focuses this station on the map"
    var includesNationalRail: Bool = true
    var onClose: (() -> Void)? = nil
    let onSelect: (TubeStation) -> Void

    var body: some View {
        StationPickerSheet(title: title, selectedID: selectedStationID,
                           selectionHint: selectionHint, onClose: onClose, results: { query in
            graph.stationSearchIndex.suggestions(
                matching: query, selectedStationID: selectedStationID,
                includesNationalRail: includesNationalRail,
                limit: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : 40
            ).map { station in
                StationPickerEntry(id: station.id, name: station.name,
                    lineIDs: graph.stationSearchIndex.lineIDs(at: station),
                    subtitle: NationalRailMap.isExclusiveStation(station.id) ? "National Rail" : nil)
            }
        }, onSelect: { entry in
            if let station = graph.stationsByID[entry.id] { onSelect(station) }
        })
    }
}

struct StationPickerEntry: Identifiable {
    let id: String
    let name: String
    let lineIDs: [TubeLineID]
    var subtitle: String? = nil
}

/// Shared presentation for journey stations and departure-board destinations.
struct StationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchIsPresented = true
    let title: String
    let selectedID: String?
    let selectionHint: String
    var searchPrompt = "Station name"
    var onClose: (() -> Void)? = nil
    let results: (String) -> [StationPickerEntry]
    let onSelect: (StationPickerEntry) -> Void

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        let suggestions = results(query)
        NavigationStack {
            Group {
                if suggestions.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(suggestions) { station in
                        Button {
                            onSelect(station)
                            close()
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(station.name)
                                        .font(.appBody(.semibold))
                                        .foregroundStyle(.primary)
                                    StationLineLegend(lineIDs: station.lineIDs)
                                    if let subtitle = station.subtitle {
                                        if subtitle == "National Rail" {
                                            Label { Text(subtitle) } icon: { NationalRailMark().frame(width: 18, height: 12) }
                                                .font(.appCaption())
                                        } else {
                                            Text(subtitle).font(.appCaption()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer(minLength: 8)
                                if selectedID == station.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(station.name)
                        .accessibilityValue((station.lineIDs.map(\.displayName) + [station.subtitle].compactMap { $0 }).joined(separator: ", "))
                        .accessibilityHint(selectionHint)
                        .accessibilityAddTraits(selectedID == station.id ? .isSelected : [])
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $searchIsPresented,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } }
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
                        .font(.appCaption())
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

#Preview("Station picker") {
    if let graph = try? TubeGraph.bundled().includingNationalRailStations() {
        StationSearchSheet(graph: graph, selectedStationID: nil, title: "Starting station") { _ in }
    }
}

#Preview("Station picker · Large text, dark") {
    if let graph = try? TubeGraph.bundled().includingNationalRailStations() {
        StationSearchSheet(graph: graph, selectedStationID: "940GZZCRWMB", title: "Destination") { _ in }
            .environment(\.dynamicTypeSize, .accessibility3)
            .preferredColorScheme(.dark)
    }
}
