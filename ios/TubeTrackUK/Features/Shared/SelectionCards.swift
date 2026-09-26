import SwiftUI

struct StationDetailCard: View {
    @Environment(TubeAppState.self) private var appState
    let station: TubeStation
    var onClose: (() -> Void)? = nil
    let onShowDisruption: (ResolvedDisruption) -> Void

    private var lineIDs: [TubeLineID] {
        appState.graph?.lineIDs(at: station) ?? station.lineIDs
    }

    private var stationIssue: ResolvedDisruption? {
        StationDisruptionLookup.firstMatching(
            station: station,
            graph: appState.graph,
            disruptions: appState.visibleDisruptions
        )
    }

    private var stationWarning: StationDepartureWarning? {
        guard let stationIssue else { return nil }
        guard !appState.isViewingLiveStatus else {
            return StationDepartureWarning(
                title: stationIssue.title,
                detail: stationIssue.reason
            )
        }

        let date = LondonRailDate.formatted(
            appState.selectedDisruptionDate,
            dateFormat: "EEE d MMM"
        )
        return StationDepartureWarning(
            title: stationIssue.title,
            detail: "Planned for \(date). \(stationIssue.reason)"
        )
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 4) {
                    Text(station.name)
                        .font(.appHeadline())
                    Spacer()
                    FavouriteStopButton(stop: .station(station))
                    StationDirectionsButton(station: station)
                    Button("Close", systemImage: "xmark.circle.fill") {
                        if let onClose {
                            onClose()
                        } else {
                            appState.clearStationSelection()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .font(.appTitle2())
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityHint("Closes station details")
                }
                StationDeparturesSection(
                    lineIDs: lineIDs,
                    preferredLineID: appState.selectedStationDepartureLineID,
                    controlledLineID: appState.selectedStationDepartureLineID,
                    arrivals: appState.stationArrivals,
                    statuses: appState.statuses,
                    isLoading: appState.isRefreshingStationArrivals,
                    isOffline: appState.isOffline,
                    errorMessage: appState.stationArrivalsError,
                    warning: stationWarning,
                    maxDeparturesHeight: 280,
                    tracking: DepartureTrackingContext(
                        hubID: station.hubID ?? station.id,
                        stationName: station.name,
                        updatedAt: appState.stationArrivalsUpdatedAt
                    ),
                    onShowWarning: showStationIssue,
                    onSelectLine: appState.selectDepartureLine
                )
                .id("\(station.id):\(appState.stationSelectionGeneration)")
                CardUpdateFooter(updatedAt: appState.stationArrivalsSourceUpdatedAt ?? appState.stationArrivalsUpdatedAt,
                    isOffline: appState.isOffline,
                    isStale: appState.stationArrivalsStale || appState.stationArrivalsError != nil)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func showStationIssue() {
        guard let stationIssue else { return }
        onShowDisruption(stationIssue)
    }
}

enum StationDisruptionLookup {
    static func firstMatching(
        station: TubeStation,
        graph: TubeGraph?,
        disruptions: [ResolvedDisruption]
    ) -> ResolvedDisruption? {
        let stationIDs = Set(
            graph?.stations(inSamePlaceAs: station).map(\.id) ?? [station.id]
        )
        return disruptions.first {
            !$0.affectedStationIDs.isDisjoint(with: stationIDs)
        }
    }
}

struct DisruptionDetailCard: View {
    let disruption: ResolvedDisruption
    let onClose: () -> Void
    let onShowDetails: (ResolvedDisruption) -> Void

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) {
                    LineBadge(lineID: disruption.lineID)
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") {
                        MapResetDiagnostics.logger.notice(
                            "card-button received disruption=\(disruption.id, privacy: .public)"
                        )
                        onClose()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .font(.appTitle2())
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityHint("Closes disruption details and resets the map")
                }

                Label(disruption.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.appSubheadline(.semibold))
                    .foregroundStyle(.red)

                Text(disruption.reason)
                    .font(.appCaption())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        disruptionDetailsButton
                        Spacer(minLength: 0)
                        disruptionConfidenceLabel
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        disruptionDetailsButton
                        disruptionConfidenceLabel
                    }
                }
            }
        }
        // Make the complete visible card an opaque hit-test region so a tap
        // beside a control cannot fall through to the UIKit map gesture layer.
        .contentShape(.rect)
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { }
        }
    }

    private var disruptionDetailsButton: some View {
        Button("Read full disruption", systemImage: "doc.text.magnifyingglass") {
            onShowDetails(disruption)
        }
        .font(.appCaption(.semibold))
    }

    private var disruptionConfidenceLabel: some View {
        Text(disruption.confidence.userDescription)
            .font(.appCaption2())
            .foregroundStyle(.tertiary)
    }
}

struct PlannedWorkDetailCard: View {
    @Environment(TubeAppState.self) private var appState
    @State private var presentsDetails = false
    let work: EngineeringWork

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(work.lineIDs) { LineBadge(lineID: $0) }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Spacer(minLength: 8)

                    Button("Close", systemImage: "xmark.circle.fill") {
                        appState.clearMapSelection()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }

                Label(work.title, systemImage: "wrench.and.screwdriver.fill")
                    .font(.appSubheadline(.semibold))
                    .foregroundStyle(.orange)

                Text(work.detail)
                    .font(.appCaption())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                HStack(alignment: .firstTextBaseline) {
                    Button("View details", systemImage: "doc.text.magnifyingglass") {
                        presentsDetails = true
                    }
                    .font(.appCaption(.semibold))

                    Spacer(minLength: 8)

                    Label(validityLabel, systemImage: "calendar")
                        .font(.appCaption2())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .sheet(isPresented: $presentsDetails) {
            WorkDetailView(work: work)
        }
    }

    private var validityLabel: String {
        let start = LondonRailDate.formatted(work.startDate, dateFormat: "EEE d MMM")
        let end = LondonRailDate.formatted(work.displayEndDate, dateFormat: "EEE d MMM")
        return LondonRailDate.calendar.isDate(work.startDate, inSameDayAs: work.displayEndDate)
            ? start
            : "\(start) – \(end)"
    }
}

struct DisruptionDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let disruption: ResolvedDisruption

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LineBadge(lineID: disruption.lineID)

                    Label(disruption.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.appHeadline())
                        .foregroundStyle(.red)

                    Text(disruption.reason)
                        .font(.appBody())
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Label(disruption.confidence.userDescription, systemImage: "map")
                        .font(.appCaption())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Disruption details")
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
}

struct TrainMapCalloutOverlay: View {
    let train: LiveTubeTrain
    let servicePresentation: LiveTrainServicePresentation
    let nextStopName: String
    let date: Date
    let markerPoint: CGPoint
    let viewportSize: CGSize

    @State private var calloutSize = CGSize(width: 292, height: 142)

    var body: some View {
        let layout = TrainMapCalloutLayout.resolve(
            markerPoint: markerPoint,
            calloutSize: calloutSize,
            viewportSize: viewportSize
        )

        TrainMapCallout(
            train: train,
            servicePresentation: servicePresentation,
            nextStopName: nextStopName,
            date: date,
            arrowOffset: layout.arrowOffset,
            placement: layout.placement
        )
        .frame(width: min(300, max(220, viewportSize.width - 24)))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            calloutSize = newSize
        }
        .position(layout.calloutCenter)
        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

private struct TrainMapCallout: View {
    let train: LiveTubeTrain
    let servicePresentation: LiveTrainServicePresentation
    let nextStopName: String
    let date: Date
    let arrowOffset: CGFloat
    let placement: TrainCalloutPlacement

    private var destinationName: String {
        guard let destination = train.destination?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !destination.isEmpty else {
            return "Destination unavailable"
        }
        return destination
    }

    private var remainingSeconds: Int {
        train.remainingSecondsToNextStation(at: date)
    }

    private var directionName: String? {
        LiveTrainDirection.displayName(for: train.direction)
    }

    private var lineName: String {
        let name = train.lineID.displayName
        guard train.lineID.isUnderground else { return name }
        return "\(name) line"
    }

    private var lineHeaderForeground: Color {
        switch train.lineID {
        case .circle, .hammersmithCity, .jubilee, .victoria, .waterlooCity,
             .dlr, .tram, .lioness, .mildmay, .suffragette:
            .black
        case .bakerloo, .central, .district, .metropolitan, .northern,
             .piccadilly, .elizabeth, .liberty, .weaver,
             .windrush:
            .white
        }
    }

    private var relativeETA: String {
        if remainingSeconds < 30 { return "Due" }
        let minutes = Int(ceil(Double(remainingSeconds) / 60))
        return "\(minutes) min"
    }

    private var informationalNote: String? {
        servicePresentation.informationalNote(for: train.lineID)
    }

    var body: some View {
        Group {
            if placement == .above {
                VStack(spacing: -1) {
                    bubble
                    pointer(rotation: .degrees(180))
                }
            } else {
                VStack(spacing: -1) {
                    pointer(rotation: .zero)
                    bubble
                }
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilitySummary: String {
        guard let directionName else {
            return "\(lineName), destination \(destinationName)"
        }
        return "\(lineName), destination \(destinationName), direction \(directionName)"
    }

    private var accessibilityValue: String {
        let nextStop = "Next stop \(nextStopName), \(relativeETA)"
        guard let informationalNote else { return nextStop }
        return "\(nextStop). \(informationalNote)"
    }

    private var bubble: some View {
        VStack(spacing: 0) {
            Text(lineName)
                .font(.appSubheadline(.bold))
                .foregroundStyle(lineHeaderForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Color.tubeLine(train.lineID),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 18,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 18
                    )
                )

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 8) {
                    Image(
                        systemName: servicePresentation.markerSystemName ?? "tram.fill"
                    )
                        .foregroundStyle(Color.tubeLine(train.lineID))
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Destination")
                                .foregroundStyle(.secondary)
                            Text(destinationName)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .foregroundStyle(Color.tubeLine(train.lineID))
                                .background(
                                    Color.tubeLine(train.lineID).opacity(0.12),
                                    in: .capsule
                                )
                        }

                        if let directionName {
                            HStack(spacing: 8) {
                                Text("Direction")
                                    .foregroundStyle(.secondary)
                                Text(directionName)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.tubeLine(train.lineID))
                            }
                        }
                    }
                }
                .font(.appSubheadline())

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Next stop")
                            .font(.appCaption())
                            .foregroundStyle(.secondary)
                        Text(nextStopName)
                            .font(.appSubheadline(.semibold))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(
                            train.estimatedNextStopArrival(at: date),
                            format: .dateTime.hour().minute()
                        )
                        .font(.appCaption().monospacedDigit())
                        .foregroundStyle(.secondary)
                        Text(relativeETA)
                            .font(.appTitle3(.bold).monospacedDigit())
                            .foregroundStyle(Color.tubeLine(train.lineID))
                    }
                }

                if let informationalNote {
                    Divider()

                    Label {
                        Text(informationalNote)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                    }
                    .font(.appCaption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

            }
            .padding(15)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.primary.opacity(0.18), lineWidth: 1)
        }
    }

    private func pointer(rotation: Angle) -> some View {
        TrainCalloutPointer()
            .fill(.regularMaterial)
            .overlay {
                TrainCalloutPointer()
                    .stroke(.primary.opacity(0.18), lineWidth: 1)
            }
            .frame(width: 24, height: 14)
            .rotationEffect(rotation)
            .offset(x: arrowOffset)
            .zIndex(1)
    }
}

private struct TrainCalloutPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

enum TrainCalloutPlacement: Equatable {
    case above
    case below
}

struct TrainMapCalloutLayout: Equatable {
    let calloutCenter: CGPoint
    let arrowOffset: CGFloat
    let placement: TrainCalloutPlacement

    static func resolve(
        markerPoint: CGPoint,
        calloutSize: CGSize,
        viewportSize: CGSize
    ) -> Self {
        let horizontalMargin: CGFloat = 12
        let topClearance: CGFloat = 104
        let bottomClearance: CGFloat = 12
        let markerGap: CGFloat = 12
        let halfWidth = calloutSize.width / 2
        let halfHeight = calloutSize.height / 2
        let minimumX = horizontalMargin + halfWidth
        let maximumX = max(minimumX, viewportSize.width - horizontalMargin - halfWidth)
        let centreX = min(maximumX, max(minimumX, markerPoint.x))
        let fitsAbove = markerPoint.y - markerGap - calloutSize.height >= topClearance
        let placement: TrainCalloutPlacement = fitsAbove ? .above : .below
        let proposedY = placement == .above
            ? markerPoint.y - markerGap - halfHeight
            : markerPoint.y + markerGap + halfHeight
        let minimumY = topClearance + halfHeight
        let maximumY = max(minimumY, viewportSize.height - bottomClearance - halfHeight)
        let centreY = min(maximumY, max(minimumY, proposedY))
        let maximumArrowOffset = max(0, halfWidth - 30)
        let arrowOffset = min(
            maximumArrowOffset,
            max(-maximumArrowOffset, markerPoint.x - centreX)
        )

        return Self(
            calloutCenter: CGPoint(x: centreX, y: centreY),
            arrowOffset: arrowOffset,
            placement: placement
        )
    }
}

enum LiveTrainHitTesting {
    static let hitRadius: CGFloat = 30

    static func nearest(
        to location: CGPoint,
        candidates: [(train: LiveTubeTrain, point: CGPoint)]
    ) -> LiveTubeTrain? {
        candidates
            .map { candidate in
                (
                    train: candidate.train,
                    distance: hypot(
                        candidate.point.x - location.x,
                        candidate.point.y - location.y
                    )
                )
            }
            .filter { $0.distance <= hitRadius }
            .min { $0.distance < $1.distance }?
            .train
    }
}

struct TrainFilterBar: View {
    @Environment(TubeAppState.self) private var appState

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                Button {
                    appState.setTrainFilter(nil)
                } label: {
                    Text("All (\(appState.activeTrainCounts.total))")
                        .font(.appCaption(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(appState.trainLineFilter.isEmpty ? Color.blue : Color.secondary.opacity(0.16), in: .capsule)
                        .foregroundStyle(appState.trainLineFilter.isEmpty ? .white : .primary)
                }
                .buttonStyle(.plain)

                ForEach(TubeLineID.liveTrainFilterCases) { lineID in
                    Button {
                        appState.setTrainFilter(lineID)
                    } label: {
                        LineBadge(
                            lineID: lineID,
                            showsName: true,
                            activeTrainCount: appState.activeTrainCounts.count(for: lineID)
                        )
                            .overlay {
                                if appState.trainLineFilter.contains(lineID) {
                                    Capsule().stroke(Color.blue, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }

                Text(activeTrainSummary)
                    .font(.appCaption2(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.leading, 3)
                    .accessibilityLabel(activeTrainSummary)
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var activeTrainSummary: String {
        let trainCount = appState.activeTrainCounts.total
        let activeLineCount = appState.activeTrainCounts.activeLineCount(
            excluding: appState.mapNetworkStatusSummary.closedLineIDs
        )
        let trainNoun = trainCount == 1 ? "train" : "trains"
        let lineNoun = activeLineCount == 1 ? "line" : "lines"
        return "\(trainCount) active \(trainNoun) across \(activeLineCount) active \(lineNoun)"
    }
}

struct LineDetailCard: View {
    @Environment(TubeAppState.self) private var appState
    let lineID: TubeLineID

    private var status: TfLStatusEntry? {
        appState.statuses.first { $0.id == lineID }?.lineStatuses.first
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    LineBadge(lineID: lineID)
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") {
                        appState.selectedLineID = nil
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }

                Label(
                    status?.statusSeverityDescription
                        ?? (appState.isOffline ? "No saved status" : "Status updating"),
                    systemImage: status == nil && appState.isOffline
                        ? "wifi.slash"
                        : status?.isGoodService == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.appSubheadline(.semibold))
                .foregroundStyle(
                    status == nil && appState.isOffline
                        ? Color.secondary
                        : status?.isGoodService == true ? .green : .orange
                )

                if let reason = status?.reason {
                    Text(reason)
                        .font(.appCaption())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if lineID.supportsEstimatedTrains {
                    Button {
                        appState.setTrainFilter(lineID)
                        appState.setLiveTrains(true)
                    } label: {
                        Label("Show estimated live trains", systemImage: "tram.fill")
                            .font(.appCaption(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .requiresNetwork(appState.isOffline)
                }
            }
        }
    }
}
