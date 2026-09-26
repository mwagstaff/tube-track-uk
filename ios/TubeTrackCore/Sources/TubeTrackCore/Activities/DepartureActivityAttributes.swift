import Foundation

/// The state behind a "Track departures" Live Activity.
///
/// Two rules govern this type, both learned from the sibling apps' push work:
///
/// 1. **Times cross the wire as epoch seconds, never as `Date`.** Swift's
///    default date coding is seconds-since-2001, which no server sends by
///    accident. An `Int` is unambiguous in every language and shows up in a
///    push payload as a plain number.
/// 2. **Every field decodes with a default.** A widget on an older build must
///    survive a newer server adding fields, and vice versa — a decode failure
///    here is a Live Activity frozen on a passenger's Lock Screen.
public struct DepartureActivityAttributes: Codable, Hashable, Sendable {
    /// Correlates the activity with its server-side push subscription.
    public let activityID: String
    public let stationHubID: String
    public let stationName: String
    public let lineIDRaw: String
    /// What the passenger sees — the station's own platform wording.
    public let direction: String
    /// The canonical filter that label resolved to when tracking started. The
    /// label alone is not enough: re-projecting the board later (here, or on
    /// the server) has to filter by something unambiguous.
    public let directionFilterRaw: String
    public let startedAtEpoch: Int
    /// The activity ends here no matter what, so a forgotten board cannot live
    /// on a Lock Screen all day.
    public let hardEndsAtEpoch: Int

    public var lineID: TubeLineID? { TubeLineID(rawValue: lineIDRaw) }
    public var directionFilter: DepartureDirectionFilter {
        DepartureDirectionFilter(rawValue: directionFilterRaw) ?? .any
    }
    public var startedAt: Date { Date(epochSeconds: startedAtEpoch) }
    public var hardEndsAt: Date { Date(epochSeconds: hardEndsAtEpoch) }

    public init(
        activityID: String,
        stationHubID: String,
        stationName: String,
        lineID: TubeLineID,
        direction: String,
        directionFilter: DepartureDirectionFilter,
        startedAt: Date,
        hardEndsAt: Date
    ) {
        self.activityID = activityID
        self.stationHubID = stationHubID
        self.stationName = String(stationName.prefix(40))
        lineIDRaw = lineID.rawValue
        self.direction = direction
        directionFilterRaw = directionFilter.rawValue
        startedAtEpoch = startedAt.epochSeconds
        hardEndsAtEpoch = hardEndsAt.epochSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activityID = try container.decodeIfPresent(String.self, forKey: .activityID) ?? ""
        stationHubID = try container.decodeIfPresent(String.self, forKey: .stationHubID) ?? ""
        stationName = try container.decodeIfPresent(String.self, forKey: .stationName) ?? ""
        lineIDRaw = try container.decodeIfPresent(String.self, forKey: .lineIDRaw) ?? ""
        direction = try container.decodeIfPresent(String.self, forKey: .direction) ?? ""
        directionFilterRaw = try container.decodeIfPresent(String.self, forKey: .directionFilterRaw)
            ?? DepartureDirectionFilter.resolve(label: direction).rawValue
        startedAtEpoch = try container.decodeIfPresent(Int.self, forKey: .startedAtEpoch) ?? 0
        hardEndsAtEpoch = try container.decodeIfPresent(Int.self, forKey: .hardEndsAtEpoch) ?? 0
    }

    public struct ContentState: Codable, Hashable, Sendable {
        /// At most this many departures ride in a push payload.
        public static let maximumDepartures = 4

        public struct Departure: Codable, Hashable, Sendable, Identifiable {
            public let id: String
            public let destination: String
            public let platform: String?
            public let expectedAtEpoch: Int

            public var expectedAt: Date { Date(epochSeconds: expectedAtEpoch) }

            public init(id: String, destination: String, platform: String?, expectedAt: Date) {
                self.id = id
                self.destination = String(destination.prefix(28))
                self.platform = platform.map { String($0.prefix(14)) }
                expectedAtEpoch = expectedAt.epochSeconds
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
                destination = try container.decodeIfPresent(String.self, forKey: .destination) ?? "Check front of train"
                platform = try container.decodeIfPresent(String.self, forKey: .platform)
                expectedAtEpoch = try container.decodeIfPresent(Int.self, forKey: .expectedAtEpoch) ?? 0
            }
        }

        public var departures: [Departure]
        public var updatedAtEpoch: Int
        /// `LineServiceCondition.severityRank`, so the widget can colour the
        /// activity without shipping the whole status model through APNs.
        public var conditionRank: Int
        public var conditionHeadline: String?
        /// Monotonic, so a push that overtakes another can be discarded.
        public var sequence: Int

        public var updatedAt: Date { Date(epochSeconds: updatedAtEpoch) }

        public init(
            departures: [Departure],
            updatedAt: Date,
            conditionRank: Int,
            conditionHeadline: String?,
            sequence: Int
        ) {
            self.departures = Array(departures.prefix(Self.maximumDepartures))
            updatedAtEpoch = updatedAt.epochSeconds
            self.conditionRank = conditionRank
            self.conditionHeadline = conditionHeadline.map { String($0.prefix(48)) }
            self.sequence = sequence
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            departures = try container.decodeIfPresent([Departure].self, forKey: .departures) ?? []
            updatedAtEpoch = try container.decodeIfPresent(Int.self, forKey: .updatedAtEpoch) ?? 0
            conditionRank = try container.decodeIfPresent(Int.self, forKey: .conditionRank) ?? 4
            conditionHeadline = try container.decodeIfPresent(String.self, forKey: .conditionHeadline)
            sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        }

        /// The departures still worth showing at `date`, using the same grace
        /// period as the in-app board.
        public func upcoming(at date: Date) -> [Departure] {
            departures.filter { $0.expectedAt.timeIntervalSince(date) > -DepartureTimeline.departedGrace }
        }
    }
}

extension Date {
    var epochSeconds: Int { Int(timeIntervalSince1970.rounded()) }

    init(epochSeconds: Int) {
        self.init(timeIntervalSince1970: TimeInterval(epochSeconds))
    }
}
