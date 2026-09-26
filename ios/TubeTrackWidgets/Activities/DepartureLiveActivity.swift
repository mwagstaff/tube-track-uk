import ActivityKit
import SwiftUI
import TubeTrackCore
import WidgetKit

/// The Lock Screen and Dynamic Island presentation of a tracked departure board.
///
/// The activity cannot fetch anything: it renders the last state it was handed
/// with minute-only labels refreshed by app updates and server pushes. When iOS
/// marks the content stale, the countdowns are replaced by the
/// clock times they were predicted for — a statement that stays true no matter
/// how long the silence lasts.
struct DepartureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DepartureActivityAttributes.self) { context in
            DepartureActivityContent(context: context)
                .activityBackgroundTint(DepartureBoardStyle.background)
                .activitySystemActionForegroundColor(DepartureBoardStyle.yellow)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.direction)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DepartureBoardStyle.yellow)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DepartureCountdown(
                        departure: context.nextDeparture,
                        isStale: context.isStale,
                        font: .title3.weight(.semibold)
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.stationName)
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(DepartureBoardStyle.yellow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(context.followingDepartures.enumerated()), id: \.offset) { index, departure in
                            DepartureActivityRow(
                                departure: departure, position: index + 2,
                                isStale: context.isStale, font: .system(.caption, design: .monospaced)
                            )
                        }
                        DepartureActivityFooter(context: context)
                    }
                }
            } compactLeading: {
                DepartureActivityStatusIcon(condition: context.condition)
            } compactTrailing: {
                DepartureCountdown(
                    departure: context.nextDeparture,
                    isStale: context.isStale,
                    font: .caption2.weight(.semibold)
                )
                .frame(width: 58)
            } minimal: {
                DepartureActivityStatusIcon(condition: context.condition)
            }
            .keylineTint(DepartureBoardStyle.yellow)
            .widgetURL(context.deepLink)
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct DepartureActivityContent: View {
    @Environment(\.activityFamily) private var family

    let context: ActivityViewContext<DepartureActivityAttributes>

    var body: some View {
        if family == .small {
            DepartureActivityWatchView(context: context)
        } else {
            DepartureActivityLockScreenView(context: context)
        }
    }
}

/// The Watch Smart Stack shows two trains under a compact station and line header.
private struct DepartureActivityWatchView: View {
    let context: ActivityViewContext<DepartureActivityAttributes>

    var body: some View {
        DepartureActivityWatchCard(
            stationName: context.attributes.stationName,
            lineID: context.lineID,
            direction: context.attributes.direction,
            directionFilter: context.attributes.directionFilter,
            condition: context.condition,
            departures: Array(context.visibleDepartures.prefix(2)),
            isStale: context.isStale,
            deepLink: context.deepLink
        )
    }
}

private struct DepartureActivityWatchCard: View {
    let stationName: String
    let lineID: TubeLineID
    let direction: String
    let directionFilter: DepartureDirectionFilter
    let condition: LineServiceCondition
    let departures: [DepartureActivityAttributes.ContentState.Departure]
    let isStale: Bool
    let deepLink: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(stationName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if isStale {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 2)
                HStack(spacing: 3) {
                    Text(shortLineName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    DepartureActivityStatusIcon(condition: condition)
                        .font(.system(size: 11))
                    Text(shortDirection)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.caption2.weight(.semibold))
                .layoutPriority(1)
            }

            if departures.isEmpty {
                Text("No trains due")
                    .font(.subheadline.weight(.semibold))
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(departures.enumerated()), id: \.offset) { index, departure in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(departure.destination)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            DepartureCountdown(
                                departure: departure, isStale: isStale,
                                font: .subheadline.weight(.bold)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(DepartureBoardStyle.yellow)
        .widgetURL(deepLink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var shortLineName: String {
        let name = lineID.watchShortName
        return name.count <= 8 ? name : lineID.shortCode
    }

    private var shortDirection: String {
        switch directionFilter {
        case .northbound: "N"
        case .southbound: "S"
        case .eastbound: "E"
        case .westbound: "W"
        case .inbound: "In"
        case .outbound: "Out"
        case .any: "All"
        }
    }

    private var accessibilityLabel: String {
        let heading = "\(stationName), \(lineID.displayName), "
            + "\(direction), \(condition.accessibilityDescription)"
        let staleDescription = isStale ? ". Live updates paused" : ""
        guard !departures.isEmpty else { return heading + ", no trains due" + staleDescription }
        let trains = departures.enumerated().map { index, departure in
            let prediction = departure.expectedAt.formatted(date: .omitted, time: .shortened)
            return "\(index == 0 ? "Next" : "Then") \(departure.destination), "
                + "\(isStale ? "last predicted" : "due") \(prediction)"
        }
        return heading + ", " + trains.joined(separator: "; ")
            + staleDescription
    }
}

// MARK: - Lock Screen

private struct DepartureActivityLockScreenView: View {
    let context: ActivityViewContext<DepartureActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(context.attributes.stationName) · \(context.lineID.displayName) · \(context.attributes.direction)")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if context.visibleDepartures.isEmpty {
                Text("No more departures")
                    .font(.system(.subheadline, design: .monospaced))
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(context.visibleDepartures.enumerated()), id: \.offset) { index, departure in
                        DepartureActivityRow(
                            departure: departure, position: index + 1, isStale: context.isStale
                        )
                    }
                }
            }

            DepartureActivityFooter(context: context)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(DepartureBoardStyle.yellow)
        .widgetURL(context.deepLink)
    }
}

// MARK: - Pieces

private enum DepartureBoardStyle {
    static let yellow = Color(red: 1, green: 0.86, blue: 0)
    static let background = Color(red: 0.13, green: 0.13, blue: 0.12)
    static let timeBackground = Color(white: 0.22)

    // Always use a 24-hour London clock, regardless of the phone's locale.
    static let updateTime = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: TimeZone(identifier: "Europe/London")!,
        calendar: Calendar(identifier: .gregorian)
    )
}

private struct DepartureActivityStatus: View {
    let condition: LineServiceCondition

    var body: some View {
        HStack(spacing: 5) {
            DepartureActivityStatusIcon(condition: condition)
            Text(condition.headline)
                .foregroundStyle(DepartureBoardStyle.yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(condition.accessibilityDescription)
    }
}

private struct DepartureActivityStatusIcon: View {
    let condition: LineServiceCondition

    var body: some View {
        Group {
            switch condition {
            case .majorDisruption:
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.white, .red)
            case .minorDisruption:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.black, .yellow)
            case .good:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, .green)
            case .overnightClosure:
                Image(systemName: "moon.circle.fill")
                    .foregroundStyle(.white, .indigo)
            case .updating:
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.white, .gray)
            }
        }
        .symbolRenderingMode(.palette)
        .accessibilityLabel(condition.accessibilityDescription)
    }
}

private struct DepartureActivityRow: View {
    let departure: DepartureActivityAttributes.ContentState.Departure
    let position: Int
    let isStale: Bool
    var font: Font = .system(.subheadline, design: .monospaced)

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(position.formatted())
                .font(font.bold())
                .frame(minWidth: 12, alignment: .leading)
            Text(departure.destination)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            DepartureCountdown(
                departure: departure, isStale: isStale,
                font: .system(.caption, design: .monospaced).weight(.semibold)
            )
            .multilineTextAlignment(.center)
            .frame(width: 72)
            .padding(.vertical, 3)
            .background(DepartureBoardStyle.timeBackground, in: .rect(cornerRadius: 4))
        }
        .foregroundStyle(DepartureBoardStyle.yellow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let time = departure.expectedAt.formatted(date: .omitted, time: .shortened)
        return isStale
            ? "\(position), \(departure.destination), predicted \(time), live updates paused"
            : "\(position), \(departure.destination), \(time)"
    }
}

/// The countdown at rendering time, refreshed with each new snapshot. Once iOS
/// marks the activity stale it becomes the clock time the train was predicted for.
private struct DepartureCountdown: View {
    let departure: DepartureActivityAttributes.ContentState.Departure?
    let isStale: Bool
    var font: Font = .subheadline

    var body: some View {
        Group {
            if let departure {
                if isStale {
                    Text(departure.expectedAt, style: .time)
                } else {
                    Text(DepartureCountdownFormatStyle(expectedAt: departure.expectedAt).format(.now))
                }
            } else {
                Text("—")
            }
        }
        .font(font)
        .foregroundStyle(DepartureBoardStyle.yellow)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct DepartureActivityFooter: View {
    let context: ActivityViewContext<DepartureActivityAttributes>

    var body: some View {
        VStack(spacing: 2) {
            if context.isStale {
                Label("Live updates paused", systemImage: "clock.arrow.circlepath")
            }
            HStack(spacing: 8) {
                Text("Updated \(context.state.updatedAt, format: DepartureBoardStyle.updateTime)")
                    .monospacedDigit()
                    .accessibilityLabel("Updated at \(context.state.updatedAt.formatted(DepartureBoardStyle.updateTime))")
                DepartureActivityStatus(condition: context.condition)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(DepartureBoardStyle.yellow)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Context conveniences

private extension ActivityViewContext<DepartureActivityAttributes> {
    var lineID: TubeLineID { attributes.lineID ?? .central }

    var condition: LineServiceCondition {
        LineServiceCondition(severityRank: state.conditionRank, headline: state.conditionHeadline)
    }

    /// Departures still ahead. A stale activity keeps showing what it last
    /// knew — dropping rows as the clock passes them would imply the board is
    /// still being updated.
    var visibleDepartures: [DepartureActivityAttributes.ContentState.Departure] {
        Array((isStale ? state.departures : state.upcoming(at: .now))
            .prefix(DepartureActivityAttributes.ContentState.maximumDepartures))
    }

    var nextDeparture: DepartureActivityAttributes.ContentState.Departure? {
        visibleDepartures.first
    }

    var followingDepartures: [DepartureActivityAttributes.ContentState.Departure] {
        Array(visibleDepartures.dropFirst())
    }

    var deepLink: URL {
        DeepLink.station(id: attributes.stationHubID, line: attributes.lineID).url
    }
}

// MARK: - Previews

#Preview("Lock Screen", as: .content, using: DepartureActivityAttributes.preview) {
    DepartureLiveActivity()
} contentStates: {
    DepartureActivityAttributes.ContentState.previewFresh
    DepartureActivityAttributes.ContentState.previewDisrupted
    DepartureActivityAttributes.ContentState.previewSevere
    DepartureActivityAttributes.ContentState.previewEmpty
}

#Preview("Watch Smart Stack") {
    let attributes = DepartureActivityAttributes.previewWatch
    DepartureActivityWatchCard(
        stationName: attributes.stationName,
        lineID: .district,
        direction: attributes.direction,
        directionFilter: attributes.directionFilter,
        condition: .good("Good service"),
        departures: DepartureActivityAttributes.ContentState.previewWatch.departures,
        isStale: false,
        deepLink: DeepLink.station(id: attributes.stationHubID, line: .district).url
    )
    .frame(width: 190, height: 80)
    .background(DepartureBoardStyle.background, in: .rect(cornerRadius: 14))
    .environment(\.colorScheme, .dark)
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: DepartureActivityAttributes.preview) {
    DepartureLiveActivity()
} contentStates: {
    DepartureActivityAttributes.ContentState.previewFresh
    DepartureActivityAttributes.ContentState.previewDisrupted
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: DepartureActivityAttributes.preview) {
    DepartureLiveActivity()
} contentStates: {
    DepartureActivityAttributes.ContentState.previewFresh
}

extension DepartureActivityAttributes {
    static var preview: DepartureActivityAttributes {
        DepartureActivityAttributes(
            activityID: "preview",
            stationHubID: "HUBOXC",
            stationName: "Oxford Circus",
            lineID: .central,
            direction: "Eastbound",
            directionFilter: .eastbound,
            startedAt: .now,
            hardEndsAt: .now.addingTimeInterval(DepartureActivityPolicy.maximumDuration)
        )
    }

    static var previewWatch: DepartureActivityAttributes {
        DepartureActivityAttributes(
            activityID: "watch-preview",
            stationHubID: "HUBMON",
            stationName: "Monument",
            lineID: .district,
            direction: "Westbound",
            directionFilter: .westbound,
            startedAt: .now,
            hardEndsAt: .now.addingTimeInterval(DepartureActivityPolicy.maximumDuration)
        )
    }
}

extension DepartureActivityAttributes.ContentState {
    private static func departure(_ id: String, _ destination: String, _ minutes: Double) -> Departure {
        Departure(
            id: id, destination: destination, platform: "Platform 2",
            expectedAt: .now.addingTimeInterval(minutes * 60)
        )
    }

    static var previewFresh: Self {
        .init(
            departures: [
                departure("1", "Hainault via Newbury Park", 0.5),
                departure("2", "Epping", 3),
                departure("3", "Hainault via Newbury Park", 5),
                departure("4", "Epping", 7),
            ],
            updatedAt: .now, conditionRank: 4, conditionHeadline: nil, sequence: 1
        )
    }

    static var previewWatch: Self {
        .init(
            departures: [
                departure("1", "Ealing Broadway", 0.5),
                departure("2", "Richmond", 4),
            ],
            updatedAt: .now, conditionRank: 4, conditionHeadline: nil, sequence: 1
        )
    }

    static var previewDisrupted: Self {
        .init(
            departures: [departure("1", "Epping", 4), departure("2", "Hainault", 11)],
            updatedAt: .now, conditionRank: 1, conditionHeadline: "Minor delays", sequence: 2
        )
    }

    static var previewEmpty: Self {
        .init(departures: [], updatedAt: .now, conditionRank: 2, conditionHeadline: "Service closed", sequence: 3)
    }

    static var previewSevere: Self {
        .init(
            departures: previewFresh.departures,
            updatedAt: .now, conditionRank: 0, conditionHeadline: "Severe delays", sequence: 4
        )
    }
}
