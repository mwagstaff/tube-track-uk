import Foundation

public enum StationDepartureMetadata {
    public static func directionLabel(for arrival: TfLArrivalPrediction) -> String {
        let cardinalDirections = ["northbound", "southbound", "eastbound", "westbound"]
        if let platformName = arrival.platformName?.lowercased(),
           let direction = cardinalDirections.first(where: { platformName.contains($0) }) {
            return direction.capitalized
        }

        if let direction = normalized(arrival.direction) {
            if arrival.lineId == TubeLineID.elizabeth.rawValue {
                switch direction.lowercased() {
                case "inbound":
                    return "Eastbound"
                case "outbound":
                    return "Westbound"
                default:
                    break
                }
            }
            return direction.capitalized
        }
        return "All directions"
    }

    public static func platformLabel(for arrival: TfLArrivalPrediction) -> String? {
        guard let platform = normalized(arrival.platformName) else { return nil }
        let lowercasedPlatform = platform.lowercased()
        let cardinalDirections = ["northbound", "southbound", "eastbound", "westbound"]
        if cardinalDirections.contains(where: { lowercasedPlatform.contains($0) }),
           !lowercasedPlatform.contains("platform") {
            return nil
        }

        if arrival.lineId == TubeLineID.elizabeth.rawValue,
           platform.count == 1,
           platform.first?.isLetter == true {
            return "Platform \(platform.uppercased())"
        }
        return platform
    }

    /// The platform on its own, for surfaces whose heading already says which
    /// way the train is going. TfL writes "Eastbound - Platform 2"; on a Lock
    /// Screen that repeats the heading and then truncates the part that matters.
    public static func compactPlatformLabel(for arrival: TfLArrivalPrediction) -> String? {
        guard let label = platformLabel(for: arrival) else { return nil }
        if let platform = label.range(of: "platform", options: .caseInsensitive) {
            return String(label[platform.lowerBound...])
                .trimmingCharacters(in: .whitespaces)
        }
        if let separator = label.range(of: " - ") {
            return String(label[separator.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        }
        return label
    }

    public static func destinationLabel(for arrival: TfLArrivalPrediction) -> String {
        let stationID = normalized(arrival.naptanId)?.uppercased()
        let destinationID = normalized(arrival.destinationNaptanId)?.uppercased()
        if let stationID, destinationID == stationID {
            return "Check front of train"
        }

        let stationName = normalizedStopName(arrival.stationName)
        for candidate in [arrival.destinationName, arrival.towards] {
            guard let candidate = normalized(candidate) else { continue }
            if let stationName,
               Self.referencesStation(candidate, normalizedStationName: stationName) {
                continue
            }
            let name = passengerFacingStopName(candidate)
            return canonicalStationNames[name.lowercased()] ?? name
        }
        return "Check front of train"
    }

    /// The running status of a National Rail departure, when it is not on time:
    /// "Cancelled · <reason>" or "Delayed · timetabled 22:29".
    public static func serviceNote(for arrival: TfLArrivalPrediction) -> String? {
        if arrival.isCancelled {
            guard let cause = normalized(arrival.serviceCause) else { return "Cancelled" }
            return "Cancelled · \(cause)"
        }
        if let scheduled = arrival.delayedFromSchedule {
            return "Delayed · timetabled \(scheduled.formatted(londonClockTime))"
        }
        if arrival.serviceStatus == .delayed { return "Delayed" }
        if arrival.isNationalRailOperator, arrival.serviceStatus == .unknown, let scheduled = arrival.scheduledDeparture {
            return "Timetabled \(scheduled.formatted(londonClockTime)) · Awaiting update"
        }
        return nil
    }

    private static var londonClockTime: Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
        style.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        style.locale = Locale(identifier: "en_GB")
        return style
    }

    public static func departureTime(
        for arrival: TfLArrivalPrediction,
        now: Date = .now
    ) -> String {
        if arrival.isCancelled { return "Cancelled" }
        if arrival.isNationalRailOperator, arrival.expectedArrival == nil {
            return arrival.serviceStatus == .delayed ? "Delayed" : "—"
        }
        let seconds: Int?
        if let expectedArrival = arrival.expectedArrival {
            seconds = max(0, Int(expectedArrival.timeIntervalSince(now)))
        } else {
            seconds = arrival.timeToStation
        }
        guard let seconds else { return "—" }
        if seconds < 45 { return "Due" }
        return departureTimeLabel(
            expectedAt: arrival.expectedArrival ?? now.addingTimeInterval(TimeInterval(seconds)),
            seconds: TimeInterval(seconds),
            minutes: max(1, seconds / 60)
        )
    }

    /// Shared wording across departure surfaces, preserving each surface's rounding policy.
    public static func departureTimeLabel(expectedAt: Date, seconds: TimeInterval, minutes: Int) -> String {
        let countdown = "\(minutes) \(minutes == 1 ? "min" : "mins")"
        guard seconds > 20 * 60 else { return countdown }
        return "\(countdown) (\(expectedAt.formatted(londonClockTime)))"
    }

    // Validate API casing against known station names rather than title-casing
    // arbitrary text, which can damage acronyms, punctuation and route notes.
    private static let canonicalStationNames: [String: String] = Dictionary(
        StationIndex.bundled.entries.map { entry in
            let name = passengerFacingStopName(entry.name)
            return (name.lowercased(), name)
        },
        uniquingKeysWith: { first, _ in first }
    )

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func referencesStation(
        _ value: String,
        normalizedStationName: String
    ) -> Bool {
        let candidate = normalizedStopName(value) ?? ""
        return candidate == normalizedStationName
            || candidate.hasPrefix("\(normalizedStationName) via ")
    }

    private static func normalizedStopName(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        return passengerFacingStopName(value).lowercased()
    }

    private static func passengerFacingStopName(_ rawName: String) -> String {
        var name = rawName
        for suffix in [" Underground Station", " DLR Station", " Tram Stop", " Rail Station"]
            where name.lowercased().hasSuffix(suffix.lowercased()) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }
}
