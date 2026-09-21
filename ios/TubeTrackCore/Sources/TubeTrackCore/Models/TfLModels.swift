import Foundation

public struct TfLLineStatus: Codable, Identifiable, Equatable, Sendable {
    public let id: TubeLineID
    public let name: String
    public let lineStatuses: [TfLStatusEntry]

    public init(
        id: TubeLineID,
        name: String,
        lineStatuses: [TfLStatusEntry]
    ) {
        self.id = id
        self.name = name
        self.lineStatuses = lineStatuses
    }
}

public struct TfLStatusEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let statusSeverity: Int
    public let statusSeverityDescription: String
    public let reason: String?
    public let validityPeriods: [TfLValidityPeriod]?
    public let disruption: TfLDisruption?

    public init(
        id: Int,
        statusSeverity: Int,
        statusSeverityDescription: String,
        reason: String? = nil,
        validityPeriods: [TfLValidityPeriod]? = nil,
        disruption: TfLDisruption? = nil
    ) {
        self.id = id
        self.statusSeverity = statusSeverity
        self.statusSeverityDescription = statusSeverityDescription
        self.reason = reason
        self.validityPeriods = validityPeriods
        self.disruption = disruption
    }

    public var isGoodService: Bool { statusSeverity == 10 || statusSeverity == 18 }

    public var isServiceClosed: Bool {
        statusSeverity == 20
            || statusSeverityDescription.localizedCaseInsensitiveCompare("Service Closed")
                == .orderedSame
    }

    public var isOvernightClosure: Bool {
        guard statusSeverity == 20 else { return false }
        let text = reason?.lowercased() ?? ""
        return text.contains("service will resume")
            || text.contains("resume later this morning")
            || text.contains("service is closed")
    }

    public var isActionableIssue: Bool {
        !isGoodService && !isOvernightClosure
    }
}

public enum LineServiceClosurePolicy {
    public static func closedLineIDs(in statuses: [TfLLineStatus]) -> Set<TubeLineID> {
        Set(statuses.compactMap { line in
            line.lineStatuses.contains(where: \.isServiceClosed) ? line.id : nil
        })
    }
}

public struct TfLValidityPeriod: Codable, Equatable, Sendable {
    public let fromDate: Date?
    public let toDate: Date?
    public let isNow: Bool?

    public init(
        fromDate: Date? = nil,
        toDate: Date? = nil,
        isNow: Bool? = nil
    ) {
        self.fromDate = fromDate
        self.toDate = toDate
        self.isNow = isNow
    }
}

public struct TfLDisruption: Codable, Equatable, Sendable {
    public let category: String?
    public let categoryDescription: String?
    public let description: String?
    public let affectedRoutes: [TfLDisruptedRoute]?
    public let affectedStops: [TfLStopPoint]?
    public let closureText: String?

    public init(
        category: String? = nil,
        categoryDescription: String? = nil,
        description: String? = nil,
        affectedRoutes: [TfLDisruptedRoute]? = nil,
        affectedStops: [TfLStopPoint]? = nil,
        closureText: String? = nil
    ) {
        self.category = category
        self.categoryDescription = categoryDescription
        self.description = description
        self.affectedRoutes = affectedRoutes
        self.affectedStops = affectedStops
        self.closureText = closureText
    }
}

public struct TfLDisruptedRoute: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let direction: String?
    public let originationName: String?
    public let destinationName: String?
    public let isEntireRouteSection: Bool?
    public let routeSectionNaptanEntrySequence: [TfLRouteStopEntry]?

    public init(
        id: String? = nil,
        name: String? = nil,
        direction: String? = nil,
        originationName: String? = nil,
        destinationName: String? = nil,
        isEntireRouteSection: Bool? = nil,
        routeSectionNaptanEntrySequence: [TfLRouteStopEntry]? = nil
    ) {
        self.id = id
        self.name = name
        self.direction = direction
        self.originationName = originationName
        self.destinationName = destinationName
        self.isEntireRouteSection = isEntireRouteSection
        self.routeSectionNaptanEntrySequence = routeSectionNaptanEntrySequence
    }
}

public struct TfLRouteStopEntry: Codable, Equatable, Sendable {
    public let ordinal: Int?
    public let stopPoint: TfLStopPoint?

    public init(
        ordinal: Int? = nil,
        stopPoint: TfLStopPoint? = nil
    ) {
        self.ordinal = ordinal
        self.stopPoint = stopPoint
    }
}

public struct TfLStopPoint: Codable, Equatable, Sendable {
    public let naptanId: String?
    public let id: String?
    public let commonName: String?
    public let lat: Double?
    public let lon: Double?

    public init(
        naptanId: String? = nil,
        id: String? = nil,
        commonName: String? = nil,
        lat: Double? = nil,
        lon: Double? = nil
    ) {
        self.naptanId = naptanId
        self.id = id
        self.commonName = commonName
        self.lat = lat
        self.lon = lon
    }
}

public struct TfLArrivalPrediction: Codable, Sendable {
    public let id: String
    public let vehicleId: String?
    public let lineId: String
    public let stationName: String?
    public let naptanId: String?
    public let platformName: String?
    public let direction: String?
    public let destinationName: String?
    public let destinationNaptanId: String?
    public let towards: String?
    public let expectedArrival: Date?
    public let timeToStation: Int?
    public let currentLocation: String?

    private enum CodingKeys: String, CodingKey {
        case id, vehicleId, lineId, stationName, naptanId, stopId, platformName
        case direction, destinationName, destinationNaptanId, destinationStopId
        case towards, expectedArrival, timeToStation, currentLocation
    }

    public init(
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public var departureIdentity: DepartureIdentity {
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

    public struct DepartureIdentity: Hashable, Sendable {
        public let sourceID: String
        public let vehicleID: String?
        public let lineID: String
        public let stationID: String?
        public let platformName: String?
        public let direction: String?
        public let destinationID: String?
        public let destinationName: String?
        public let towards: String?
        public let expectedArrival: Date?
        public let fallbackTimeToStation: Int?
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
public struct TfLLiveTrainPrediction: Decodable, Sendable {
    public let vehicleId: String?
    public let lineId: String
    public let naptanId: String?
    public let direction: String?
    public let destinationName: String?
    public let destinationNaptanId: String?
    public let towards: String?
    public let timeToStation: Int?
    public let currentLocation: String?
    public let platformName: String?

    private enum CodingKeys: String, CodingKey {
        case vehicleId, lineId, naptanId, stopId, direction, destinationName
        case destinationNaptanId, destinationStopId, towards, timeToStation
        case currentLocation, platformName
    }

    public init(
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

    public init(from decoder: Decoder) throws {
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
    public static var tfl: JSONDecoder {
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
    public nonisolated(unsafe) static let tfl: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public nonisolated(unsafe) static let tflWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
