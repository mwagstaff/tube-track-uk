import SwiftUI

struct MapOverviewHeader: View {
    @Binding var disruptionsExpanded: Bool
    @Binding var zoomedDisruptionsExpanded: Bool
    let overviewOpacity: Double
    let compactForZoom: Bool

    private var effectiveExpanded: Binding<Bool> {
        Binding(
            get: {
                compactForZoom ? zoomedDisruptionsExpanded : disruptionsExpanded
            },
            set: { newValue in
                if compactForZoom {
                    zoomedDisruptionsExpanded = newValue
                } else {
                    disruptionsExpanded = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compactForZoom {
                HStack(spacing: 11) {
                    TubeTrackMark(compact: true)
                    Text("TubeTrack UK")
                        .font(.largeTitle.weight(.bold))
                        .tracking(-0.7)
                }
                .opacity(overviewOpacity)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("TubeTrack UK")
            }

            MapDisruptionOverviewCard(
                expanded: effectiveExpanded,
                headlineOnly: compactForZoom && !zoomedDisruptionsExpanded
            )
            .opacity(
                zoomedDisruptionsExpanded ? 1 : max(0.5, overviewOpacity)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

struct MapDisruptionOverviewCard: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var expanded: Bool
    let headlineOnly: Bool

    private var lineEntries: [ResolvedDisruption] {
        Dictionary(
            grouping: appState.visibleDisruptions.filter(\.lineID.isUnderground),
            by: \.lineID
        )
            .compactMap { _, disruptions in disruptions.first }
            .sorted {
                $0.lineID.displayName.localizedStandardCompare($1.lineID.displayName)
                    == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            if headlineOnly {
                Button {
                    expanded = true
                } label: {
                    headlineRow
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows current disruptions")
            } else {
                headlineRow
            }

            if !headlineOnly, expanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !headlineOnly {
                collapsedContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .animation(
            reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.12),
            value: expanded
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: headlineOnly)
        .accessibilityElement(children: .contain)
    }

    private var headlineRow: some View {
        HStack(spacing: 12) {
                Image(systemName: headlineSymbol)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(headlineColor)
                    .frame(width: 40, height: 40)
                    .background(headlineColor.opacity(0.13), in: .circle)
                    .symbolEffect(.pulse, isActive: appState.isRefreshingDisruptionData)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    if expanded {
                        Text("Live status and planned engineering work")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 6)

                if expanded {
                    DisruptionDateMenu(compact: true)
                } else if headlineOnly {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    private var collapsedContent: some View {
        VStack(spacing: 0) {
            if lineEntries.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 11)
            } else {
                VStack(spacing: 9) {
                    ForEach(lineEntries.prefix(2)) { disruption in
                        compactRow(disruption)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider()
                .padding(.horizontal, 14)

            Button {
                expanded = true
            } label: {
                HStack(spacing: 7) {
                    Text("View all disruptions")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Color.tubeBlue)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            if !appState.isViewingLiveStatus {
                DisruptionTimeFilterBar()
                    .padding(.horizontal, 14)
            }

            Divider()
                .padding(.horizontal, 14)

            Group {
                if lineEntries.isEmpty {
                    ContentUnavailableView(
                        "No disruptions",
                        systemImage: "checkmark.circle",
                        description: Text(emptyMessage)
                    )
                    .frame(maxHeight: 140)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(lineEntries) { disruption in
                                expandedRow(disruption)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: 218)
                }
            }

            Divider()
                .padding(.horizontal, 14)

            Button {
                expanded = false
            } label: {
                Label("Show less", systemImage: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.tubeBlue)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }

    private func compactRow(_ disruption: ResolvedDisruption) -> some View {
        HStack(spacing: 11) {
            Capsule()
                .fill(Color.tubeLine(disruption.lineID))
                .frame(width: 38, height: 5)
            Text(disruption.lineID.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("•")
                .foregroundStyle(.tertiary)
            Text(disruption.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func expandedRow(_ disruption: ResolvedDisruption) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.35)) {
                appState.select(disruption: disruption)
                expanded = false
            }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.tubeLine(disruption.lineID))
                    .frame(width: 5)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(disruption.lineID.displayName)
                            .font(.subheadline.weight(.bold))
                        Spacer(minLength: 8)
                        Text(disruption.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Text(disruption.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(.primary.opacity(0.055), in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Highlights the affected line on the map")
    }

    private var headline: String {
        let count = lineEntries.count
        if appState.isRefreshingDisruptionData && appState.visibleDisruptions.isEmpty {
            return appState.isViewingLiveStatus
                ? "Updating network status"
                : "Loading planned disruptions"
        }
        if appState.isViewingLiveStatus {
            return count == 0
                ? "No disruptions currently"
                : "\(count) disruption\(count == 1 ? "" : "s") currently"
        }
        let date = LondonRailDate.formatted(
            appState.selectedDisruptionDate,
            dateFormat: "EEE d MMM"
        )
        return count == 0
            ? "No disruptions · \(date)"
            : "\(count) disruption\(count == 1 ? "" : "s") · \(date)"
    }

    private var emptyMessage: String {
        if appState.isViewingLiveStatus {
            return "All Underground lines are reporting normally."
        }
        return "No planned work matches the selected date and times."
    }

    private var headlineSymbol: String {
        lineEntries.isEmpty
            ? "checkmark.circle.fill"
            : "exclamationmark.triangle.fill"
    }

    private var headlineColor: Color {
        lineEntries.isEmpty ? .green : .red
    }
}

struct MapExploreHint: View {
    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .stroke(Color.tubeBlue.opacity(0.18), lineWidth: 1.5)
                Image(systemName: "hand.pinch")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.tubeBlue)
            }
            .frame(width: 43, height: 43)

            VStack(alignment: .leading, spacing: 3) {
                Text("Pinch to explore the network")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.tubeBlue)
                Text("Tap any station for departures and status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 340)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

struct MapNetworkStatsCard: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    stats
                }
                .scrollIndicators(.hidden)
            } else {
                stats
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            ForEach(Array(MapNetworkStatFilter.allCases.enumerated()), id: \.element) {
                index, filter in
                if index > 0 { divider }
                stat(filter)
            }
        }
        .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 540 : 0)
    }

    private func stat(_ filter: MapNetworkStatFilter) -> some View {
        let selected = appState.selectedMapNetworkStat == filter
        let value = appState.mapNetworkStatusSummary.count(for: filter)

        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) {
                appState.toggleMapNetworkStat(filter)
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: filter.symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(filter.color)
                    .frame(height: 12)
                Text(value, format: .number)
                    .font(.title3.weight(.bold).monospacedDigit())
                Text(filter.title)
                    .font(.caption2)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(filter.color.opacity(selected ? 0.13 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(filter.color.opacity(selected ? 0.42 : 0), lineWidth: 1)
                    }
                    .padding(.horizontal, 3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(filter.title), \(value)")
        .accessibilityHint(selected ? "Shows all lines" : "Highlights matching lines on the map")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var divider: some View {
        Divider()
            .frame(height: 52)
    }
}
