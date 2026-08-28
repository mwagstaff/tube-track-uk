import SwiftUI

enum LineServiceCondition: Equatable, Sendable {
    case good(String)
    case minorDisruption(String)
    case majorDisruption(String)
    case overnightClosure(String)
    case updating

    var accessibilityDescription: String {
        switch self {
        case let .good(description),
             let .minorDisruption(description),
             let .majorDisruption(description),
             let .overnightClosure(description):
            description
        case .updating:
            "Status updating"
        }
    }

    static func condition(for status: TfLLineStatus?) -> Self {
        guard let entries = status?.lineStatuses, !entries.isEmpty else { return .updating }

        if let entry = entries.first(where: \.isOvernightClosure) {
            return .overnightClosure(entry.statusSeverityDescription)
        }
        if let entry = entries.first(where: {
            $0.isActionableIssue && $0.statusSeverity != 9
        }) {
            return .majorDisruption(entry.statusSeverityDescription)
        }
        if let entry = entries.first(where: { $0.isActionableIssue }) {
            return .minorDisruption(entry.statusSeverityDescription)
        }
        let description = entries.first?.statusSeverityDescription ?? "Good service"
        return .good(description)
    }
}

struct StationDepartureGroup: Identifiable, Sendable {
    let lineID: TubeLineID
    let direction: String
    let arrivals: [TfLArrivalPrediction]

    var id: String { "\(lineID.rawValue):\(direction.lowercased())" }
    var collapsedArrivals: ArraySlice<TfLArrivalPrediction> { arrivals.prefix(3) }

    static func groups(
        from arrivals: [TfLArrivalPrediction],
        for selectedLineID: TubeLineID? = nil
    ) -> [Self] {
        let validArrivals = arrivals.compactMap { arrival -> (Key, TfLArrivalPrediction)? in
            guard let lineID = TubeLineID(rawValue: arrival.lineId),
                  selectedLineID == nil || lineID == selectedLineID else {
                return nil
            }
            let direction = StationDepartureMetadata.directionLabel(for: arrival)
            return (Key(lineID: lineID, direction: direction), arrival)
        }

        return Dictionary(grouping: validArrivals, by: \.0)
            .map { key, values in
                StationDepartureGroup(
                    lineID: key.lineID,
                    direction: key.direction,
                    arrivals: values.map(\.1).sorted(by: arrivesSooner)
                )
            }
            .sorted { left, right in
                if left.lineID.displayName != right.lineID.displayName {
                    return left.lineID.displayName < right.lineID.displayName
                }
                let leftRank = directionRank(left.direction)
                let rightRank = directionRank(right.direction)
                if leftRank != rightRank { return leftRank < rightRank }
                return left.direction < right.direction
            }
    }

    private static func arrivesSooner(
        _ left: TfLArrivalPrediction,
        _ right: TfLArrivalPrediction
    ) -> Bool {
        if left.timeToStation != right.timeToStation {
            return (left.timeToStation ?? .max) < (right.timeToStation ?? .max)
        }
        if left.expectedArrival != right.expectedArrival {
            return (left.expectedArrival ?? .distantFuture)
                < (right.expectedArrival ?? .distantFuture)
        }
        if left.destinationName != right.destinationName {
            return (left.destinationName ?? "") < (right.destinationName ?? "")
        }
        if left.platformName != right.platformName {
            return (left.platformName ?? "") < (right.platformName ?? "")
        }
        return left.id < right.id
    }

    private static func directionRank(_ direction: String) -> Int {
        switch direction.lowercased() {
        case "northbound": 0
        case "southbound": 1
        case "eastbound": 2
        case "westbound": 3
        case "inbound": 4
        case "outbound": 5
        case "all directions": 6
        default: 7
        }
    }

    private struct Key: Hashable {
        let lineID: TubeLineID
        let direction: String
    }
}

enum StationDepartureSelection {
    static func resolved(
        current: TubeLineID?,
        lineIDs: [TubeLineID],
        arrivals: [TfLArrivalPrediction]
    ) -> TubeLineID? {
        if let current, lineIDs.contains(current) {
            return current
        }

        let linesWithPredictions = Set(arrivals.compactMap {
            TubeLineID(rawValue: $0.lineId)
        })
        return lineIDs.first(where: linesWithPredictions.contains) ?? lineIDs.first
    }
}

enum StationDepartureMetadata {
    static func directionLabel(for arrival: TfLArrivalPrediction) -> String {
        let cardinalDirections = ["northbound", "southbound", "eastbound", "westbound"]
        if let platformName = arrival.platformName?.lowercased(),
           let direction = cardinalDirections.first(where: { platformName.contains($0) }) {
            return direction.capitalized
        }

        if let direction = normalized(arrival.direction) {
            if arrival.lineId == TubeLineID.elizabeth.rawValue {
                switch direction.lowercased() {
                case "inbound":
                    return "Eastbound"
                case "outbound":
                    return "Westbound"
                default:
                    break
                }
            }
            return direction.capitalized
        }
        return "All directions"
    }

    static func platformLabel(for arrival: TfLArrivalPrediction) -> String? {
        guard let platform = normalized(arrival.platformName) else { return nil }
        let lowercasedPlatform = platform.lowercased()
        let cardinalDirections = ["northbound", "southbound", "eastbound", "westbound"]
        if cardinalDirections.contains(where: { lowercasedPlatform.contains($0) }),
           !lowercasedPlatform.contains("platform") {
            return nil
        }

        if arrival.lineId == TubeLineID.elizabeth.rawValue,
           platform.count == 1,
           platform.first?.isLetter == true {
            return "Platform \(platform.uppercased())"
        }
        return platform
    }

    static func destinationLabel(for arrival: TfLArrivalPrediction) -> String {
        let stationID = normalized(arrival.naptanId)?.uppercased()
        let destinationID = normalized(arrival.destinationNaptanId)?.uppercased()
        if let stationID, destinationID == stationID {
            return "Check front of train"
        }

        let stationName = normalizedStopName(arrival.stationName)
        for candidate in [arrival.destinationName, arrival.towards] {
            guard let candidate = normalized(candidate) else { continue }
            if let stationName,
               Self.referencesStation(candidate, normalizedStationName: stationName) {
                continue
            }
            return passengerFacingStopName(candidate)
        }
        return "Check front of train"
    }

    static func departureTime(
        for arrival: TfLArrivalPrediction,
        now: Date = .now
    ) -> String {
        let seconds: Int?
        if let expectedArrival = arrival.expectedArrival {
            seconds = max(0, Int(expectedArrival.timeIntervalSince(now)))
        } else {
            seconds = arrival.timeToStation
        }
        guard let seconds else { return "—" }
        if seconds < 45 { return "Due" }
        return "\(max(1, seconds / 60)) min"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func referencesStation(
        _ value: String,
        normalizedStationName: String
    ) -> Bool {
        let candidate = normalizedStopName(value) ?? ""
        return candidate == normalizedStationName
            || candidate.hasPrefix("\(normalizedStationName) via ")
    }

    private static func normalizedStopName(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        return passengerFacingStopName(value).lowercased()
    }

    private static func passengerFacingStopName(_ rawName: String) -> String {
        var name = rawName
        for suffix in [" Underground Station", " DLR Station", " Tram Stop", " Rail Station"]
            where name.lowercased().hasSuffix(suffix.lowercased()) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }
}

struct StationDepartureWarning {
    let title: String
    let detail: String
}

struct StationDeparturesSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var requestedLineID: TubeLineID?
    @State private var presentedStatusLineID: TubeLineID?

    let lineIDs: [TubeLineID]
    let arrivals: [TfLArrivalPrediction]
    let statuses: [TfLLineStatus]
    let isLoading: Bool
    let errorMessage: String?
    let warning: StationDepartureWarning?
    let maxDeparturesHeight: CGFloat?
    let onShowWarning: (() -> Void)?

    init(
        lineIDs: [TubeLineID],
        arrivals: [TfLArrivalPrediction],
        statuses: [TfLLineStatus],
        isLoading: Bool = false,
        errorMessage: String? = nil,
        warning: StationDepartureWarning? = nil,
        maxDeparturesHeight: CGFloat? = nil,
        onShowWarning: (() -> Void)? = nil
    ) {
        self.lineIDs = lineIDs
        self.arrivals = arrivals
        self.statuses = statuses
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.warning = warning
        self.maxDeparturesHeight = maxDeparturesHeight
        self.onShowWarning = onShowWarning
    }

    private var selectedLineID: TubeLineID? {
        StationDepartureSelection.resolved(
            current: requestedLineID,
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
                lineStatus: statuses.first { $0.id == lineID }
            )
        }
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: selectionInputID) {
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
        if isLoading, arrivals.isEmpty {
            HStack(spacing: 9) {
                ProgressView()
                Text("Loading live departures…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let errorMessage, arrivals.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Departures unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            .padding(.vertical, 3)
        } else if selectedGroups.isEmpty {
            Text(emptyStateMessage)
                .font(.subheadline)
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
        if reduceMotion {
            requestedLineID = lineID
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                requestedLineID = lineID
            }
        }
    }

    private func reconcileSelection() {
        if let requestedLineID, lineIDs.contains(requestedLineID) {
            return
        }
        guard !isLoading || !arrivals.isEmpty else {
            requestedLineID = nil
            return
        }
        requestedLineID = StationDepartureSelection.resolved(
            current: nil,
            lineIDs: lineIDs,
            arrivals: arrivals
        )
    }
}

private struct StationLinePicker: View {
    let lineIDs: [TubeLineID]
    let selectedLineID: TubeLineID?
    let statuses: [TfLLineStatus]
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
                let condition = LineServiceCondition.condition(
                    for: statuses.first { $0.id == selectedLineID }
                )
                Button {
                    onShowStatus(selectedLineID)
                } label: {
                    Image(systemName: statusPresentation(for: condition).symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusPresentation(for: condition).color)
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .tertiarySystemFill), in: .circle)
                        .overlay {
                            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                }
                .buttonStyle(StationDepartureButtonStyle())
                .accessibilityLabel(
                    "\(selectedLineID.displayName) status, \(condition.accessibilityDescription)"
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
                    .font(.caption2.weight(.bold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
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
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(warning.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
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
                    .font(.subheadline.weight(.bold))
                Text(group.direction)
                    .font(.subheadline)
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
                    .font(.caption.weight(.semibold))
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
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let platform = StationDepartureMetadata.platformLabel(for: arrival) {
                    Text(platform)
                        .font(.caption2)
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
            .font(.subheadline.weight(.bold))
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
                            "Status updating",
                            systemImage: "arrow.clockwise",
                            description: Text("Service details for this line aren’t available yet.")
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
                .font(.headline)
                .foregroundStyle(presentation.color)

            if let reason = entry.reason, !reason.isEmpty {
                Text(reason)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(
                    entry.isGoodService
                        ? "TfL is reporting normal service."
                        : "No additional details were reported."
                )
                .font(.body)
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
