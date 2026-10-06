import Foundation

public enum NationalRailStations {
    public static let codesByStopID: [String: [String]] = {
        guard let url = Bundle.module.url(forResource: "NationalRailStations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let codes = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return codes
    }()

    public static func codes(for stationIDs: [String]) -> [String] {
        Set(stationIDs.flatMap { codesByStopID[$0] ?? [] }).sorted()
    }
}

/// TrainTrack's station-wide board, whose clock times are local to the railway.
struct NationalRailBoard: Decodable, Sendable {
    let departures: [NationalRailDeparture]
    let dataStatus: String
    let lastSuccessfulUpdate: Date?

    func predictions(crs: String, now: Date, includeThameslink: Bool = false) -> [TfLArrivalPrediction] {
        let reference = lastSuccessfulUpdate ?? now
        var seen = Set<String>()
        return departures.compactMap { row in
            guard let prediction = row.prediction(crs: crs, reference: reference, now: now, includeThameslink: includeThameslink),
                  seen.insert(prediction.id).inserted else { return nil }
            return prediction
        }.sorted {
            ($0.expectedArrival ?? $0.scheduledDeparture ?? .distantFuture)
                < ($1.expectedArrival ?? $1.scheduledDeparture ?? .distantFuture)
        }
    }
}

struct NationalRailDeparture: Decodable, Sendable {
    struct Times: Decodable, Sendable {
        let scheduled: String?
        let estimated: String?
        let actual: String?
    }
    struct Destination: Decodable, Sendable {
        let crs: String?
        let locationName: String?
    }

    let serviceID: String
    let operatorName: String?
    let operatorCode: String?
    let serviceType: String?
    let platform: String?
    let platformIsHidden: Bool?
    let isCancelled: Bool?
    let cancelReason: String?
    let delayReason: String?
    let times: Times
    let destinations: [Destination]

    enum CodingKeys: String, CodingKey {
        case serviceID, operatorName = "operator", operatorCode, serviceType, platform, platformIsHidden
        case isCancelled, cancelReason, delayReason, times = "departure_time", destination
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serviceID = try c.decode(String.self, forKey: .serviceID)
        operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
        operatorCode = try c.decodeIfPresent(String.self, forKey: .operatorCode)
        serviceType = try c.decodeIfPresent(String.self, forKey: .serviceType)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        platformIsHidden = try c.decodeIfPresent(Bool.self, forKey: .platformIsHidden)
        isCancelled = try c.decodeIfPresent(Bool.self, forKey: .isCancelled)
        cancelReason = try c.decodeIfPresent(String.self, forKey: .cancelReason)
        delayReason = try c.decodeIfPresent(String.self, forKey: .delayReason)
        times = try c.decode(Times.self, forKey: .times)
        if let list = try? c.decode([Destination].self, forKey: .destination) {
            destinations = list
        } else {
            destinations = try c.decodeIfPresent(Destination.self, forKey: .destination).map { [$0] } ?? []
        }
    }

    func prediction(crs: String, reference: Date, now: Date, includeThameslink: Bool = false) -> TfLArrivalPrediction? {
        let code = operatorCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let name = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // These services already have dedicated TfL boards and line pills.
        let excludedCodes = includeThameslink ? ["LO", "XR"] : ["TL", "LO", "XR"]
        let excludedNames = includeThameslink
            ? ["london overground", "elizabeth line", "tfl rail"]
            : ["thameslink", "london overground", "elizabeth line", "tfl rail"]
        guard !excludedCodes.contains(code), !excludedNames.contains(name.lowercased()),
              serviceType == nil || serviceType?.lowercased() == "train",
              let scheduled = Self.clockDate(times.scheduled, near: reference),
              !(destinations.count == 1 && destinations.first?.crs == crs) else { return nil }
        let estimate = times.estimated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cancelled = isCancelled == true || estimate.lowercased() == "cancelled"
        let forecast = Self.clockDate(estimate, near: scheduled)
        let onTime = estimate.lowercased() == "on time" || estimate.lowercased() == "ontime"
        let expected = cancelled || onTime ? scheduled : forecast
        if let actual = Self.clockDate(times.actual, near: scheduled), actual <= now { return nil }
        // An explicitly delayed train can still be awaiting a forecast after
        // its booked departure. Keep the live row until the provider removes it.
        guard (expected ?? reference) >= now.addingTimeInterval(-60) else { return nil }
        let status: RailServiceStatus = cancelled ? .cancelled
            : estimate.lowercased() == "delayed" || (forecast?.timeIntervalSince(scheduled) ?? 0) >= 60 ? .delayed
            : onTime || forecast != nil ? .onTime : .unknown
        let operatorID = code.isEmpty ? (name.isEmpty ? "unknown" : name.lowercased()) : code
        let destination = destinations.compactMap(\.locationName).filter { !$0.isEmpty }.joined(separator: " & ")
        let visiblePlatform = platformIsHidden == true ? nil : platform?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TfLArrivalPrediction(
            id: "national-rail:\(crs):\(serviceID)", vehicleId: nil,
            lineId: "national-rail:\(operatorID)", stationName: nil, naptanId: crs,
            platformName: visiblePlatform.flatMap { $0.isEmpty ? nil : "Platform \($0)" } ?? "Platform to be confirmed",
            direction: nil, destinationName: destination.isEmpty ? "Check station screens" : destination,
            destinationNaptanId: nil, towards: nil, expectedArrival: expected,
            timeToStation: expected.map { max(0, Int($0.timeIntervalSince(now))) }, currentLocation: nil,
            scheduledDeparture: scheduled, serviceStatus: status,
            serviceCause: cancelled ? cancelReason : delayReason,
            operatorName: name.isEmpty ? "National Rail" : name
        )
    }

    /// Resolve against the board's timestamp, not the phone's timezone or the
    /// refresh time of a stale board. Strict matching avoids invented DST times.
    static func clockDate(_ value: String?, near reference: Date) -> Date? {
        guard let value, value.count == 5 else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let start = reference.addingTimeInterval(-12 * 3600)
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        let candidates = [Calendar.RepeatedTimePolicy.first, .last].compactMap {
            calendar.nextDate(after: start, matching: components, matchingPolicy: .strict, repeatedTimePolicy: $0)
        }.filter { abs($0.timeIntervalSince(reference)) <= 12 * 3600 }
        return candidates.min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }
}

public struct NationalRailDepartureGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let arrivals: [TfLArrivalPrediction]

    public static func groups(from arrivals: [TfLArrivalPrediction]) -> [Self] {
        Dictionary(grouping: arrivals.filter(\.isNationalRailOperator), by: \.lineId).map { id, rows in
            Self(id: id, name: rows.first?.operatorName ?? "National Rail", arrivals: rows.sorted {
                ($0.expectedArrival ?? $0.scheduledDeparture ?? .distantFuture)
                    < ($1.expectedArrival ?? $1.scheduledDeparture ?? .distantFuture)
            })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
