import Foundation
import OSLog
import TubeTrackCore
import WidgetKit

struct LineStatusRow: Identifiable, Sendable {
    let lineID: TubeLineID
    let condition: LineServiceCondition
    let reason: String?

    var id: TubeLineID { lineID }
}

struct LineStatusEntry: TimelineEntry, Sendable {
    let date: Date
    let rows: [LineStatusRow]
    let updatedAt: Date?
    let isCached: Bool
    let failed: Bool

    var freshness: Freshness {
        .evaluate(updatedAt: updatedAt, now: date, isCached: isCached)
    }

    /// Rows ordered worst first, for the summary-style families.
    var rowsBySeverity: [LineStatusRow] {
        rows.sorted { left, right in
            if left.condition.severityRank != right.condition.severityRank {
                return left.condition.severityRank < right.condition.severityRank
            }
            return left.lineID.widgetDisplayRank < right.lineID.widgetDisplayRank
        }
    }

    var disruptedRows: [LineStatusRow] { rows.filter(\.condition.hasIssue) }
}

struct LineStatusProvider: AppIntentTimelineProvider {
    static let retryInterval: TimeInterval = 5 * 60

    private static let logger = Logger(subsystem: "dev.skynolimit.TubeTrackUK.Widgets", category: "LineStatus")

    func placeholder(in context: Context) -> LineStatusEntry {
        .sample
    }

    func snapshot(for configuration: LineStatusConfigurationIntent, in context: Context) async -> LineStatusEntry {
        if context.isPreview { return .sample(for: configuration) }
        return await load(configuration)
    }

    func timeline(for configuration: LineStatusConfigurationIntent, in context: Context) async -> Timeline<LineStatusEntry> {
        let entry = await load(configuration)
        let nextReload = entry.failed && entry.updatedAt == nil
            ? entry.date.addingTimeInterval(Self.retryInterval)
            : WidgetRefreshPolicy.nextReload(after: entry.date)
        // Status changes are rare and mostly arrive by push; spend the reload
        // budget where it earns its keep. Entries between fetches only advance
        // the displayed age of the same snapshot; they never imply new data.
        return Timeline(entries: Self.ageEntries(from: entry, until: nextReload), policy: .after(nextReload))
    }

    private static func ageEntries(from entry: LineStatusEntry, until reload: Date) -> [LineStatusEntry] {
        guard let updatedAt = entry.updatedAt else { return [entry] }
        var entries = [entry]
        let age = max(0, entry.date.timeIntervalSince(updatedAt))
        var next = updatedAt.addingTimeInterval((floor(age / 60) + 1) * 60)
        while next < reload {
            entries.append(LineStatusEntry(date: next, rows: entry.rows, updatedAt: updatedAt,
                isCached: entry.isCached, failed: entry.failed))
            next.addTimeInterval(60)
        }
        return entries
    }

    private func load(_ configuration: LineStatusConfigurationIntent) async -> LineStatusEntry {
        let now = Date.now
        let lineIDs = configuration.selectedLineIDs
        Self.logger.notice("Loading status for \(lineIDs.count) lines (\(configuration.lines.count) configured)")
        do {
            let response = try await TubeTrackAPIClient(clientSurface: .widget).getSnapshot(
                "/api/v1/status", as: [TfLLineStatus].self
            )
            return LineStatusEntry(
                date: now,
                rows: Self.rows(from: response.data, lineIDs: lineIDs, disruptionsFirst: configuration.disruptionsFirst),
                updatedAt: response.updatedAt,
                isCached: response.cached || response.stale,
                failed: false
            )
        } catch {
            Self.logger.warning("Status fetch failed: \(error.localizedDescription, privacy: .public)")
            if let cached = try? await SnapshotCache().load(CachedStatusSnapshot.self, named: "status.json") {
                return LineStatusEntry(
                    date: now,
                    rows: Self.rows(from: cached.statuses, lineIDs: lineIDs, disruptionsFirst: configuration.disruptionsFirst),
                    updatedAt: cached.fetchedAt,
                    isCached: true,
                    failed: true
                )
            }
            return LineStatusEntry(date: now, rows: [], updatedAt: nil, isCached: false, failed: true)
        }
    }

    static func rows(
        from statuses: [TfLLineStatus],
        lineIDs: [TubeLineID],
        disruptionsFirst: Bool
    ) -> [LineStatusRow] {
        let rows = LineStatusProjection.rows(from: statuses, lineIDs: lineIDs)
            .map { LineStatusRow(lineID: $0.lineID, condition: $0.condition, reason: $0.reason) }
        guard disruptionsFirst else { return rows }
        return rows.sorted { left, right in
            let leftIssue = left.condition.hasIssue, rightIssue = right.condition.hasIssue
            if leftIssue != rightIssue { return leftIssue }
            if leftIssue, left.condition.severityRank != right.condition.severityRank {
                return left.condition.severityRank < right.condition.severityRank
            }
            return left.lineID.widgetDisplayRank < right.lineID.widgetDisplayRank
        }
    }
}

extension LineStatusProvider {
    /// TfL prefixes every reason with the line ("Central Line: Minor delays…").
    /// The row already names the line, so drop it to make room for the detail.
    static func trimmedReason(_ reason: String) -> String {
        LineStatusProjection.trimmedReason(reason)
    }
}

/// The subset of the app's `TubeStatusSnapshot` the widget needs; extra keys
/// in `status.json` are ignored.
private struct CachedStatusSnapshot: Codable, Sendable {
    let statuses: [TfLLineStatus]
    let fetchedAt: Date
}

extension LineStatusEntry {
    static var sample: LineStatusEntry {
        sample(lineIDs: [.central, .circle, .district, .victoria, .jubilee, .northern])
    }

    static func sample(for configuration: LineStatusConfigurationIntent) -> LineStatusEntry {
        sample(lineIDs: configuration.selectedLineIDs)
    }

    static func sample(lineIDs: [TubeLineID]) -> LineStatusEntry {
        let now = Date.now
        let rows = lineIDs.enumerated().map { index, lineID -> LineStatusRow in
            switch index {
            case 0:
                LineStatusRow(
                    lineID: lineID,
                    condition: .majorDisruption("Part suspended"),
                    reason: "No service between Oxford Circus and Holborn while we fix a signal failure."
                )
            case 1:
                LineStatusRow(lineID: lineID, condition: .minorDisruption("Minor delays"), reason: "Minor delays due to an earlier fault.")
            default:
                LineStatusRow(lineID: lineID, condition: .good("Good service"), reason: nil)
            }
        }
        return LineStatusEntry(date: now, rows: rows, updatedAt: now, isCached: false, failed: false)
    }
}
