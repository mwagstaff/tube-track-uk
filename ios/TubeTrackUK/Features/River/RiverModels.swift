import CoreLocation
import Foundation

struct RiverLine: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct RiverPier: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let lineIds: [String]
    let arrivalStopIds: [String]
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct RiverRoute: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let lineId: String
    let direction: String
    let stopIds: [String]
}

struct RiverNetwork: Codable, Sendable {
    let lines: [RiverLine]
    let piers: [RiverPier]
    let routes: [RiverRoute]
    static let empty = RiverNetwork(lines: [], piers: [], routes: [])

    func pier(_ id: String) -> RiverPier? { piers.first { $0.id == id } }
    func lineName(_ id: String) -> String { lines.first { $0.id == id }?.name ?? id.uppercased() }
}

struct RiverPrediction: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let vehicleId: String?
    let tripId: String?
    let pierId: String
    let lineId: String
    let direction: String?
    let destinationId: String?
    let destinationName: String?
    let expectedArrival: Date
    let observedAt: Date
    let expiresAt: Date?
    let terminatesHere: Bool

    var journeyKey: String? {
        guard let vehicleId, !vehicleId.isEmpty else { return nil }
        return [lineId, vehicleId, tripId ?? "", direction ?? "", destinationId ?? ""].joined(separator: ":")
    }

    func isCurrent(at date: Date) -> Bool {
        expectedArrival >= date && observedAt >= date.addingTimeInterval(-90)
            && observedAt <= date.addingTimeInterval(30) && (expiresAt == nil || expiresAt! >= date)
    }
}

struct RiverLineStatus: Codable, Identifiable, Sendable {
    struct Entry: Codable, Sendable {
        let description: String
        let reason: String?
        let severity: Int?
    }
    let id: String
    let name: String
    let entries: [Entry]
}

struct RiverBoardSnapshot: Codable, Sendable {
    let predictions: [RiverPrediction]
    let updatedAt: Date
    let stale: Bool

    func validUntil(lineId: String?) -> Date? {
        predictions.filter { !$0.terminatesHere && (lineId == nil || $0.lineId == lineId) }.map {
            min($0.expectedArrival, $0.observedAt.addingTimeInterval(90), $0.expiresAt ?? .distantFuture)
        }.max()
    }
}

/// One empty source update must not erase a board that still has valid boats.
/// A second distinct update confirms it; cached repeats cannot confirm it.
struct RiverBoardRefreshPolicy {
    private var emptyUpdatedAt: Date?

    mutating func resolve(_ incoming: RiverBoardSnapshot, previous: RiverBoardSnapshot?, now: Date) -> RiverBoardSnapshot {
        guard let previous else { return incoming }
        if incoming.updatedAt < previous.updatedAt || incoming.stale {
            return .init(predictions: previous.predictions, updatedAt: previous.updatedAt, stale: true)
        }
        let hasRecentDepartures = now.timeIntervalSince(previous.updatedAt) <= 90
            && previous.predictions.contains { !$0.terminatesHere }
        if incoming.predictions.isEmpty && hasRecentDepartures {
            if emptyUpdatedAt == nil || incoming.updatedAt <= emptyUpdatedAt! {
                emptyUpdatedAt = emptyUpdatedAt ?? incoming.updatedAt
                return .init(predictions: previous.predictions, updatedAt: previous.updatedAt, stale: true)
            }
        }
        emptyUpdatedAt = nil
        return incoming
    }
}

struct RiverStatusSnapshot: Codable, Sendable {
    let statuses: [RiverLineStatus]
    let updatedAt: Date
}

struct RiverSchematicAnchor: Codable, Identifiable, Sendable {
    let id: String
    let x: Double
    let y: Double
    let offsetX: Double
    let offsetY: Double
    let labelSide: Double
    let major: Bool
    var riverPoint: CGPoint { CGPoint(x: x, y: y) }
    var markerPoint: CGPoint { CGPoint(x: x + offsetX, y: y + offsetY) }
}

enum RiverBundle {
    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct EstimatedRiverBoat: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let lineId: String
    let previousPierId: String
    let nextPierId: String
    let destination: String?
    let segmentStartedAt: Date
    let expectedArrival: Date
    let observedAt: Date
    var expiresAt: Date? = nil
    var basis: String? = nil

    func progress(at date: Date) -> Double? {
        let duration = expectedArrival.timeIntervalSince(segmentStartedAt)
        guard duration >= 30, duration <= 1_800,
              date >= segmentStartedAt, date < expectedArrival,
              observedAt <= date.addingTimeInterval(30),
              expiresAt == nil || expiresAt! > date,
              date.timeIntervalSince(observedAt) <= 90 else { return nil }
        return min(1, max(0, date.timeIntervalSince(segmentStartedAt) / expectedArrival.timeIntervalSince(segmentStartedAt)))
    }
}

/// Legacy fallback for servers without the shared /river/boats endpoint.
/// A prediction identity is not guaranteed to be a physical vessel identifier.
/// Only a witnessed transition between consecutive calling piers establishes a
/// segment. The first snapshot never creates a fleet of guessed boats.
struct RiverBoatEstimator {
    private var previous: [String: RiverPrediction] = [:]
    private var segments: [String: EstimatedRiverBoat] = [:]
    private var followingPier: [String: String] = [:]

    mutating func update(_ predictions: [RiverPrediction], network: RiverNetwork, at date: Date) -> [EstimatedRiverBoat] {
        let groups = Dictionary(grouping: predictions.filter { $0.isCurrent(at: date) && $0.journeyKey != nil }, by: { $0.journeyKey! })
        var next: [String: RiverPrediction] = [:]
        var nextFollowing: [String: String] = [:]
        // Missing/empty responses can retain a still-valid segment, but never
        // advance its source age or its arrival boundary.
        var result = segments.filter { $0.value.progress(at: date) != nil }
        for (key, values) in groups {
            guard let target = values.min(by: { $0.expectedArrival < $1.expectedArrival }) else { continue }
            if let old = previous[key], target.observedAt < old.observedAt.addingTimeInterval(target.pierId == old.pierId ? 0 : -1) { continue }
            result.removeValue(forKey: key)
            // Conflicting predictions at the same ETA cannot identify a segment.
            guard !values.contains(where: { $0.pierId != target.pierId && abs($0.expectedArrival.timeIntervalSince(target.expectedArrival)) < 10 }) else { continue }
            next[key] = target
            nextFollowing[key] = values.filter { $0.pierId != target.pierId && $0.expectedArrival > target.expectedArrival }
                .min(by: { $0.expectedArrival < $1.expectedArrival })?.pierId
            let start: (String, Date)?
            if let segment = segments[key], segment.nextPierId == target.pierId,
               date.timeIntervalSince(segment.observedAt) <= 90 {
                start = (segment.previousPierId, segment.segmentStartedAt)
            } else if let old = previous[key], old.pierId != target.pierId,
                      target.observedAt >= old.observedAt.addingTimeInterval(-1),
                      date.timeIntervalSince(old.observedAt) <= 90,
                      old.expectedArrival <= date,
                      date.timeIntervalSince(old.expectedArrival) <= 90 {
                start = (old.pierId, old.expectedArrival)
            } else { start = nil }
            guard let (from, startedAt) = start else { continue }
            let witnessedCallingPair = followingPier[key] == target.pierId
                || (segments[key]?.previousPierId == from && segments[key]?.nextPierId == target.pierId)
            let matchingRoutes = network.routes.filter { route in
                guard route.lineId == target.lineId,
                      target.direction == nil || target.direction == route.direction,
                      let index = route.stopIds.firstIndex(of: from),
                      let targetIndex = route.stopIds.firstIndex(of: target.pierId), targetIndex > index,
                      targetIndex == index + 1 || witnessedCallingPair else { return false }
                if let destination = target.destinationId {
                    return route.stopIds[targetIndex...].contains(destination)
                }
                return true
            }
            let duration = target.expectedArrival.timeIntervalSince(startedAt)
            guard !matchingRoutes.isEmpty, duration >= 30, duration <= 1_800 else { continue }
            result[key] = EstimatedRiverBoat(
                id: key, lineId: target.lineId, previousPierId: from, nextPierId: target.pierId,
                destination: target.destinationName, segmentStartedAt: startedAt,
                expectedArrival: target.expectedArrival, observedAt: target.observedAt,
                expiresAt: min(target.expectedArrival, target.observedAt.addingTimeInterval(90)), basis: "observedTransition"
            )
        }
        // An empty poll is not proof that a vessel vanished. Retain only the
        // short-lived observation history, never invent a segment or renew age.
        previous = previous.filter { !groups.keys.contains($0.key) && date.timeIntervalSince($0.value.observedAt) <= 90 }
            .merging(next) { _, new in new }
        followingPier = followingPier.filter { previous[$0.key] != nil && !groups.keys.contains($0.key) }
            .merging(nextFollowing) { _, new in new }
        segments = result
        return result.values.sorted { $0.id < $1.id }
    }
}
