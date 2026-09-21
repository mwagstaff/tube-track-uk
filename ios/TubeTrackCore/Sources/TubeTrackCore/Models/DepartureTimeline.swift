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
}
