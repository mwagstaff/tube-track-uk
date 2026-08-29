import Foundation

struct TfLLineStatus: Codable, Identifiable, Equatable, Sendable {
    let id: TubeLineID
    let name: String
    let lineStatuses: [TfLStatusEntry]
}

struct TfLStatusEntry: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let statusSeverity: Int
    let statusSeverityDescription: String
    let reason: String?
    let validityPeriods: [TfLValidityPeriod]?
    let disruption: TfLDisruption?

    var isGoodService: Bool { statusSeverity == 10 || statusSeverity == 18 }

    var isServiceClosed: Bool {
        statusSeverity == 20
            || statusSeverityDescription.localizedCaseInsensitiveCompare("Service Closed")
                == .orderedSame
    }

    var isOvernightClosure: Bool {
        guard statusSeverity == 20 else { return false }
        let text = reason?.lowercased() ?? ""
        return text.contains("service will resume")
            || text.contains("resume later this morning")
            || text.contains("service is closed")
    }

    var isActionableIssue: Bool {
        !isGoodService && !isOvernightClosure
    }
}

struct TfLValidityPeriod: Codable, Equatable, Sendable {
    let fromDate: Date?
    let toDate: Date?
    let isNow: Bool?
}

struct TfLDisruption: Codable, Equatable, Sendable {
    let category: String?
    let categoryDescription: String?
    let description: String?
    let affectedRoutes: [TfLDisruptedRoute]?
    let affectedStops: [TfLStopPoint]?
    let closureText: String?
}

struct TfLDisruptedRoute: Codable, Equatable, Sendable {
    let id: String?
    let name: String?
    let direction: String?
    let originationName: String?
    let destinationName: String?
    let isEntireRouteSection: Bool?
    let routeSectionNaptanEntrySequence: [TfLRouteStopEntry]?
}

struct TfLRouteStopEntry: Codable, Equatable, Sendable {
    let ordinal: Int?
    let stopPoint: TfLStopPoint?
}

struct TfLStopPoint: Codable, Equatable, Sendable {
    let naptanId: String?
    let id: String?
    let commonName: String?
    let lat: Double?
    let lon: Double?
}

struct TfLArrivalPrediction: Codable, Sendable {
    let id: String
    let vehicleId: String?
    let lineId: String
    let stationName: String?
    let naptanId: String?
    let platformName: String?
    let direction: String?
    let destinationName: String?
    let destinationNaptanId: String?
    let towards: String?
    let expectedArrival: Date?
    let timeToStation: Int?
    let currentLocation: String?

    /// TfL's `id` is not unique for every departure. DLR predictions, in
    /// particular, can reuse one value for an entire station board, so use the
    /// fields that describe an individual prediction whenever the app needs a
    /// stable identity or removes exact duplicates.
    var departureIdentity: DepartureIdentity {
        DepartureIdentity(
            sourceID: id,
            vehicleID: Self.normalized(vehicleId),
            lineID: lineId,
            stationID: Self.normalized(naptanId),
            platformName: Self.normalized(platformName),
            direction: Self.normalized(direction),
            destinationID: Self.normalized(destinationNaptanId),
            destinationName: Self.normalized(destinationName),
            towards: Self.normalized(towards),
            expectedArrival: expectedArrival,
            fallbackTimeToStation: expectedArrival == nil ? timeToStation : nil
        )
    }

    struct DepartureIdentity: Hashable, Sendable {
        let sourceID: String
        let vehicleID: String?
        let lineID: String
        let stationID: String?
        let platformName: String?
        let direction: String?
        let destinationID: String?
        let destinationName: String?
        let towards: String?
        let expectedArrival: Date?
        let fallbackTimeToStation: Int?
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// The subset of a TfL arrival prediction needed to estimate a vehicle's
/// position. Keeping this separate from station departures avoids decoding
/// thousands of unused strings and ISO-8601 dates on every network-wide poll.
struct TfLLiveTrainPrediction: Decodable, Sendable {
    let vehicleId: String?
    let lineId: String
    let naptanId: String?
    let direction: String?
    let destinationName: String?
    let destinationNaptanId: String?
    let towards: String?
    let timeToStation: Int?
    let currentLocation: String?
    let platformName: String?
}

extension JSONDecoder {
    static var tfl: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.tfl.date(from: value)
                ?? ISO8601DateFormatter.tflWithoutFractionalSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid TfL date: \(value)")
        }
        return decoder
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let tfl: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let tflWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
