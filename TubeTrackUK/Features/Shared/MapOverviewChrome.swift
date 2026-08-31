import SwiftUI

struct MapOverviewHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var disruptionsExpanded: Bool
    @Binding var zoomedDisruptionsExpanded: Bool
    let overviewOpacity: Double
    let compactForZoom: Bool
    let onSelectDisruption: () -> Void

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
            if usesCompactTopRow {
                HStack(spacing: 8) {
                    MapDisruptionOverviewCard(
                        expanded: effectiveExpanded,
                        headlineOnly: true,
                        compactHeadline: true,
                        onSelectDisruption: onSelectDisruption
                    )
                    .layoutPriority(1)

                    MapHeaderControls()
                }
            } else {
                HStack(spacing: 8) {
                    if !compactForZoom {
                        Text("TubeTrack UK")
                            .font(.appLargeTitle(.bold))
                            .tracking(-0.7)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .layoutPriority(1)
                            .opacity(overviewOpacity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityLabel("TubeTrack UK")
                    }

                    Spacer(minLength: 4)

                    MapHeaderControls()
                }
                .frame(minHeight: MapDockMetrics.controlSize)

                MapDisruptionOverviewCard(
                    expanded: effectiveExpanded,
                    headlineOnly: compactForZoom && !zoomedDisruptionsExpanded,
                    compactHeadline: false,
                    onSelectDisruption: onSelectDisruption
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var usesCompactTopRow: Bool {
        compactForZoom
            && !effectiveExpanded.wrappedValue
            && !dynamicTypeSize.isAccessibilitySize
    }
}

struct MapDisruptionOverviewCard: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var expanded: Bool
    let headlineOnly: Bool
    let compactHeadline: Bool
    let onSelectDisruption: () -> Void

    private var lineGroups: MapDisruptionLineGroups {
        MapDisruptionLineGroups(disruptions: appState.visibleDisruptions)
    }

    private var lineEntries: [ResolvedDisruption] {
        lineGroups.all
    }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                headlineRow
            } else {
                Button {
                    expanded = true
                } label: {
                    VStack(spacing: 0) {
                        headlineRow
                        if !headlineOnly {
                            collapsedLinePills
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(.rect)
                .accessibilityHint("Shows current disruptions")
            }

            if !headlineOnly, expanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: compactHeadline ? 18 : 24)
        )
        .animation(
            reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.12),
            value: expanded
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: headlineOnly)
        .accessibilityElement(children: .contain)
    }

    private var headlineRow: some View {
        HStack(spacing: compactHeadline ? 8 : 12) {
            Image(systemName: headlineSymbol)
                    .font(
                        compactHeadline
                            ? .appSubheadline(.bold)
                            : .appHeadline(.bold)
                    )
                    .foregroundStyle(headlineColor)
                    .frame(
                        width: compactHeadline ? 32 : 40,
                        height: compactHeadline ? 32 : 40
                    )
                    .background(headlineColor.opacity(0.13), in: .circle)
                    .symbolEffect(.pulse, isActive: appState.isRefreshingDisruptionData)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(
                            compactHeadline
                                ? .appSubheadline(.bold)
                                : .appHeadline(.bold)
                        )
                        .foregroundStyle(.primary)
                        .lineLimit(compactHeadline ? 1 : nil)
                        .minimumScaleFactor(compactHeadline ? 0.78 : 1)
                    if expanded {
                        Text("Live status and planned engineering work")
                            .font(.appCaption())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 6)

                if expanded {
                    DisruptionDateMenu(compact: true)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.appCaption(.bold))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: compactHeadline ? 24 : 32,
                            height: compactHeadline ? 32 : 32
                        )
                }
        }
        .padding(.horizontal, compactHeadline ? 10 : 14)
        .padding(.vertical, compactHeadline ? 6 : 12)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }

    private var collapsedLinePills: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 14)

            if lineEntries.isEmpty {
                Text(emptyMessage)
                    .font(.appCaption())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                HStack(spacing: collapsedPillSpacing) {
                    ForEach(lineEntries) { disruption in
                        Capsule()
                            .fill(Color.tubeLine(disruption.lineID))
                            .overlay {
                                Capsule()
                                    .stroke(.primary.opacity(0.16), lineWidth: 0.5)
                            }
                            .frame(width: collapsedPillWidth, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(affectedLinesAccessibilityLabel)
            }
        }
    }

    private var collapsedPillSpacing: CGFloat {
        lineEntries.count > 12 ? 4 : 6
    }

    private var collapsedPillWidth: CGFloat {
        guard !lineEntries.isEmpty else { return 0 }
        let availableWidth: CGFloat = 292
        let gaps = CGFloat(max(0, lineEntries.count - 1)) * collapsedPillSpacing
        return min(24, max(10, (availableWidth - gaps) / CGFloat(lineEntries.count)))
    }

    private var affectedLinesAccessibilityLabel: String {
        "Affected lines: " + lineEntries.map(\.lineID.displayName).joined(separator: ", ")
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
                            ForEach(lineGroups.majorIssues) { disruption in
                                expandedRow(disruption)
                            }
                            if !lineGroups.majorIssues.isEmpty,
                               !lineGroups.minorDelays.isEmpty {
                                minorDelaySeparator
                            }
                            ForEach(lineGroups.minorDelays) { disruption in
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
                    .font(.appSubheadline(.semibold))
                    .foregroundStyle(Color.tubeBlue)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }

    private var minorDelaySeparator: some View {
        HStack(spacing: 8) {
            Divider()
            Text("Minor delays")
                .font(.appCaption2(.medium))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Divider()
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minor delays")
    }

    private func expandedRow(_ disruption: ResolvedDisruption) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.35)) {
                onSelectDisruption()
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
                            .font(.appSubheadline(.bold))
                        Spacer(minLength: 8)
                        Text(disruption.title)
                            .font(.appCaption(.semibold))
                            .foregroundStyle(disruption.isMinorDelay ? .orange : .red)
                            .lineLimit(1)
                    }
                    Text(disruption.reason)
                        .font(.appCaption())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Image(systemName: "chevron.right")
                    .font(.appCaption(.bold))
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
            return "All supported London rail lines are reporting normally."
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
                    .font(.appTitle3(.medium))
                    .foregroundStyle(Color.tubeBlue)
            }
            .frame(width: 43, height: 43)

            VStack(alignment: .leading, spacing: 3) {
                Text("Pinch to explore the network")
                    .font(.appSubheadline(.bold))
                    .foregroundStyle(Color.tubeBlue)
                Text("Tap any station for departures and status")
                    .font(.appCaption())
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
    private static let statHeight: CGFloat = 82

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
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            ForEach(Array(visibleFilters.enumerated()), id: \.element) {
                index, filter in
                if index > 0 { divider }
                stat(filter)
            }

            if !appState.isViewingLiveStatus {
                divider
                returnToTodayButton
            }
        }
        .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? accessibilityWidth : 0)
    }

    private var visibleFilters: [MapNetworkStatFilter] {
        if appState.isViewingLiveStatus {
            return [.lines, .goodService, .minorDelays, .majorIssues, .closed]
        }
        return [.lines, .goodService, .disrupted]
    }

    private var accessibilityWidth: CGFloat {
        CGFloat(visibleFilters.count + (appState.isViewingLiveStatus ? 0 : 1)) * 108
    }

    private func stat(_ filter: MapNetworkStatFilter) -> some View {
        let selected = appState.selectedMapNetworkStat == filter
        let value = appState.mapNetworkStatusSummary.count(for: filter)

        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) {
                appState.toggleMapNetworkStat(filter)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: filter.symbol)
                    .font(.appCaption2(.bold))
                    .foregroundStyle(filter.color)
                    .frame(height: 12)
                Text(value, format: .number)
                    .font(.appTitle3(.bold).monospacedDigit())
                Text(filter.title)
                    .font(.appCaption2())
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 28, alignment: .top)
            }
            .offset(y: filter == .lines ? 4 : 0)
            .padding(.horizontal, 4)
            .frame(
                maxWidth: .infinity,
                minHeight: Self.statHeight,
                maxHeight: Self.statHeight
            )
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(filter.color.opacity(selected ? 0.13 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(filter.color.opacity(selected ? 0.42 : 0), lineWidth: 1)
                    }
                    .padding(4)
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

    private var returnToTodayButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) {
                appState.setDisruptionDateSelection(.today)
            }
        } label: {
            VStack(spacing: 5) {
                Label("Return to today", systemImage: "calendar.badge.clock")
                    .labelStyle(.iconOnly)
                    .font(.appTitle3(.semibold))
                    .foregroundStyle(Color.tubeBlue)
                Text("Today")
                    .font(.appCaption2(.semibold))
                    .foregroundStyle(Color.tubeBlue)
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.tubeBlue.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(Color.tubeBlue.opacity(0.18), lineWidth: 1)
                    }
                    .padding(.horizontal, 3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to today")
        .accessibilityHint("Shows current service status and restores the live statistics")
    }

    private var divider: some View {
        Divider()
            .frame(height: Self.statHeight - 20)
    }
}
