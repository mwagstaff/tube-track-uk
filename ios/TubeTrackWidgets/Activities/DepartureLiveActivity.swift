import ActivityKit
import SwiftUI
import TubeTrackCore
import WidgetKit

/// The Lock Screen and Dynamic Island presentation of a tracked departure board.
///
/// The activity cannot fetch anything: it renders the last state it was handed
/// and lets SwiftUI's date-relative text carry the countdown forward between
/// pushes. When iOS marks the content stale, the countdowns are replaced by the
/// clock times they were predicted for — a statement that stays true no matter
/// how long the silence lasts.
struct DepartureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DepartureActivityAttributes.self) { context in
            DepartureActivityLockScreenView(context: context)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        WidgetLineMark(lineID: context.lineID, size: 12)
                        Text(context.attributes.direction)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(context.followingDepartures) { departure in
                            DepartureActivityRow(
                                departure: departure, isStale: context.isStale, font: .caption
                            )
                        }
                        DepartureActivityFooter(context: context)
                    }
                }
            } compactLeading: {
                WidgetLineMark(lineID: context.lineID, size: 10)
            } compactTrailing: {
                DepartureCountdown(
                    departure: context.nextDeparture,
                    isStale: context.isStale,
                    font: .caption2.weight(.semibold)
                )
                .frame(maxWidth: 52)
            } minimal: {
                WidgetLineMark(lineID: context.lineID, size: 10)
            }
            .keylineTint(Color.tubeLine(context.lineID))
            .widgetURL(context.deepLink)
        }
    }
}

// MARK: - Lock Screen

private struct DepartureActivityLockScreenView: View {
    let context: ActivityViewContext<DepartureActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WidgetLineMark(lineID: context.lineID, size: 11)
                Text("\(context.lineID.displayName) · \(context.attributes.direction)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                if let condition = context.condition, condition.hasIssue {
                    WidgetStatusGlyph(condition: condition, font: .caption)
                }
                Button(intent: EndDepartureTrackingIntent(activityID: context.attributes.activityID)) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Stop tracking")
            }

            Text(context.attributes.stationName)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if context.visibleDepartures.isEmpty {
                Text("No more departures")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(context.visibleDepartures) { departure in
                    DepartureActivityRow(
                        departure: departure, isStale: context.isStale, font: .subheadline
                    )
                }
            }

            DepartureActivityFooter(context: context)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pieces

private struct DepartureActivityRow: View {
    let departure: DepartureActivityAttributes.ContentState.Departure
    let isStale: Bool
    var font: Font = .subheadline

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(departure.destination)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let platform = departure.platform {
                Text(platform)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            DepartureCountdown(departure: departure, isStale: isStale, font: font.weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let time = departure.expectedAt.formatted(date: .omitted, time: .shortened)
        return isStale
            ? "\(departure.destination), predicted \(time)"
            : "\(departure.destination), \(time)"
    }
}

/// The countdown itself. While the data is current this is a live, ticking
/// relative time that needs no pushes to stay right; once iOS marks the
/// activity stale it becomes the clock time the train was predicted for.
private struct DepartureCountdown: View {
    let departure: DepartureActivityAttributes.ContentState.Departure?
    let isStale: Bool
    var font: Font = .subheadline

    var body: some View {
        Group {
            if let departure {
                if isStale {
                    Text(departure.expectedAt, style: .time)
                        .foregroundStyle(.secondary)
                } else {
                    Text(departure.expectedAt, style: .relative)
                }
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
        .font(font)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct DepartureActivityFooter: View {
    let context: ActivityViewContext<DepartureActivityAttributes>

    var body: some View {
        HStack(spacing: 4) {
            if context.isStale {
                Label("Live updates paused", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
            } else if let headline = context.state.conditionHeadline {
                Text(headline)
            } else {
                Text("Updated \(context.state.updatedAt, style: .time)")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Context conveniences

private extension ActivityViewContext<DepartureActivityAttributes> {
    var lineID: TubeLineID { attributes.lineID ?? .central }

    var condition: LineServiceCondition? {
        LineServiceCondition(severityRank: state.conditionRank, headline: state.conditionHeadline)
    }

    /// Departures still ahead. A stale activity keeps showing what it last
    /// knew — dropping rows as the clock passes them would imply the board is
    /// still being updated.
    var visibleDepartures: [DepartureActivityAttributes.ContentState.Departure] {
        isStale ? state.departures : state.upcoming(at: .now)
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
    DepartureActivityAttributes.ContentState.previewEmpty
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
            stationHubID: "HUBKTN",
            stationName: "Kentish Town",
            lineID: .northern,
            direction: "Southbound",
            directionFilter: .southbound,
            startedAt: .now,
            hardEndsAt: .now.addingTimeInterval(DepartureActivityPolicy.maximumDuration)
        )
    }
}

extension DepartureActivityAttributes.ContentState {
    private static func departure(_ id: String, _ destination: String, _ minutes: Double) -> Departure {
        Departure(
            id: id, destination: destination, platform: "Platform 8",
            expectedAt: .now.addingTimeInterval(minutes * 60)
        )
    }

    static var previewFresh: Self {
        .init(
            departures: [
                departure("1", "Morden", 2),
                departure("2", "Morden", 6),
                departure("3", "Kennington", 9),
            ],
            updatedAt: .now, conditionRank: 4, conditionHeadline: nil, sequence: 1
        )
    }

    static var previewDisrupted: Self {
        .init(
            departures: [departure("1", "Kennington", 4), departure("2", "Morden", 11)],
            updatedAt: .now, conditionRank: 1, conditionHeadline: "Minor delays", sequence: 2
        )
    }

    static var previewEmpty: Self {
        .init(departures: [], updatedAt: .now, conditionRank: 2, conditionHeadline: "Service closed", sequence: 3)
    }
}
