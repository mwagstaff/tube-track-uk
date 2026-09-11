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

    private var isLoadingTfLDisruptions: Bool {
        appState.isViewingLiveStatus && appState.isLoadingInitialStatus && !appState.isOffline
    }

    private var hasNoSavedDisruptionData: Bool {
        guard appState.isOffline else { return false }
        if appState.isViewingLiveStatus { return appState.statusUpdatedAt == nil }
        return hasIncompleteSavedWorks && lineEntries.isEmpty
    }

    private var hasIncompleteSavedWorks: Bool {
        appState.isOffline && !appState.isViewingLiveStatus
            && !appState.hasSavedWorks(for: appState.selectedDisruptionDate)
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

            if appState.isOffline {
                OfflineStatusMessage(
                    updatedAt: appState.disruptionDataUpdatedAt,
                    isWorks: !appState.isViewingLiveStatus
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
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
            headlineStatusIcon

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
                    Text(
                        appState.isOffline
                            ? "Saved status and planned engineering work"
                            : "Live status and planned engineering work"
                    )
                        .font(.appCaption())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            if expanded {
                DisruptionDateMenu(compact: true, opensPickerDirectly: true)
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

    private var headlineStatusIcon: some View {
        Group {
            if isLoadingTfLDisruptions {
                ProgressView()
                    .controlSize(compactHeadline ? .small : .regular)
                    .tint(.blue)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: headlineSymbol)
                    .font(
                        compactHeadline
                            ? .appSubheadline(.bold)
                            : .appHeadline(.bold)
                    )
                    .foregroundStyle(headlineColor)
                    .symbolEffect(
                        .pulse,
                        isActive: appState.isRefreshingDisruptionData && !appState.isOffline
                    )
            }
        }
        .frame(
            width: compactHeadline ? 32 : 40,
            height: compactHeadline ? 32 : 40
        )
        .background(headlineColor.opacity(0.13), in: .circle)
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
                HStack(alignment: .bottom, spacing: collapsedCategorySpacing) {
                    if !lineGroups.majorIssues.isEmpty {
                        collapsedPillGroup(
                            title: "Major",
                            disruptions: lineGroups.majorIssues
                        )
                    }
                    if !lineGroups.minorDelays.isEmpty {
                        collapsedPillGroup(
                            title: "Minor",
                            disruptions: lineGroups.minorDelays
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .padding(.horizontal, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(affectedLinesAccessibilityLabel)
            }
        }
    }

    private func collapsedPillGroup(
        title: String,
        disruptions: [ResolvedDisruption]
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.appCaption2(.medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .accessibilityHidden(true)

            HStack(spacing: collapsedPillSpacing) {
                ForEach(disruptions) { disruption in
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
        }
    }

    private var collapsedCategorySpacing: CGFloat {
        lineGroups.majorIssues.isEmpty || lineGroups.minorDelays.isEmpty ? 0 : 12
    }

    private var collapsedPillSpacing: CGFloat {
        lineEntries.count > 12 ? 4 : 6
    }

    private var collapsedPillWidth: CGFloat {
        guard !lineEntries.isEmpty else { return 0 }
        let availableWidth: CGFloat = 292
        let gaps = CGFloat(
            max(0, lineGroups.majorIssues.count - 1)
                + max(0, lineGroups.minorDelays.count - 1)
        ) * collapsedPillSpacing + collapsedCategorySpacing
        return min(24, max(10, (availableWidth - gaps) / CGFloat(lineEntries.count)))
    }

    private var affectedLinesAccessibilityLabel: String {
        var groups: [String] = []
        if !lineGroups.majorIssues.isEmpty {
            groups.append(
                "Major: "
                    + lineGroups.majorIssues.map(\.lineID.displayName).joined(separator: ", ")
            )
        }
        if !lineGroups.minorDelays.isEmpty {
            groups.append(
                "Minor: "
                    + lineGroups.minorDelays.map(\.lineID.displayName).joined(separator: ", ")
            )
        }
        return "Affected lines. " + groups.joined(separator: ". ")
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            if hasIncompleteSavedWorks {
                Label(
                    "This date hasn’t been fully saved. Connect to check for more work.",
                    systemImage: "wifi.slash"
                )
                .font(.appCaption())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            }
            if !appState.isViewingLiveStatus {
                DisruptionTimeFilterBar(fillsAvailableWidth: true)
                    .padding(.horizontal, 14)
            }

            MapDisruptionQuickDateFilter(
                selection: appState.disruptionDateSelection,
                onSelect: appState.setDisruptionDateSelection(_:)
            )
            .padding(.horizontal, 12)

            Divider()
                .padding(.horizontal, 14)

            Group {
                if isLoadingTfLDisruptions {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.blue)
                        Text("TfL disruption data is still loading.")
                            .font(.appCaption())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                } else if lineEntries.isEmpty {
                    ContentUnavailableView(
                        appState.isOffline ? "No saved disruptions" : "No disruptions",
                        systemImage: hasNoSavedDisruptionData ? "wifi.slash" : "checkmark.circle",
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
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                    onSelectDisruption()
                    appState.highlightAllDisruptionsOnMap()
                    expanded = false
                }
            } label: {
                Label("Highlight disrupted lines", systemImage: AppTab.works.symbol)
                    .font(.appSubheadline(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.orange).interactive(), in: .capsule)
            .padding(.horizontal, 12)
            .disabled(lineEntries.isEmpty)
            .opacity(lineEntries.isEmpty ? 0.5 : 1)
            .accessibilityHint("Collapses this panel and fits all affected sections on the map")

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
        if hasNoSavedDisruptionData { return "No saved disruptions" }
        if isLoadingTfLDisruptions {
            return "Loading disruptions from TfL"
        }
        if !appState.isViewingLiveStatus,
           !appState.isOffline,
           appState.isRefreshingDisruptionData,
           appState.visibleDisruptions.isEmpty {
            return "Loading planned disruptions"
        }
        if appState.isViewingLiveStatus {
            if appState.isOffline {
                return count == 0
                    ? "No disruptions in saved update"
                    : "\(count) saved disruption\(count == 1 ? "" : "s")"
            }
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
        if hasNoSavedDisruptionData {
            return "Connect to the internet to check for disruptions."
        }
        if appState.isOffline {
            return appState.isViewingLiveStatus
                ? "No disruptions were reported in the last saved update."
                : "No saved work matches the selected date and times."
        }
        if appState.isViewingLiveStatus {
            if isLoadingTfLDisruptions {
                return "Loading disruption data from TfL..."
            }
            return "All lines are reporting normally... For now."
        }
        return "No planned work matches the selected date and times."
    }

    private var headlineSymbol: String {
        if hasNoSavedDisruptionData { return "wifi.slash" }
        return lineEntries.isEmpty
            ? "checkmark.circle.fill"
            : "exclamationmark.triangle.fill"
    }

    private var headlineColor: Color {
        if hasNoSavedDisruptionData { return .secondary }
        if isLoadingTfLDisruptions { return .blue }
        return lineEntries.isEmpty ? .green : .red
    }
}

private struct MapDisruptionQuickDate: Identifiable {
    let title: String
    let selection: DisruptionDateSelection

    var id: String { title }
}

private struct MapDisruptionQuickDateFilter: View {
    let selection: DisruptionDateSelection
    let onSelect: (DisruptionDateSelection) -> Void

    private var quickDates: [MapDisruptionQuickDate] {
        [
            MapDisruptionQuickDate(title: "Today", selection: .today),
            MapDisruptionQuickDate(title: "Tomorrow", selection: .tomorrow),
            MapDisruptionQuickDate(title: "Saturday", selection: .saturday),
            MapDisruptionQuickDate(title: "Sunday", selection: .sunday),
        ]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(quickDates) { quickDate in
                quickDateButton(quickDate)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func quickDateButton(_ quickDate: MapDisruptionQuickDate) -> some View {
        let selected = selection == quickDate.selection
        let date = quickDate.selection.date()

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                onSelect(quickDate.selection)
            }
        } label: {
            VStack(spacing: 1) {
                Text(quickDate.title)
                    .font(.appCaption(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(LondonRailDate.formatted(date, dateFormat: "d MMM"))
                    .font(.appCaption2())
                    .opacity(selected ? 0.85 : 0.65)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(selected ? Color.tubeBlue : Color.secondary.opacity(0.13))
            }
            .clipShape(Capsule(style: .continuous))
            .contentShape(.capsule)
            .foregroundStyle(selected ? .white : .primary)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(quickDate.title), \(LondonRailDate.formatted(date, dateFormat: "EEEE d MMMM yyyy"))"
        )
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    // More negative moves the selection boundary up; positive moves it down.
    private static let selectionBoundaryYOffset: CGFloat = -12

    @Environment(TubeAppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onAction: (MapActionNotice) -> Void = { _ in }

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
        CGFloat(visibleFilters.count) * 108
    }

    private func stat(_ filter: MapNetworkStatFilter) -> some View {
        let selected = appState.selectedMapNetworkStat == filter
        let value = appState.mapNetworkStatusSummary.count(for: filter)
        let isUnavailable = hasUnavailableOfflineCount(for: filter, value: value)

        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) {
                if let disruptionScope = MapDisruptionHighlightScope(filter: filter),
                   !selected {
                    onAction(MapActionNotice(
                        message: disruptionScope.noticeMessage,
                        symbol: AppTab.works.symbol
                    ))
                }
                appState.toggleMapNetworkStat(filter)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: filter.symbol)
                    .font(.appCaption2(.bold))
                    .foregroundStyle(filter.color)
                    .frame(height: 12)
                Group {
                    if isUnavailable {
                        Text("—")
                    } else {
                        Text(value, format: .number)
                    }
                }
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
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .offset(y: Self.selectionBoundaryYOffset)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(filter.title), \(isUnavailable ? "No saved data" : String(value))")
        .requiresNetwork(
            isUnavailable,
            onlineHint: statAccessibilityHint(for: filter, selected: selected)
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func hasUnavailableOfflineCount(for filter: MapNetworkStatFilter, value: Int) -> Bool {
        guard appState.isOffline, filter != .lines else { return false }
        if appState.isViewingLiveStatus { return appState.statusUpdatedAt == nil }
        guard !appState.hasSavedWorks(for: appState.selectedDisruptionDate) else { return false }
        // Known saved disruptions remain inspectable even when the saved range
        // is incomplete. An absent entry cannot establish good service.
        return filter == .goodService || value == 0
    }

    private func statAccessibilityHint(
        for filter: MapNetworkStatFilter,
        selected: Bool
    ) -> String {
        if selected {
            return "Clears this filter and shows all lines"
        }
        if MapDisruptionHighlightScope(filter: filter) != nil {
            return "Highlights matching affected sections on the map"
        }
        return "Highlights matching lines on the map"
    }

    private var divider: some View {
        Divider()
            .frame(height: Self.statHeight - 20)
    }
}
