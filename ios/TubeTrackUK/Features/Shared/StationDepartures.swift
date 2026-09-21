import SwiftUI

struct StationDepartureWarning {
    let title: String
    let detail: String
}

struct StationDeparturesSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var requestedLineID: TubeLineID?
    @State private var presentedStatusLineID: TubeLineID?

    let lineIDs: [TubeLineID]
    let preferredLineID: TubeLineID?
    let controlledLineID: TubeLineID?
    let arrivals: [TfLArrivalPrediction]
    let statuses: [TfLLineStatus]
    let isLoading: Bool
    let isOffline: Bool
    let errorMessage: String?
    let warning: StationDepartureWarning?
    let maxDeparturesHeight: CGFloat?
    let onShowWarning: (() -> Void)?
    let onSelectLine: ((TubeLineID) -> Void)?

    init(
        lineIDs: [TubeLineID],
        preferredLineID: TubeLineID? = nil,
        controlledLineID: TubeLineID? = nil,
        arrivals: [TfLArrivalPrediction],
        statuses: [TfLLineStatus],
        isLoading: Bool = false,
        isOffline: Bool = false,
        errorMessage: String? = nil,
        warning: StationDepartureWarning? = nil,
        maxDeparturesHeight: CGFloat? = nil,
        onShowWarning: (() -> Void)? = nil,
        onSelectLine: ((TubeLineID) -> Void)? = nil
    ) {
        self.lineIDs = lineIDs
        self.preferredLineID = preferredLineID
        self.controlledLineID = controlledLineID
        self.arrivals = arrivals
        self.statuses = statuses
        self.isLoading = isLoading
        self.isOffline = isOffline
        self.errorMessage = errorMessage
        self.warning = warning
        self.maxDeparturesHeight = maxDeparturesHeight
        self.onShowWarning = onShowWarning
        self.onSelectLine = onSelectLine
        _requestedLineID = State(initialValue: preferredLineID.flatMap {
            lineIDs.contains($0) ? $0 : nil
        })
    }

    private var selectedLineID: TubeLineID? {
        StationDepartureSelection.resolved(
            controlled: controlledLineID,
            requested: requestedLineID,
            usesControlledSelection: onSelectLine != nil,
            preferred: preferredLineID,
            lineIDs: lineIDs,
            arrivals: arrivals
        )
    }

    private var selectedGroups: [StationDepartureGroup] {
        StationDepartureGroup.groups(from: arrivals, for: selectedLineID)
    }

    private var selectionInputID: String {
        let lines = lineIDs.map(\.rawValue).joined(separator: ":")
        let predictionLines = Set(arrivals.map(\.lineId)).sorted().joined(separator: ":")
        return "\(isLoading):\(lines):\(predictionLines)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !lineIDs.isEmpty {
                StationLinePicker(
                    lineIDs: lineIDs,
                    selectedLineID: selectedLineID,
                    statuses: statuses,
                    isOffline: isOffline,
                    onSelect: select,
                    onShowStatus: { presentedStatusLineID = $0 }
                )
                .padding(.bottom, 10)

                Divider()
            }

            if let warning {
                StationDepartureWarningView(
                    warning: warning,
                    action: onShowWarning
                )
                .padding(.vertical, 10)

                Divider()
            }

            TimelineView(.periodic(from: .now, by: 15)) { context in
                departuresViewport(now: context.date)
                    .padding(.top, 12)
            }
        }
        .sheet(item: $presentedStatusLineID) { lineID in
            LineStatusDetailSheet(
                lineID: lineID,
                lineStatus: statuses.first { $0.id == lineID },
                isOffline: isOffline
            )
        }
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: selectionInputID) {
            reconcileSelection()
        }
        .onChange(of: preferredLineID) { _, preferredLineID in
            guard onSelectLine == nil else { return }
            requestedLineID = preferredLineID.flatMap {
                lineIDs.contains($0) ? $0 : nil
            }
            reconcileSelection()
        }
    }

    @ViewBuilder
    private func departuresViewport(now: Date) -> some View {
        if let maxDeparturesHeight {
            ScrollView(.vertical) {
                departuresContent(now: now)
                    .padding(.trailing, 4)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: maxDeparturesHeight)
            .id(selectedLineID)
        } else {
            departuresContent(now: now)
        }
    }

    @ViewBuilder
    private func departuresContent(now: Date) -> some View {
        if isOffline {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live departures unavailable offline")
                        .font(.appSubheadline(.semibold))
                    Text("Departures will update when you’re back online.")
                        .font(.appCaption())
                }
            } icon: {
                Image(systemName: "wifi.slash")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        } else if isLoading, arrivals.isEmpty {
            HStack(spacing: 9) {
                ProgressView()
                Text("Loading live departures…")
                    .font(.appSubheadline())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let errorMessage, arrivals.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.tubeBlue)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LiveDepartureWaitingCopy.title)
                        .font(.appSubheadline(.semibold))
                    Text(errorMessage)
                        .font(.appCaption())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        } else if selectedGroups.isEmpty {
            Text(emptyStateMessage)
                .font(.appSubheadline())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 13) {
                ForEach(Array(selectedGroups.enumerated()), id: \.element.id) { index, group in
                    StationDepartureGroupView(group: group, now: now)
                    if index < selectedGroups.count - 1 {
                        Divider()
                    }
                }
            }
            .id(selectedLineID)
        }
    }

    private var emptyStateMessage: String {
        guard let selectedLineID else { return "No imminent departures reported." }
        return "No imminent \(selectedLineID.displayName) departures reported."
    }

    private func select(_ lineID: TubeLineID) {
        guard lineID != selectedLineID else { return }
        if let onSelectLine {
            if reduceMotion {
                onSelectLine(lineID)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    onSelectLine(lineID)
                }
            }
            return
        }
        if reduceMotion {
            requestedLineID = lineID
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                requestedLineID = lineID
            }
        }
    }

    private func reconcileSelection() {
        guard onSelectLine == nil else { return }
        if let requestedLineID, lineIDs.contains(requestedLineID) {
            return
        }
        guard !isLoading || !arrivals.isEmpty else {
            requestedLineID = nil
            return
        }
        requestedLineID = StationDepartureSelection.resolved(
            current: nil,
            preferred: preferredLineID,
            lineIDs: lineIDs,
            arrivals: arrivals
        )
    }
}

private struct StationLinePicker: View {
    let lineIDs: [TubeLineID]
    let selectedLineID: TubeLineID?
    let statuses: [TfLLineStatus]
    let isOffline: Bool
    let onSelect: (TubeLineID) -> Void
    let onShowStatus: (TubeLineID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(lineIDs) { lineID in
                        StationLinePill(
                            lineID: lineID,
                            selected: selectedLineID == lineID,
                            action: { onSelect(lineID) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)

            if let selectedLineID {
                let status = statuses.first { $0.id == selectedLineID }
                let condition = LineServiceCondition.condition(
                    for: status
                )
                let hasNoSavedStatus = isOffline && (status?.lineStatuses.isEmpty ?? true)
                Button {
                    onShowStatus(selectedLineID)
                } label: {
                    Image(systemName: hasNoSavedStatus ? "wifi.slash" : statusPresentation(for: condition).symbol)
                        .font(.appSubheadline(.semibold))
                        .foregroundStyle(hasNoSavedStatus ? .secondary : statusPresentation(for: condition).color)
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .tertiarySystemFill), in: .circle)
                        .overlay {
                            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                }
                .buttonStyle(StationDepartureButtonStyle())
                .accessibilityLabel(
                    "\(selectedLineID.displayName) status, \(hasNoSavedStatus ? "No saved status" : condition.accessibilityDescription)"
                )
                .accessibilityHint("Shows full service status")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func statusPresentation(
        for condition: LineServiceCondition
    ) -> (symbol: String, color: Color) {
        switch condition {
        case .good:
            ("checkmark.circle.fill", .green)
        case .minorDisruption:
            ("exclamationmark.triangle.fill", .orange)
        case .majorDisruption:
            ("exclamationmark.octagon.fill", .red)
        case .overnightClosure:
            ("moon.zzz.fill", .indigo)
        case .updating:
            ("arrow.clockwise", .secondary)
        }
    }
}

struct StationLinePill: View {
    let lineID: TubeLineID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                TubeLineDot(lineID: lineID)
                Text(lineID.displayName)
                    .lineLimit(1)
                Image(systemName: "checkmark")
                    .font(.appCaption2(.bold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .font(.appCaption(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                selected ? Color.tubeBlue : Color(uiColor: .tertiarySystemFill),
                in: .capsule
            )
            .overlay {
                Capsule().stroke(
                    selected ? Color.white.opacity(0.18) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(StationDepartureButtonStyle())
        .accessibilityIdentifier("departures-line-\(lineID.rawValue)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lineID.displayName)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(
            selected ? "Currently showing departures" : "Shows departures for this line"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct StationDepartureWarningView: View {
    let warning: StationDepartureWarning
    let action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.appSubheadline())
                    .foregroundStyle(.red)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.title)
                        .font(.appCaption(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(warning.detail)
                        .font(.appCaption2())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.appCaption2(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(StationDepartureButtonStyle())
        .disabled(action == nil)
        .accessibilityLabel("Station issue. \(warning.title). \(warning.detail)")
        .accessibilityHint(action == nil ? "" : "Shows full disruption details")
    }
}

private struct StationDepartureGroupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    let group: StationDepartureGroup
    let now: Date

    private var visibleArrivals: ArraySlice<TfLArrivalPrediction> {
        isExpanded ? group.arrivals[...] : group.collapsedArrivals
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                TubeLineDot(lineID: group.lineID, size: 9)
                Text(group.lineID.displayName)
                    .font(.appSubheadline(.bold))
                Text(group.direction)
                    .font(.appSubheadline())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: 8) {
                ForEach(visibleArrivals, id: \.departureIdentity) { arrival in
                    departureRow(arrival, now: now)
                }
            }

            if group.arrivals.count > 3 {
                Button {
                    toggleExpansion()
                } label: {
                    HStack(spacing: 5) {
                        Text(isExpanded ? "Show fewer departures" : "View all departures")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.appCaption(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.departureAccent)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }
        }
    }

    private func departureRow(
        _ arrival: TfLArrivalPrediction,
        now: Date
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(StationDepartureMetadata.destinationLabel(for: arrival))
                    .font(.appSubheadline(.medium))
                    .lineLimit(2)
                if let platform = StationDepartureMetadata.platformLabel(for: arrival) {
                    Text(platform)
                        .font(.appCaption2())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            Text(
                StationDepartureMetadata.departureTime(
                    for: arrival,
                    now: now
                )
            )
            .font(.appSubheadline(.bold))
            .monospacedDigit()
            .foregroundStyle(Color.departureAccent)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded.toggle()
            }
        }
    }
}

private struct StationDepartureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct LineStatusDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let lineID: TubeLineID
    let lineStatus: TfLLineStatus?
    let isOffline: Bool

    private var entries: [TfLStatusEntry] {
        lineStatus?.lineStatuses ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LineBadge(lineID: lineID)

                    if entries.isEmpty {
                        ContentUnavailableView(
                            isOffline ? "No saved status" : "Status updating",
                            systemImage: isOffline ? "wifi.slash" : "arrow.clockwise",
                            description: Text(
                                isOffline
                                    ? "Connect to the internet to check this line’s service status."
                                    : "Service details for this line aren’t available yet."
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            statusEntry(entry)
                            if index < entries.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("\(lineID.displayName) status")
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

    private func statusEntry(_ entry: TfLStatusEntry) -> some View {
        let presentation = presentation(for: entry)
        return VStack(alignment: .leading, spacing: 10) {
            Label(entry.statusSeverityDescription, systemImage: presentation.symbol)
                .font(.appHeadline())
                .foregroundStyle(presentation.color)

            if let reason = entry.reason, !reason.isEmpty {
                Text(reason)
                    .font(.appBody())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(
                    entry.isGoodService
                        ? (isOffline ? "Normal service was reported in the saved update." : "TfL is reporting normal service.")
                        : "No additional details were reported."
                )
                .font(.appBody())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func presentation(for entry: TfLStatusEntry) -> (symbol: String, color: Color) {
        if entry.isOvernightClosure {
            return ("moon.zzz.fill", .indigo)
        }
        if entry.isActionableIssue, entry.statusSeverity != 9 {
            return ("exclamationmark.octagon.fill", .red)
        }
        if entry.isActionableIssue {
            return ("exclamationmark.triangle.fill", .orange)
        }
        return ("checkmark.circle.fill", .green)
    }
}

#if DEBUG
#Preview("Station departures") {
    StationDeparturesSection(
        lineIDs: [.northern, .victoria],
        arrivals: [
            TfLArrivalPrediction(
                id: "northern-north-1",
                vehicleId: "1",
                lineId: TubeLineID.northern.rawValue,
                stationName: "Stockwell",
                naptanId: "stockwell",
                platformName: "Northbound - Platform 2",
                direction: "inbound",
                destinationName: "High Barnet Underground Station",
                destinationNaptanId: nil,
                towards: "High Barnet",
                expectedArrival: nil,
                timeToStation: 60,
                currentLocation: nil
            ),
            TfLArrivalPrediction(
                id: "northern-south-1",
                vehicleId: "2",
                lineId: TubeLineID.northern.rawValue,
                stationName: "Stockwell",
                naptanId: "stockwell",
                platformName: "Southbound - Platform 3",
                direction: "outbound",
                destinationName: "Morden Underground Station",
                destinationNaptanId: nil,
                towards: "Morden",
                expectedArrival: nil,
                timeToStation: 120,
                currentLocation: nil
            ),
        ],
        statuses: []
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
#endif
