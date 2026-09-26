import Foundation
import TubeTrackCore

/// The shortest useful request cadence for a WidgetKit status timeline.
/// The system decides when it actually reloads the extension.
enum WatchStatusRefreshPolicy {
    static let requestInterval = WidgetRefreshPolicy.minimumInterval
    static let overdueGrace = WidgetRefreshPolicy.minimumInterval

    static func nextRequest(after date: Date) -> Date {
        date.addingTimeInterval(requestInterval)
    }
}

struct WatchStatusState: Sendable {
    let date: Date
    let rows: [LineStatusSummary]
    let updatedAt: Date?
    let isCached: Bool
    let failed: Bool

    var freshness: Freshness {
        .evaluate(updatedAt: updatedAt, now: date, isCached: isCached)
    }

    /// Allow five minutes for a requested reload before marking it overdue.
    var warningDate: Date? {
        updatedAt.map {
            WatchStatusRefreshPolicy.nextRequest(after: $0)
                .addingTimeInterval(WatchStatusRefreshPolicy.overdueGrace)
        }
    }

    var showsAgeWarning: Bool {
        guard !failed, !isCached, let warningDate else { return true }
        return date >= warningDate
    }

    var accessibilityFreshness: String {
        let summary = freshness.summary(at: date)
        return showsAgeWarning ? "Status may be out of date. \(summary)" : summary
    }

    func row(for lineID: TubeLineID) -> LineStatusSummary? {
        rows.first { $0.lineID == lineID }
    }
}

private struct WatchCachedStatus: Codable, Sendable {
    let statuses: [TfLLineStatus]
    let fetchedAt: Date
}

enum WatchStatusData {
    static func load(lineIDs: [TubeLineID], now: Date = .now) async -> WatchStatusState {
        let cache = SnapshotCache()
        do {
            let response = try await TubeTrackAPIClient(clientSurface: .watch).getSnapshot(
                "/api/v1/status", as: [TfLLineStatus].self
            )
            try? await cache.save(
                WatchCachedStatus(statuses: response.data, fetchedAt: response.updatedAt),
                named: "status.json"
            )
            return WatchStatusState(
                date: now,
                rows: LineStatusProjection.rows(from: response.data, lineIDs: lineIDs),
                updatedAt: response.updatedAt,
                // A normal one-minute server cache hit is still current status.
                isCached: response.stale,
                failed: false
            )
        } catch {
            if let remembered = try? await cache.load(WatchCachedStatus.self, named: "status.json") {
                return WatchStatusState(
                    date: now,
                    rows: LineStatusProjection.rows(from: remembered.statuses, lineIDs: lineIDs),
                    updatedAt: remembered.fetchedAt,
                    isCached: true,
                    failed: true
                )
            }
            return WatchStatusState(
                date: now,
                rows: [], updatedAt: nil, isCached: false, failed: true
            )
        }
    }

    static func sample(lineIDs: [TubeLineID], now: Date = .now) -> WatchStatusState {
        let rows = lineIDs.enumerated().map { index, lineID in
            LineStatusSummary(
                lineID: lineID,
                condition: index == 0 ? .minorDisruption("Minor delays") : .good("Good service"),
                reason: index == 0 ? "Minor delays due to an earlier signal failure." : nil
            )
        }
        return WatchStatusState(date: now, rows: rows, updatedAt: now, isCached: false, failed: false)
    }
}
