import SwiftUI
import TubeTrackCore
import WidgetKit

struct LineStatusWidget: Widget {
    static let kind = "LineStatusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: LineStatusConfigurationIntent.self,
            provider: LineStatusProvider()
        ) { entry in
            LineStatusWidgetView(entry: entry)
                .tubeTrackWidgetContainer()
        }
        .configurationDisplayName("Line Status")
        .description("Live service status for the lines you choose.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}

struct LineStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: LineStatusEntry

    var body: some View {
        switch family {
        case .systemSmall:
            LineStatusSmallView(entry: entry)
                .padding(14)
                .widgetURL(DeepLink.status.url)
        case .systemMedium:
            LineStatusListView(entry: entry, maximumRows: 4, showsReasons: false)
                .padding(14)
        case .systemLarge:
            LineStatusListView(entry: entry, maximumRows: 10, showsReasons: true)
                .padding(16)
        case .accessoryRectangular:
            LineStatusRectangularView(entry: entry)
                .widgetURL(DeepLink.status.url)
        case .accessoryInline:
            LineStatusInlineView(entry: entry)
                .widgetURL(DeepLink.status.url)
        case .accessoryCircular:
            LineStatusCircularView(entry: entry)
                .widgetURL(DeepLink.status.url)
        default:
            LineStatusSmallView(entry: entry)
                .padding(14)
        }
    }
}

// MARK: - Home Screen

private struct LineStatusSmallView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let entry: LineStatusEntry

    private static let maximumRows = 5

    var body: some View {
        if entry.rows.isEmpty {
            LineStatusEmptyView(entry: entry, compact: true)
        } else if entry.rows.count == 1, let row = entry.rows.first {
            hero(row)
        } else {
            list
        }
    }

    private func hero(_ row: LineStatusRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WidgetLineMark(lineID: row.lineID, size: 22)
                Spacer()
                WidgetStatusGlyph(condition: row.condition, font: .title3)
            }
            Spacer(minLength: 6)
            Text(row.lineID.displayName)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(row.condition.headline)
                .font(.subheadline.weight(.semibold))
                .statusTint(row.condition, renderingMode: renderingMode)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let reason = row.reason, row.condition.hasIssue {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.lineID.displayName) line, \(row.condition.accessibilityDescription)")
    }

    private var list: some View {
        let rows = entry.rows
        let shown = Array(rows.prefix(Self.maximumRows))
        let hidden = rows.count - shown.count
        // Two or three lines have room for the status wording; more lines
        // fall back to a glyph-only row so everything still fits.
        let roomy = rows.count <= 3
        return VStack(alignment: .leading, spacing: roomy ? 10 : 6) {
            ForEach(shown) { row in
                HStack(alignment: roomy ? .top : .center, spacing: 8) {
                    WidgetLineMark(lineID: row.lineID, size: roomy ? 13 : 11)
                        .padding(.top, roomy ? 3 : 0)
                    if roomy {
                        // The glyph sits inline with the status so the text keeps
                        // the full width, which matters once the mark becomes a
                        // short-code capsule in tinted rendering.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.lineID.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            HStack(spacing: 3) {
                                WidgetStatusGlyph(condition: row.condition, font: .caption2)
                                Text(row.condition.headline)
                                    .font(.caption)
                                    .statusTint(row.condition, renderingMode: renderingMode)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        Spacer(minLength: 0)
                    } else {
                        Text(row.lineID.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer(minLength: 4)
                        WidgetStatusGlyph(condition: row.condition, font: .caption)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.lineID.displayName), \(row.condition.accessibilityDescription)")
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LineStatusListView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let entry: LineStatusEntry
    let maximumRows: Int
    let showsReasons: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Line status")
                    .font(.headline)
                Spacer()
                summary
            }
            if entry.rows.isEmpty {
                LineStatusEmptyView(entry: entry, compact: false)
            } else {
                let shown = Array(entry.rows.prefix(maximumRows))
                VStack(alignment: .leading, spacing: showsReasons ? 8 : 6) {
                    ForEach(shown) { row in
                        Link(destination: DeepLink.line(row.lineID).url) {
                            statusRow(row)
                        }
                    }
                }
                .invalidatableContent()
                // Medium has no spare line; its header already says how many
                // lines have issues, which is what the passenger needs.
                if showsReasons, entry.rows.count > shown.count {
                    Text("+\(entry.rows.count - shown.count) more lines in the app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            WidgetFooter(
                updatedAt: entry.updatedAt,
                isCached: entry.isCached,
                failed: entry.failed,
                showsRefresh: true
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var summary: some View {
        let disrupted = entry.disruptedRows.count
        if !entry.rows.isEmpty {
            if disrupted == 0 {
                Label("All good", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(renderingMode == .fullColor ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            } else {
                Text("\(disrupted) with issues")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(_ row: LineStatusRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            WidgetLineMark(lineID: row.lineID, size: 12)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.lineID.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.condition.headline)
                        .font(.caption.weight(.medium))
                        .statusTint(row.condition, renderingMode: renderingMode)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    WidgetStatusGlyph(condition: row.condition, font: .caption)
                }
                if showsReasons, row.condition.hasIssue, let reason = row.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .font(.subheadline)
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.lineID.displayName) line, \(row.condition.accessibilityDescription)")
        .accessibilityHint("Opens the line in TubeTrack UK")
    }
}

private struct LineStatusEmptyView: View {
    let entry: LineStatusEntry
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Status unavailable", systemImage: "wifi.slash")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            Text(compact ? "Try again shortly." : "Live data could not be loaded. Tap refresh to try again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Lock Screen

private struct LineStatusRectangularView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    let entry: LineStatusEntry

    var body: some View {
        let rows = Array(entry.rowsBySeverity.prefix(3))
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                Text("Line status")
                    .font(.headline)
                Text(entry.failed ? "Unavailable" : "No lines chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    // On the Lock Screen the mark is already the line's short
                    // code, so the name would only crowd out the status.
                    HStack(spacing: 5) {
                        WidgetLineMark(lineID: row.lineID, size: 9)
                        if renderingMode == .fullColor {
                            Text(row.lineID.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(row.condition.headline)
                            .font(.caption.weight(renderingMode == .fullColor ? .regular : .semibold))
                            .foregroundStyle(renderingMode == .fullColor ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 2)
                        WidgetStatusGlyph(condition: row.condition, font: .caption2)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.lineID.displayName), \(row.condition.accessibilityDescription)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct LineStatusInlineView: View {
    let entry: LineStatusEntry

    var body: some View {
        if let worst = entry.rowsBySeverity.first {
            if worst.condition.hasIssue {
                let others = entry.disruptedRows.count - 1
                Text("\(Image(systemName: worst.condition.symbolName)) \(worst.lineID.displayName) · \(worst.condition.headline)\(others > 0 ? " · +\(others)" : "")")
            } else {
                Text("\(Image(systemName: "checkmark.circle.fill")) \(entry.rows.count == 1 ? worst.lineID.displayName : "All lines") · Good service")
            }
        } else {
            Text("\(Image(systemName: "wifi.slash")) Status unavailable")
        }
    }
}

private struct LineStatusCircularView: View {
    let entry: LineStatusEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let row = entry.rowsBySeverity.first {
                VStack(spacing: 1) {
                    Text(row.lineID.shortCode)
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Image(systemName: row.condition.symbolName)
                        .font(.title3)
                        .widgetAccentable()
                }
                .padding(4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.lineID.displayName), \(row.condition.accessibilityDescription)")
            } else {
                Image(systemName: "wifi.slash")
                    .font(.title3)
            }
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    LineStatusWidget()
} timeline: {
    LineStatusEntry.sample
    LineStatusEntry.sample(lineIDs: [.central])
}

#Preview("Medium", as: .systemMedium) {
    LineStatusWidget()
} timeline: {
    LineStatusEntry.sample
    LineStatusEntry(date: .now, rows: [], updatedAt: nil, isCached: false, failed: true)
}

#Preview("Large", as: .systemLarge) {
    LineStatusWidget()
} timeline: {
    LineStatusEntry.sample(lineIDs: TubeLineID.widgetDisplayOrder)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    LineStatusWidget()
} timeline: {
    LineStatusEntry.sample
}

#Preview("Inline", as: .accessoryInline) {
    LineStatusWidget()
} timeline: {
    LineStatusEntry.sample
}

#Preview("Circular", as: .accessoryCircular) {
    LineStatusWidget()
} timeline: {
    LineStatusEntry.sample
}
