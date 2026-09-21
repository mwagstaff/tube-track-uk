import SwiftUI
import TubeTrackCore
import WidgetKit

struct StationDeparturesWidget: Widget {
    static let kind = "StationDeparturesWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: StationDeparturesConfigurationIntent.self,
            provider: StationDeparturesProvider()
        ) { entry in
            StationDeparturesWidgetView(entry: entry)
                .tubeTrackWidgetContainer()
        }
        .configurationDisplayName("Station Departures")
        .description("Next trains in each direction from a station you choose.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}

struct StationDeparturesWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: DeparturesEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                DeparturesSmallView(entry: entry).padding(14)
            case .systemMedium:
                DeparturesBoardView(entry: entry, style: .medium).padding(14)
            case .systemLarge:
                DeparturesBoardView(entry: entry, style: .large).padding(16)
            case .accessoryRectangular:
                DeparturesRectangularView(entry: entry)
            case .accessoryInline:
                DeparturesInlineView(entry: entry)
            case .accessoryCircular:
                DeparturesCircularView(entry: entry)
            default:
                DeparturesSmallView(entry: entry).padding(14)
            }
        }
        .widgetURL(entry.deepLink.url)
    }
}

extension DeparturesEntry {
    var deepLink: DeepLink {
        guard let station else { return .status }
        return .station(id: station.id, line: lineFilter)
    }

    var directionLabel: String {
        lineFilter.map(\.displayName) ?? "All lines"
    }
}

// MARK: - Shared pieces

private struct DepartureRow: View {
    let group: StationDepartureGroup
    let arrival: TfLArrivalPrediction
    let entry: DeparturesEntry
    var showsPlatform = true
    var destinationFont: Font = .subheadline
    var timeFont: Font = .subheadline.weight(.semibold)

    var body: some View {
        let destination = StationDepartureMetadata.destinationLabel(for: arrival)
        let platform = showsPlatform
            ? StationDepartureMetadata.platformLabel(for: arrival).map { Self.withoutDirection($0, direction: group.direction) }
            : nil
        let time = entry.timeLabel(for: arrival)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(destination)
                .font(destinationFont)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let platform {
                Text(platform)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(time)
                .font(timeFont)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.direction) to \(destination), \(time)")
    }
}

extension DepartureRow {
    /// "Northbound - Platform 5" under a "Northbound" header reads better as
    /// "Platform 5".
    static func withoutDirection(_ platform: String, direction: String) -> String {
        let prefix = direction.lowercased()
        guard platform.lowercased().hasPrefix(prefix) else { return platform }
        let remainder = platform.dropFirst(prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:"))
        return remainder.isEmpty ? platform : remainder
    }
}

private struct DirectionHeader: View {
    let group: StationDepartureGroup
    var showsLineName = true

    var body: some View {
        HStack(spacing: 6) {
            WidgetLineMark(lineID: group.lineID, size: 10)
            Text(showsLineName ? "\(group.lineID.displayName) · \(group.direction)" : group.direction)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityHidden(true)
    }
}

private struct DeparturesStateView: View {
    let entry: DeparturesEntry
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entry.needsConfiguration {
                Label("Choose a station", systemImage: "tram.fill")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                Text("Edit this widget to pick a station.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if entry.failed && entry.updatedAt == nil {
                Label("Departures unavailable", systemImage: "wifi.slash")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                Text(compact ? "Try again shortly." : "Live data could not be loaded. Tap refresh to try again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if entry.isCached, entry.arrivals.isEmpty {
                Label("Live data unavailable", systemImage: "clock.arrow.circlepath")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                Text(compact ? "Try again shortly." : "TfL predictions are out of date. Tap refresh to try again.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("No departures", systemImage: "moon.zzz.fill")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                if let issue = entry.worstIssue {
                    Text("\(issue.lineID.displayName): \(issue.condition.headline)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("No trains are predicted right now.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IssueChip: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let lineID: TubeLineID
    let condition: LineServiceCondition

    var body: some View {
        HStack(spacing: 4) {
            WidgetStatusGlyph(condition: condition, font: .caption2)
            Text(condition.headline)
                .font(.caption2.weight(.medium))
                .statusTint(condition, renderingMode: renderingMode)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lineID.displayName) line, \(condition.accessibilityDescription)")
    }
}

// MARK: - Home Screen

private struct DeparturesSmallView: View {
    let entry: DeparturesEntry

    var body: some View {
        let groups = entry.groups(maximumInformationLines: 4)
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.station?.name ?? "Departures")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if groups.isEmpty {
                DeparturesStateView(entry: entry, compact: true)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        DirectionHeader(group: group, showsLineName: entry.lineFilter == nil)
                        ForEach(group.arrivals, id: \.departureIdentity) { arrival in
                            DepartureRow(
                                group: group, arrival: arrival, entry: entry,
                                showsPlatform: false, destinationFont: .caption, timeFont: .callout.weight(.semibold)
                            )
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DeparturesBoardView: View {
    enum Style { case medium, large }

    let entry: DeparturesEntry
    let style: Style

    private var groups: [StationDepartureGroup] {
        switch style {
        case .medium:
            entry.groups(maximumInformationLines: 6)
        case .large:
            entry.allGroups().prefix(4).map { group in
                StationDepartureGroup(lineID: group.lineID, direction: group.direction, arrivals: Array(group.arrivals.prefix(3)))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .large ? 10 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.station?.name ?? "Departures")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                if let issue = entry.worstIssue {
                    IssueChip(lineID: issue.lineID, condition: issue.condition)
                } else if entry.lineFilter != nil {
                    Text(entry.directionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            let groups = groups
            if groups.isEmpty {
                DeparturesStateView(entry: entry, compact: false)
            } else {
                VStack(alignment: .leading, spacing: style == .large ? 8 : 4) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            DirectionHeader(group: group, showsLineName: entry.lineFilter == nil)
                            ForEach(group.arrivals, id: \.departureIdentity) { arrival in
                                DepartureRow(group: group, arrival: arrival, entry: entry)
                            }
                        }
                    }
                }
                .invalidatableContent()
            }
            Spacer(minLength: 0)
            WidgetFooter(
                updatedAt: entry.updatedAt,
                isCached: entry.isCached,
                failed: entry.failed,
                showsRefresh: !entry.needsConfiguration
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Lock Screen

private struct DeparturesRectangularView: View {
    let entry: DeparturesEntry

    var body: some View {
        let groups = entry.groups(maximumInformationLines: 4)
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.station?.name ?? "Departures")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if groups.isEmpty {
                Text(entry.needsConfiguration ? "Choose a station" : (entry.failed && entry.updatedAt == nil ? "Unavailable" : "No departures"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { group in
                    if let arrival = group.arrivals.first {
                        HStack(spacing: 4) {
                            WidgetLineMark(lineID: group.lineID, size: 8)
                            Text(group.direction.prefix(1).uppercased())
                                .font(.caption.weight(.bold))
                            Text(StationDepartureMetadata.destinationLabel(for: arrival))
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 2)
                            Text(entry.timeLabel(for: arrival))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(group.direction) to \(StationDepartureMetadata.destinationLabel(for: arrival)), \(entry.timeLabel(for: arrival))")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct DeparturesInlineView: View {
    let entry: DeparturesEntry

    var body: some View {
        let groups = entry.groups(maximumInformationLines: 4)
        if let station = entry.station, !groups.isEmpty {
            let parts = groups.compactMap { group -> String? in
                guard let arrival = group.arrivals.first else { return nil }
                return "\(group.direction.prefix(1).uppercased()) \(entry.timeLabel(for: arrival))"
            }
            Text("\(Image(systemName: "tram.fill")) \(station.name) · \(parts.joined(separator: " · "))")
        } else if let station = entry.station {
            Text("\(Image(systemName: "tram.fill")) \(station.name) · No departures")
        } else {
            Text("\(Image(systemName: "tram.fill")) Choose a station")
        }
    }
}

private struct DeparturesCircularView: View {
    let entry: DeparturesEntry

    var body: some View {
        let soonest = entry.allGroups().flatMap(\.arrivals).min { left, right in
            (left.expectedArrival ?? .distantFuture) < (right.expectedArrival ?? .distantFuture)
        }
        ZStack {
            AccessoryWidgetBackground()
            if let soonest, let lineID = TubeLineID(rawValue: soonest.lineId) {
                let label = entry.timeLabel(for: soonest)
                VStack(spacing: 0) {
                    Text(lineID.shortCode)
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                    if label == "Due" {
                        Text("Due")
                            .font(.title3.weight(.bold))
                    } else {
                        Text(label.replacingOccurrences(of: " min", with: ""))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        Text("min")
                            .font(.caption2)
                    }
                }
                .minimumScaleFactor(0.7)
                .padding(3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Next \(lineID.displayName) train \(label)")
            } else {
                Image(systemName: "tram.fill")
                    .font(.title3)
            }
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    StationDeparturesWidget()
} timeline: {
    DeparturesEntry.sample
}

#Preview("Medium", as: .systemMedium) {
    StationDeparturesWidget()
} timeline: {
    DeparturesEntry.sample
}

#Preview("Large", as: .systemLarge) {
    StationDeparturesWidget()
} timeline: {
    DeparturesEntry.sample
}

#Preview("Rectangular", as: .accessoryRectangular) {
    StationDeparturesWidget()
} timeline: {
    DeparturesEntry.sample
}

#Preview("Inline", as: .accessoryInline) {
    StationDeparturesWidget()
} timeline: {
    DeparturesEntry.sample
}

#Preview("Circular", as: .accessoryCircular) {
    StationDeparturesWidget()
} timeline: {
    DeparturesEntry.sample
}
