import SwiftUI
import TubeTrackCore

/// The National Rail double arrow supplied in the design reference, drawn as
/// a vector so the small mark stays sharp at every Dynamic Type size.
struct NationalRailMark: View {
    @ScaledMetric(relativeTo: .caption) private var width = 20.0

    var body: some View {
        NationalRailDoubleArrow()
            .fill(.white)
            .padding(3)
            .frame(width: width, height: width * 0.72)
            .background(Color(red: 0.9, green: 0, blue: 0.08), in: .rect(cornerRadius: 2))
            .accessibilityHidden(true)
    }
}

private struct NationalRailDoubleArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let polygons: [[CGPoint]] = [
            [.init(x: 0.20, y: 0), .init(x: 0.42, y: 0), .init(x: 0.70, y: 0.24),
             .init(x: 1, y: 0.24), .init(x: 1, y: 0.40), .init(x: 0.70, y: 0.40),
             .init(x: 0.53, y: 0.60), .init(x: 1, y: 0.60), .init(x: 1, y: 0.76),
             .init(x: 0.53, y: 0.76), .init(x: 0.80, y: 1), .init(x: 0.58, y: 1),
             .init(x: 0.30, y: 0.76), .init(x: 0, y: 0.76), .init(x: 0, y: 0.60),
             .init(x: 0.30, y: 0.60), .init(x: 0.53, y: 0.40), .init(x: 0, y: 0.40),
             .init(x: 0, y: 0.24), .init(x: 0.53, y: 0.24)]
        ]
        for points in polygons {
            path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
            path.closeSubpath()
        }
        return path
    }
}

struct NationalRailOperatorPill: View {
    let name: String
    let id: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                NationalRailMark()
                Text(name).lineLimit(1)
                Image(systemName: "checkmark")
                    .font(.appCaption2(.bold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .font(.appCaption(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(uiColor: selected ? .secondarySystemFill : .tertiarySystemFill), in: .capsule)
            .overlay { Capsule().stroke(Color.primary.opacity(selected ? 0.45 : 0.08), lineWidth: 1) }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("departures-operator-\(id)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), National Rail")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Shows departures for this operator")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NationalRailDepartureGroupView: View {
    @Environment(StationBoardActivityController.self) private var boardActivity: StationBoardActivityController?
    @Environment(ScheduledJourneyStore.self) private var scheduleStore: ScheduledJourneyStore?
    @State private var scheduling: ScheduledJourney?
    @State private var choosesTracking = false
    @State private var expanded = false
    let group: NationalRailDepartureGroup
    let now: Date
    var tracking: DepartureTrackingContext?
    var isFresh = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    heading
                    Spacer(minLength: 6)
                    trackButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    trackButton
                }
            }
            ForEach(expanded ? group.arrivals[...] : group.arrivals.prefix(3), id: \.departureIdentity) { arrival in
                StationDepartureRow(arrival: arrival, now: now)
            }
            if group.arrivals.count > 3 {
                Button { expanded.toggle() } label: {
                    Label(expanded ? "Show fewer departures" : "View all departures",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.appCaption(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.departureAccent)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
    }

    private var heading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                NationalRailMark()
                operatorName
                directionLabel
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    NationalRailMark()
                    operatorName
                }.fixedSize(horizontal: true, vertical: false)
                directionLabel
            }
            VStack(alignment: .leading, spacing: 4) {
                operatorName
                HStack(spacing: 7) {
                    NationalRailMark()
                    directionLabel
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var operatorName: some View {
        Text(group.name).font(.appSubheadline(.bold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var directionLabel: some View {
        Text(group.directionLabel).font(.appSubheadline())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var trackButton: some View {
        if let tracking, let controller = boardActivity {
            let updatedAt = tracking.nationalRailUpdatedAt ?? tracking.updatedAt
            let isTracking = controller.isTracking(hubID: tracking.hubID, lineIDRaw: group.operatorID,
                direction: group.direction.displayName)
            DepartureTrackButton(isTracking: isTracking,
                boardName: "\(group.name) \(group.direction.displayName) at \(tracking.stationName)") {
                if isTracking { Task { await controller.end(reason: .userEnded) } }
                else { choosesTracking = true }
            }
            .confirmationDialog("Track this journey", isPresented: $choosesTracking, titleVisibility: .visible) {
                Button("Start tracking now") {
                    Task {
                        guard isFresh, let updatedAt, Date.now.timeIntervalSince(updatedAt) <= 90 else { return }
                        await controller.start(hubID: tracking.hubID, stationName: tracking.stationName,
                            group: group, updatedAt: updatedAt)
                    }
                }
                .disabled(!controller.areActivitiesEnabled || group.direction == .any || !isFresh || updatedAt == nil || now.timeIntervalSince(updatedAt ?? .distantPast) > 90)
                if scheduleStore != nil, group.operatorID != "national-rail:unknown", let station = ScheduledBoard.railStation(id: tracking.hubID) {
                    Button("Add scheduled journey") {
                        scheduling = .suggested(outbound: ScheduledBoard(station: station,
                            operatorID: group.operatorID, operatorName: group.name, direction: group.direction))
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $scheduling) { journey in
                NavigationStack { ScheduledJourneyEditor(journey: journey, suggestsReturn: true) }
            }
            .accessibilityHint(isTracking ? "Removes the departure board from the Lock Screen"
                               : "Choose to track now or add a scheduled journey")
            .fixedSize(horizontal: true, vertical: false)

            .accessibilityIdentifier("departures-track-\(group.id)")
        }
    }
}

#if DEBUG
#Preview("Rail pills — light") {
    VStack {
        NationalRailOperatorPill(name: "Southeastern", id: "SE", selected: true) {}
        NationalRailOperatorPill(name: "Southern", id: "SN", selected: false) {}
    }.padding()
}

#Preview("Rail pills — dark, large text") {
    NationalRailOperatorPill(name: "South Western Railway", id: "SW", selected: true) {}
        .padding().preferredColorScheme(.dark).environment(\.dynamicTypeSize, .accessibility3)
}
#endif
