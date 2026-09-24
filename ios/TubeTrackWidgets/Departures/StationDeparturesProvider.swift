import Foundation
import OSLog
import TubeTrackCore
import WidgetKit

struct DeparturesEntry: TimelineEntry, Sendable {
    let date: Date
    let station: StationHub?
    let lineFilter: TubeLineID?
    let direction: DepartureDirectionFilter
    /// Predictions still ahead of `date`. Views group and budget these per
    /// family and label them relative to `date`, so one fetch yields a
    /// timeline whose minutes tick without reloading.
    let arrivals: [TfLArrivalPrediction]
    let lineConditions: [TubeLineID: LineServiceCondition]
    let freshness: Freshness
    let failed: Bool

    var needsConfiguration: Bool { station == nil }
    var updatedAt: Date? { freshness.updatedAt }
    var isCached: Bool { freshness.isCached }

    /// The most disruptive condition among the lines on show, if any has an issue.
    var worstIssue: (lineID: TubeLineID, condition: LineServiceCondition)? {
        let candidates = lineConditions
            .filter { lineFilter == nil || $0.key == lineFilter }
            .filter(\.value.hasIssue)
        return candidates.min { $0.value.severityRank < $1.value.severityRank }
            .map { ($0.key, $0.value) }
    }

    func groups(maximumInformationLines: Int) -> [StationDepartureGroup] {
        withDirectionApplied(CompactStationDeparturePolicy.groups(
            from: arrivals,
            for: lineFilter,
            maximumInformationLines: maximumInformationLines
        ))
    }

    func allGroups() -> [StationDepartureGroup] {
        withDirectionApplied(StationDepartureGroup.groups(from: arrivals, for: lineFilter))
    }

    /// The one queue of trains to show when the passenger pinned a line *and* a
    /// direction — the single-queue layout only makes sense when both are set,
    /// since "Northbound" at an interchange means several different queues.
    ///
    /// `nil` also when this station labels its platforms in a way the chosen
    /// direction never matches, so the widget shows the ordinary board rather
    /// than claiming a direction it cannot honour.
    var focusedGroup: StationDepartureGroup? {
        guard direction != .any, let lineFilter else { return nil }
        return StationDepartureGroup.groups(from: arrivals, for: lineFilter)
            .matching(direction)
            .first { !$0.arrivals.isEmpty }
    }

    /// Never blank the board: an unmatched direction falls back to every group.
    private func withDirectionApplied(_ groups: [StationDepartureGroup]) -> [StationDepartureGroup] {
        let matched = groups.matching(direction)
        return matched.isEmpty ? groups : matched
    }

    /// The countdown label. Only meaningful while `freshness.showsCountdowns`;
    /// past that the views show the predicted clock time instead, which stays
    /// true however old the snapshot gets.
    func timeLabel(for arrival: TfLArrivalPrediction) -> String {
        StationDepartureMetadata.departureTime(for: arrival, now: date)
    }
}

struct StationDeparturesProvider: AppIntentTimelineProvider {
    static let retryInterval: TimeInterval = 5 * 60
    static let cacheLifetime: TimeInterval = 15 * 60

    private static let logger = Logger(subsystem: "dev.skynolimit.TubeTrackUK.Widgets", category: "Departures")

    func placeholder(in context: Context) -> DeparturesEntry {
        .sample
    }

    func snapshot(for configuration: StationDeparturesConfigurationIntent, in context: Context) async -> DeparturesEntry {
        if context.isPreview { return .sample }
        return await load(configuration).first ?? .sample
    }

    func timeline(for configuration: StationDeparturesConfigurationIntent, in context: Context) async -> Timeline<DeparturesEntry> {
        let entries = await load(configuration)
        guard let first = entries.first else {
            return Timeline(entries: [.sample], policy: .after(.now.addingTimeInterval(Self.retryInterval)))
        }
        if first.needsConfiguration {
            return Timeline(entries: [first], policy: .never)
        }
        if first.failed && first.updatedAt == nil {
            return Timeline(entries: [first], policy: .after(first.date.addingTimeInterval(Self.retryInterval)))
        }
        // WidgetKit grants a frequently-viewed widget roughly 40–70 reloads a
        // day; asking for more just gets us throttled into staleness.
        return Timeline(entries: entries, policy: .after(WidgetRefreshPolicy.nextReload(after: first.date)))
    }

    private func load(_ configuration: StationDeparturesConfigurationIntent) async -> [DeparturesEntry] {
        let now = Date.now
        let direction = configuration.selectedDirection
        guard let stationEntity = configuration.station,
              let hub = StationIndex.bundled.hub(containing: stationEntity.id) else {
            return [DeparturesEntry(
                date: now, station: nil, lineFilter: nil, direction: direction, arrivals: [],
                lineConditions: [:], freshness: .evaluate(updatedAt: nil, now: now), failed: false
            )]
        }
        let lineFilter = configuration.selectedLineID
        let client = TubeTrackAPIClient()
        let cache = SnapshotCache()
        let cacheName = "widget-arrivals-\(hub.id).json"

        async let conditions = Self.loadConditions(for: hub.lineIDs, client: client)

        let arrivals: [TfLArrivalPrediction]
        let fetchedAt: Date
        let isCached: Bool
        let failed: Bool
        do {
            let snapshot = try await StationArrivalsService(client: client).fetchSnapshot(stationIDs: hub.stopIDs)
            // Predictions without a clock time are pinned to the server's
            // refresh time, not ours: if the server is serving old data the
            // trains have already gone and must not read as "Due".
            let anchor = snapshot.serverUpdatedAt ?? snapshot.fetchedAt
            arrivals = DepartureTimeline.anchored(snapshot.arrivals, producedAt: anchor)
            fetchedAt = anchor
            isCached = snapshot.cached || snapshot.isStale
            failed = false
            Self.logger.notice("Fetched \(snapshot.arrivals.count) arrivals for \(hub.id, privacy: .public); server updated \(anchor, privacy: .public) stale=\(snapshot.isStale); ahead now: \(DepartureTimeline.stillAhead(arrivals, at: now).count)")
            try? await cache.save(CachedArrivals(arrivals: arrivals, fetchedAt: fetchedAt), named: cacheName)
        } catch {
            Self.logger.warning("Arrivals fetch failed for \(hub.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if let cached = try? await cache.load(CachedArrivals.self, named: cacheName),
               now.timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
                arrivals = cached.arrivals
                fetchedAt = cached.fetchedAt
                isCached = true
                failed = true
            } else {
                return [DeparturesEntry(
                    date: now, station: hub, lineFilter: lineFilter, direction: direction, arrivals: [],
                    lineConditions: await conditions, freshness: .evaluate(updatedAt: nil, now: now), failed: true
                )]
            }
        }
        let lineConditions = await conditions

        return DepartureTimeline.entryDates(now: now, updatedAt: fetchedAt).map { entryDate in
            DeparturesEntry(
                date: entryDate,
                station: hub,
                lineFilter: lineFilter,
                direction: direction,
                arrivals: DepartureTimeline.stillAhead(arrivals, at: entryDate),
                lineConditions: lineConditions,
                freshness: .evaluate(updatedAt: fetchedAt, now: entryDate, isCached: isCached),
                failed: failed
            )
        }
    }

    private static func loadConditions(
        for lineIDs: [TubeLineID],
        client: TubeTrackAPIClient
    ) async -> [TubeLineID: LineServiceCondition] {
        guard let statuses: [TfLLineStatus] = try? await client.get("/api/v1/status") else { return [:] }
        var conditions: [TubeLineID: LineServiceCondition] = [:]
        for status in statuses where lineIDs.contains(status.id) {
            conditions[status.id] = LineServiceCondition.condition(for: status)
        }
        return conditions
    }
}

private struct CachedArrivals: Codable, Sendable {
    let arrivals: [TfLArrivalPrediction]
    let fetchedAt: Date
}

extension DeparturesEntry {
    static var sample: DeparturesEntry {
        let now = Date.now
        func arrival(_ id: String, _ line: TubeLineID, _ platform: String, _ destination: String, _ seconds: Int) -> TfLArrivalPrediction {
            TfLArrivalPrediction(
                id: id, vehicleId: nil, lineId: line.rawValue, stationName: "Oxford Circus Underground Station",
                naptanId: "940GZZLUOXC", platformName: platform, direction: nil,
                destinationName: destination, destinationNaptanId: nil, towards: nil,
                expectedArrival: now.addingTimeInterval(TimeInterval(seconds)), timeToStation: seconds, currentLocation: nil
            )
        }
        return DeparturesEntry(
            date: now,
            station: StationHub(
                id: "HUBOXC", name: "Oxford Circus", stopIDs: ["940GZZLUOXC"],
                lineIDs: [.bakerloo, .central, .victoria]
            ),
            lineFilter: nil,
            direction: .any,
            arrivals: [
                arrival("1", .central, "Eastbound - Platform 2", "Epping Underground Station", 120),
                arrival("2", .central, "Eastbound - Platform 2", "Hainault Underground Station", 300),
                arrival("3", .central, "Westbound - Platform 1", "Ealing Broadway Underground Station", 240),
                arrival("4", .central, "Westbound - Platform 1", "West Ruislip Underground Station", 420),
                arrival("5", .victoria, "Northbound - Platform 3", "Walthamstow Central Underground Station", 60),
                arrival("6", .victoria, "Southbound - Platform 4", "Brixton Underground Station", 180),
                arrival("7", .bakerloo, "Northbound - Platform 5", "Queen's Park Underground Station", 360),
                arrival("8", .bakerloo, "Southbound - Platform 6", "Elephant & Castle Underground Station", 30),
            ],
            lineConditions: [.central: .minorDisruption("Minor delays"), .victoria: .good("Good service"), .bakerloo: .good("Good service")],
            freshness: .evaluate(updatedAt: now, now: now),
            failed: false
        )
    }
}
