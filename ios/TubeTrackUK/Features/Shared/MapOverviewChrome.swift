import SwiftUI

struct MapOverviewHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let overviewOpacity: Double
    let compactForZoom: Bool
    let onShowDisruptions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compactForZoom {
                Text("TubeTrack UK")
                    .font(.appLargeTitle(.bold))
                    .tracking(-0.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .opacity(overviewOpacity)
                    .accessibilityAddTraits(.isHeader)
            }
            MapDisruptionOverviewCard(
                headlineOnly: compactForZoom,
                compactHeadline: usesCompactTopRow,
                onExpand: onShowDisruptions
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var usesCompactTopRow: Bool {
        compactForZoom
            && !dynamicTypeSize.isAccessibilitySize
    }
}

struct MapDisruptionOverviewCard: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let headlineOnly: Bool
    let compactHeadline: Bool
    let onExpand: () -> Void

    private var lineGroups: MapDisruptionLineGroups {
        MapDisruptionLineGroups(disruptions: appState.visibleDisruptions)
    }

    private var lineEntries: [ResolvedDisruption] {
        lineGroups.all
    }

    private var disruptionCount: Int { lineEntries.count + appState.cableCar.overviewIssueCount }

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
        Button(action: onExpand) {
            VStack(spacing: 0) {
                headlineRow
                if !headlineOnly {
                    collapsedLinePills
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
            }
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityHint("Opens disruptions full screen")
        .frame(maxWidth: .infinity)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: compactHeadline ? 18 : 24)
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
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.appCaption(.bold))
                .foregroundStyle(.secondary)
                .frame(
                    width: compactHeadline ? 24 : 32,
                    height: 32
                )
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
            if appState.cableCar.isEnabled, appState.cableCar.presentation.kind != .open {
                Label("Cable Car · \(appState.cableCar.presentation.headline)", image: "CableCarIcon")
                    .font(.appCaption(.semibold))
                    .foregroundStyle(appState.cableCar.presentation.isIssue ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
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

    private var headline: String {
        let count = disruptionCount
        if count == 0, appState.cableCar.isOverviewUnconfirmed { return "Cable Car status unconfirmed" }
        if count == 0, hasNoSavedDisruptionData { return "No saved disruptions" }
        if count == 0, isLoadingTfLDisruptions {
            return "Loading disruptions from TfL"
        }
        if !appState.isViewingLiveStatus,
           !appState.isOffline,
           appState.isRefreshingDisruptionData,
           disruptionCount == 0 {
            return "Loading planned disruptions"
        }
        if appState.isViewingLiveStatus {
            return MapDisruptionSummaryText.liveHeadline(
                disruptionCount: count,
                closedLineCount: appState.mapNetworkStatusSummary.closedLineIDs.count
                    + (appState.cableCar.isEnabled && appState.cableCar.presentation.kind == .scheduledClosed ? 1 : 0),
                isOffline: appState.isOffline
            )
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
            return appState.cableCar.isEnabled ? "No rail disruptions reported." : "All lines are reporting normally... For now."
        }
        return "No planned work matches the selected date and times."
    }

    private var headlineSymbol: String {
        if disruptionCount == 0, hasNoSavedDisruptionData { return "wifi.slash" }
        if disruptionCount == 0, appState.cableCar.isOverviewUnconfirmed { return "questionmark.circle" }
        return disruptionCount == 0
            ? "checkmark.circle.fill"
            : "exclamationmark.triangle.fill"
    }

    private var headlineColor: Color {
        if disruptionCount == 0, hasNoSavedDisruptionData { return .secondary }
        if isLoadingTfLDisruptions { return .blue }
        if disruptionCount == 0, appState.cableCar.isOverviewUnconfirmed { return .secondary }
        return disruptionCount == 0 ? .green : .red
    }
}

struct MapDisruptionsScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var lineGroups: MapDisruptionLineGroups {
        MapDisruptionLineGroups(disruptions: appState.visibleDisruptions)
    }

    private var lineEntries: [ResolvedDisruption] {
        lineGroups.all
    }

    private var disruptionCount: Int { lineEntries.count + appState.cableCar.overviewIssueCount }

    private var isLoadingTfLDisruptions: Bool {
        appState.isViewingLiveStatus && appState.isLoadingInitialStatus && !appState.isOffline
    }

    private var hasIncompleteSavedWorks: Bool {
        appState.isOffline && !appState.isViewingLiveStatus
            && !appState.hasSavedWorks(for: appState.selectedDisruptionDate)
    }

    private var hasNoSavedDisruptionData: Bool {
        guard appState.isOffline else { return false }
        if appState.isViewingLiveStatus { return appState.statusUpdatedAt == nil }
        return hasIncompleteSavedWorks && lineEntries.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                statusSummary

                if appState.isOffline {
                    OfflineStatusMessage(
                        updatedAt: appState.disruptionDataUpdatedAt,
                        isWorks: !appState.isViewingLiveStatus
                    )
                    .frame(maxWidth: .infinity)
                }

                filters

                MapNetworkStatsCard(onSelect: { _ in dismiss() })
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)

                Divider()

                disruptionContent

                if appState.cableCar.isEnabled {
                    CableCarStatusRow(onSelect: { dismiss() })
                        .padding(12)
                        .background(.primary.opacity(0.055), in: .rect(cornerRadius: 14))
                }

                actions
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("Disruptions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusSummary: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    statusHeadline
                    DisruptionDateMenu(compact: true, opensPickerDirectly: true)
                }
            } else {
                HStack(spacing: 12) {
                    statusHeadline
                    Spacer(minLength: 8)
                    DisruptionDateMenu(compact: true, opensPickerDirectly: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusHeadline: some View {
        HStack(spacing: 12) {
            Group {
                if isLoadingTfLDisruptions {
                    ProgressView()
                        .tint(.blue)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: headlineSymbol)
                        .font(.appHeadline(.bold))
                        .foregroundStyle(headlineColor)
                        .symbolEffect(
                            .pulse,
                            isActive: appState.isRefreshingDisruptionData && !appState.isOffline
                        )
                }
            }
            .frame(width: 40, height: 40)
            .background(headlineColor.opacity(0.13), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.appHeadline(.bold))
                    .foregroundStyle(.primary)
                if appState.isViewingLiveStatus {
                    Text(
                        appState.isOffline
                            ? "Saved status and planned engineering work"
                            : "Live status and planned engineering work"
                    )
                    .font(.appCaption())
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "Planned works can change. Always check on the day.",
                        systemImage: "info.circle"
                    )
                    .font(.appCaption())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var filters: some View {
        VStack(spacing: 12) {
            if hasIncompleteSavedWorks {
                Label(
                    "This date hasn’t been fully saved. Connect to check for more work.",
                    systemImage: "wifi.slash"
                )
                .font(.appCaption())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !appState.isViewingLiveStatus {
                DisruptionTimeFilterBar(fillsAvailableWidth: true)
            }

            MapDisruptionQuickDateFilter(
                selection: appState.disruptionDateSelection,
                onSelect: appState.setDisruptionDateSelection(_:)
            )
        }
    }

    @ViewBuilder
    private var disruptionContent: some View {
        if isLoadingTfLDisruptions {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.blue)
                Text("TfL disruption data is still loading.")
                    .font(.appCaption())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if lineEntries.isEmpty {
            ContentUnavailableView(
                appState.cableCar.isEnabled
                    ? (appState.isOffline ? "No saved rail disruptions" : "No rail disruptions")
                    : (appState.isOffline ? "No saved disruptions" : "No disruptions"),
                systemImage: hasNoSavedDisruptionData ? "wifi.slash" : "checkmark.circle",
                description: Text(emptyMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(lineGroups.majorIssues) { disruption in
                    disruptionRow(disruption)
                }
                if !lineGroups.majorIssues.isEmpty,
                   !lineGroups.minorDelays.isEmpty {
                    minorDelaySeparator
                }
                ForEach(lineGroups.minorDelays) { disruption in
                    disruptionRow(disruption)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.26)) {
                    if lineEntries.isEmpty, appState.cableCar.overviewIssueCount > 0 {
                        appState.selectCableCar()
                    } else {
                        appState.toggleAllDisruptionsOnMap()
                    }
                }
                dismiss()
            } label: {
                Label(
                    appState.isViewingDisruptedLines
                        ? "Show all lines"
                        : "View disrupted lines",
                    systemImage: appState.isViewingDisruptedLines
                        ? "line.3.horizontal"
                        : "wrench.and.screwdriver"
                )
                    .font(.appSubheadline(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular
                    .tint(appState.isViewingDisruptedLines ? Color.tubeBlue : .orange)
                    .interactive(),
                in: .capsule
            )
            .disabled(disruptionCount == 0 && !appState.isViewingDisruptedLines)
            .opacity(disruptionCount == 0 && !appState.isViewingDisruptedLines ? 0.5 : 1)
            .accessibilityHint(
                appState.isViewingDisruptedLines
                    ? "Returns to the map and shows every line"
                    : "Returns to the map and highlights all affected sections"
            )

            Button {
                dismiss()
                Task { @MainActor in
                    await Task.yield()
                    appState.showsWorks = true
                }
            } label: {
                Label("Engineering works", systemImage: "calendar.badge.exclamationmark")
                    .font(.appSubheadline(.semibold))
                    .foregroundStyle(Color.tubeBlue)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens planned works by date and line")
        }
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
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minor delays")
    }

    private func disruptionRow(_ disruption: ResolvedDisruption) -> some View {
        Button {
            appState.select(disruption: disruption)
            dismiss()
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
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                Image(systemName: "chevron.right")
                    .font(.appCaption(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(.primary.opacity(0.055), in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Returns to the map and highlights the affected line")
    }

    private var headline: String {
        let count = disruptionCount
        if count == 0, appState.cableCar.isOverviewUnconfirmed { return "Cable Car status unconfirmed" }
        if count == 0, hasNoSavedDisruptionData { return "No saved disruptions" }
        if count == 0, isLoadingTfLDisruptions { return "Loading disruptions from TfL" }
        if !appState.isViewingLiveStatus,
           !appState.isOffline,
           appState.isRefreshingDisruptionData,
           disruptionCount == 0 {
            return "Loading planned disruptions"
        }
        if appState.isViewingLiveStatus {
            return MapDisruptionSummaryText.liveHeadline(
                disruptionCount: count,
                closedLineCount: appState.mapNetworkStatusSummary.closedLineIDs.count
                    + (appState.cableCar.isEnabled && appState.cableCar.presentation.kind == .scheduledClosed ? 1 : 0),
                isOffline: appState.isOffline
            )
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
            return appState.cableCar.isEnabled ? "No rail disruptions reported." : "All lines are reporting normally... For now."
        }
        return "No planned work matches the selected date and times."
    }

    private var headlineSymbol: String {
        if disruptionCount == 0, hasNoSavedDisruptionData { return "wifi.slash" }
        if disruptionCount == 0, appState.cableCar.isOverviewUnconfirmed { return "questionmark.circle" }
        return disruptionCount == 0
            ? "checkmark.circle.fill"
            : "exclamationmark.triangle.fill"
    }

    private var headlineColor: Color {
        if disruptionCount == 0, hasNoSavedDisruptionData { return .secondary }
        if isLoadingTfLDisruptions { return .blue }
        if disruptionCount == 0, appState.cableCar.isOverviewUnconfirmed { return .secondary }
        return disruptionCount == 0 ? .green : .red
    }
}

private struct MapDisruptionQuickDate: Identifiable {
    let title: String
    let selection: DisruptionDateSelection

    var id: String { title }
}

private struct MapDisruptionQuickDateFilter: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    buttons
                }
                .scrollIndicators(.hidden)
            } else {
                buttons
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ForEach(quickDates) { quickDate in
                if dynamicTypeSize.isAccessibilitySize {
                    quickDateButton(quickDate)
                        .frame(width: 116)
                } else {
                    quickDateButton(quickDate)
                        .frame(maxWidth: .infinity)
                }
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
    var onSelect: (MapNetworkStatFilter) -> Void = { _ in }

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
        var filters: [MapNetworkStatFilter] = [.lines, .goodService]
        if appState.mapNetworkStatusSummary.count(for: .closed) > 0 {
            filters.append(.closed)
        }
        filters.append(.disrupted)
        return filters
    }

    private var accessibilityWidth: CGFloat {
        CGFloat(visibleFilters.count) * 132
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
                        symbol: "wrench.and.screwdriver"
                    ))
                }
                appState.toggleMapNetworkStat(filter)
                onSelect(filter)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: filter.symbol)
                    .font(.appCaption2(.bold))
                    .foregroundStyle(filter.color)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 12)
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
                    .frame(
                        minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 28,
                        alignment: .top
                    )
            }
            .offset(y: filter == .lines ? 4 : 0)
            .padding(.horizontal, 4)
            .frame(
                maxWidth: .infinity,
                minHeight: Self.statHeight
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
