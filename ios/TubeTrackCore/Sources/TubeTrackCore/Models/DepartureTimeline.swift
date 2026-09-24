import Foundation

/// Helpers for showing one set of predictions across a span of time, as a
/// widget timeline does: every entry is rendered against a later clock.
public enum DepartureTimeline {
    /// Trains shown as "Due" linger this long past their prediction before
    /// dropping off the board, matching the in-app departure boards.
    public static let departedGrace: TimeInterval = 30

    /// Predictions that only carry `timeToStation` would otherwise read the
    /// same at every later moment; pin them to a clock time once, relative to
    /// when the server produced them.
    public static func anchored(
        _ arrivals: [TfLArrivalPrediction],
        producedAt: Date
    ) -> [TfLArrivalPrediction] {
        arrivals.map { arrival in
            guard arrival.expectedArrival == nil, let seconds = arrival.timeToStation else { return arrival }
            return TfLArrivalPrediction(
                id: arrival.id,
                vehicleId: arrival.vehicleId,
                lineId: arrival.lineId,
                stationName: arrival.stationName,
                naptanId: arrival.naptanId,
                platformName: arrival.platformName,
                direction: arrival.direction,
                destinationName: arrival.destinationName,
                destinationNaptanId: arrival.destinationNaptanId,
                towards: arrival.towards,
                expectedArrival: producedAt.addingTimeInterval(TimeInterval(seconds)),
                timeToStation: seconds,
                currentLocation: arrival.currentLocation
            )
        }
    }

    /// The predictions still worth showing at `date`.
    public static func stillAhead(
        _ arrivals: [TfLArrivalPrediction],
        at date: Date
    ) -> [TfLArrivalPrediction] {
        arrivals.filter { arrival in
            guard let expected = arrival.expectedArrival else { return true }
            return expected.timeIntervalSince(date) > -departedGrace
        }
    }

    /// The most entries one snapshot is ever worth rendering into.
    public static let maximumEntries = 12

    /// When a widget should re-render the same snapshot.
    ///
    /// Countdowns change on the minute, so an entry per minute keeps the board
    /// exact without touching the network. There is no point rendering minutes
    /// beyond the snapshot's own shelf life, so the run stops at the staleness
    /// threshold and a final entry switches the board to its stale
    /// presentation — which is what the widget then shows until WidgetKit
    /// grants the next reload.
    public static func entryDates(
        now: Date,
        updatedAt: Date?,
        limit: Int = maximumEntries
    ) -> [Date] {
        guard limit > 0 else { return [now] }
        guard let updatedAt else { return [now] }

        let goesStaleAt = updatedAt.addingTimeInterval(Freshness.staleThreshold)
        guard goesStaleAt > now else { return [now] }

        var dates = [now]
        // Step in whole minutes from the snapshot, so entry boundaries line up
        // with the minute the labels actually change on.
        var candidate = updatedAt
        while candidate <= now {
            candidate.addTimeInterval(60)
        }
        while candidate < goesStaleAt, dates.count < limit - 1 {
            dates.append(candidate)
            candidate.addTimeInterval(60)
        }
        if dates.count < limit {
            dates.append(goesStaleAt)
        }
        return dates
    }
}
