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

enum LineServiceClosurePolicy {
    static func closedLineIDs(in statuses: [TfLLineStatus]) -> Set<TubeLineID> {
        Set(statuses.compactMap { line in
            line.lineStatuses.contains(where: \.isServiceClosed) ? line.id : nil
        })
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

    private enum CodingKeys: String, CodingKey {
        case id, vehicleId, lineId, stationName, naptanId, stopId, platformName
        case direction, destinationName, destinationNaptanId, destinationStopId
        case towards, expectedArrival, timeToStation, currentLocation
    }

    init(
        id: String,
        vehicleId: String?,
        lineId: String,
        stationName: String?,
        naptanId: String?,
        platformName: String?,
        direction: String?,
        destinationName: String?,
        destinationNaptanId: String?,
        towards: String?,
        expectedArrival: Date?,
        timeToStation: Int?,
        currentLocation: String?
    ) {
        self.id = id
        self.vehicleId = vehicleId
        self.lineId = lineId
        self.stationName = stationName
        self.naptanId = naptanId
        self.platformName = platformName
        self.direction = direction
        self.destinationName = destinationName
        self.destinationNaptanId = destinationNaptanId
        self.towards = towards
        self.expectedArrival = expectedArrival
        self.timeToStation = timeToStation
        self.currentLocation = currentLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        vehicleId = try container.decodeIfPresent(String.self, forKey: .vehicleId)
        lineId = try container.decode(String.self, forKey: .lineId)
        stationName = try container.decodeIfPresent(String.self, forKey: .stationName)
        naptanId = try container.decodeIfPresent(String.self, forKey: .stopId)
            ?? container.decodeIfPresent(String.self, forKey: .naptanId)
        platformName = try container.decodeIfPresent(String.self, forKey: .platformName)
        direction = try container.decodeIfPresent(String.self, forKey: .direction)
        destinationName = try container.decodeIfPresent(String.self, forKey: .destinationName)
        destinationNaptanId = try container.decodeIfPresent(String.self, forKey: .destinationStopId)
            ?? container.decodeIfPresent(String.self, forKey: .destinationNaptanId)
        towards = try container.decodeIfPresent(String.self, forKey: .towards)
        expectedArrival = try container.decodeIfPresent(Date.self, forKey: .expectedArrival)
        timeToStation = try container.decodeIfPresent(Int.self, forKey: .timeToStation)
        currentLocation = try container.decodeIfPresent(String.self, forKey: .currentLocation)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(vehicleId, forKey: .vehicleId)
        try container.encode(lineId, forKey: .lineId)
        try container.encodeIfPresent(stationName, forKey: .stationName)
        try container.encodeIfPresent(naptanId, forKey: .stopId)
        try container.encodeIfPresent(platformName, forKey: .platformName)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(destinationName, forKey: .destinationName)
        try container.encodeIfPresent(destinationNaptanId, forKey: .destinationStopId)
        try container.encodeIfPresent(towards, forKey: .towards)
        try container.encodeIfPresent(expectedArrival, forKey: .expectedArrival)
        try container.encodeIfPresent(timeToStation, forKey: .timeToStation)
        try container.encodeIfPresent(currentLocation, forKey: .currentLocation)
    }

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

    private enum CodingKeys: String, CodingKey {
        case vehicleId, lineId, naptanId, stopId, direction, destinationName
        case destinationNaptanId, destinationStopId, towards, timeToStation
        case currentLocation, platformName
    }

    init(
        vehicleId: String?,
        lineId: String,
        naptanId: String?,
        direction: String?,
        destinationName: String?,
        destinationNaptanId: String?,
        towards: String?,
        timeToStation: Int?,
        currentLocation: String?,
        platformName: String?
    ) {
        self.vehicleId = vehicleId
        self.lineId = lineId
        self.naptanId = naptanId
        self.direction = direction
        self.destinationName = destinationName
        self.destinationNaptanId = destinationNaptanId
        self.towards = towards
        self.timeToStation = timeToStation
        self.currentLocation = currentLocation
        self.platformName = platformName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vehicleId = try container.decodeIfPresent(String.self, forKey: .vehicleId)
        lineId = try container.decode(String.self, forKey: .lineId)
        naptanId = try container.decodeIfPresent(String.self, forKey: .stopId)
            ?? container.decodeIfPresent(String.self, forKey: .naptanId)
        direction = try container.decodeIfPresent(String.self, forKey: .direction)
        destinationName = try container.decodeIfPresent(String.self, forKey: .destinationName)
        destinationNaptanId = try container.decodeIfPresent(String.self, forKey: .destinationStopId)
            ?? container.decodeIfPresent(String.self, forKey: .destinationNaptanId)
        towards = try container.decodeIfPresent(String.self, forKey: .towards)
        timeToStation = try container.decodeIfPresent(Int.self, forKey: .timeToStation)
        currentLocation = try container.decodeIfPresent(String.self, forKey: .currentLocation)
        platformName = try container.decodeIfPresent(String.self, forKey: .platformName)
    }
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
