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
    public let scheduleID: String?
    public let activityID: String
    public let stationHubID: String
    public let stationName: String
    public let lineIDRaw: String
    public let operatorName: String?
    public let boardRequest: DepartureBoardRequest?
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

    /// Resolve bundled station names for both app-started and scheduled activities.
    /// Keep all legacy destinations visible until the passenger edits that board.
    public var callingAtLabel: String? {
        guard let ids = boardRequest?.destinationIDs, !ids.isEmpty else { return nil }
        let names = ids.map { id in
            DepartureStop.bundled.first { $0.id == id || $0.stopIDs.contains(id) || $0.railCodes.contains(id) }?.name ?? id
        }
        return "Calling at " + names.joined(separator: " or ")
    }

    public var isRiver: Bool { lineIDRaw.hasPrefix("rb") }
    public var isNationalRailOperator: Bool { lineIDRaw.hasPrefix("national-rail:") }
    public var showsPlatforms: Bool { boardRequest != nil || isNationalRailOperator || lineID?.isNationalRail == true }
    public var lineName: String { operatorName ?? lineID?.displayName ?? (isNationalRailOperator ? "National Rail" : lineIDRaw.uppercased()) }
    public var deepLink: DeepLink {
        deepLink(for: nil)
    }

    /// Keep the displayed direction and tap destination in sync, including older
    /// scheduled activities whose immutable attributes requested any direction.
    public func directionLabel(for state: ContentState?) -> String {
        if let label = boardRequest?.direction, !label.isEmpty { return label }
        if directionFilter != .any { return directionFilter.displayName }
        if let inferred = state?.commonDirection { return inferred.displayName }
        return direction
    }

    public func deepLink(for state: ContentState?) -> DeepLink {
        if isRiver, boardRequest == nil { return .pier(id: stationHubID, line: lineIDRaw) }
        var request = boardRequest ?? DepartureBoardRequest(originID: stationHubID, lineIDs: [lineIDRaw])
        if request.direction == nil {
            let label = directionLabel(for: state)
            if DepartureDirectionFilter.resolve(label: label) != .any { request.direction = label }
        }
        return .board(request)
    }
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
        self.init(activityID: activityID, stationHubID: stationHubID, stationName: stationName,
                  lineIDRaw: lineID.rawValue, direction: direction, directionFilter: directionFilter,
                  startedAt: startedAt, hardEndsAt: hardEndsAt)
    }

    public init(
        activityID: String, stationHubID: String, stationName: String,
        lineIDRaw: String, direction: String, directionFilter: DepartureDirectionFilter,
        startedAt: Date, hardEndsAt: Date, operatorName: String? = nil,
        boardRequest: DepartureBoardRequest? = nil
    ) {
        scheduleID = nil
        self.activityID = activityID
        self.stationHubID = stationHubID
        self.stationName = String(stationName.prefix(40))
        self.lineIDRaw = lineIDRaw
        self.operatorName = operatorName.map { String($0.prefix(40)) }
        self.boardRequest = boardRequest
        self.direction = direction
        directionFilterRaw = directionFilter.rawValue
        startedAtEpoch = startedAt.epochSeconds
        hardEndsAtEpoch = hardEndsAt.epochSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scheduleID = try container.decodeIfPresent(String.self, forKey: .scheduleID)
        activityID = try container.decodeIfPresent(String.self, forKey: .activityID) ?? ""
        stationHubID = try container.decodeIfPresent(String.self, forKey: .stationHubID) ?? ""
        stationName = try container.decodeIfPresent(String.self, forKey: .stationName) ?? ""
        lineIDRaw = try container.decodeIfPresent(String.self, forKey: .lineIDRaw) ?? ""
        operatorName = try container.decodeIfPresent(String.self, forKey: .operatorName)
        boardRequest = try container.decodeIfPresent(DepartureBoardRequest.self, forKey: .boardRequest)
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
            public let lineIDRaw: String?
            public let directionRaw: String?
            public let id: String
            public let destination: String
            public let platform: String?
            public let expectedAtEpoch: Int
            /// "delayed" or "cancelled" for a National Rail train; absent when
            /// it is running normally, and always absent for the Underground.
            public let status: String?
            /// False when the railway has no forecast. The scheduled time is
            /// retained for ordering, but must never become a live countdown.
            public let hasExpectedTime: Bool

            public var expectedAt: Date { Date(epochSeconds: expectedAtEpoch) }
            public var isCancelled: Bool { status == RailServiceStatus.cancelled.rawValue }
            public var isDelayed: Bool { status == RailServiceStatus.delayed.rawValue }

            /// Older payloads omit status for normal running trains.
            public var railServiceStatus: RailServiceStatus {
                status.map { RailServiceStatus(rawValue: $0) ?? .unknown }
                    ?? (hasExpectedTime ? .onTime : .unknown)
            }

            /// Only known platform identifiers become pills. Missing, hidden
            /// and truncated "to be confirmed" labels must not imply a platform.
            public var platformPillLabel: String? {
                guard var code = platform?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                      !code.isEmpty else { return nil }
                if code.hasPrefix("PLATFORM") { code.removeFirst("PLATFORM".count) }
                else if code.hasPrefix("P"), code.count > 1 { code.removeFirst() }
                code = code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard code.range(of: #"^(?:[0-9]{1,3}[A-Z]?|[A-Z])$"#, options: .regularExpression) != nil else { return nil }
                return "P\(code)"
            }

            public init(
                id: String, destination: String, platform: String?, expectedAt: Date,
                status: RailServiceStatus? = nil, hasExpectedTime: Bool = true, lineIDRaw: String? = nil,
                direction: DepartureDirectionFilter? = nil
            ) {
                self.lineIDRaw = lineIDRaw
                directionRaw = direction?.rawValue
                self.id = id
                self.destination = String(destination.prefix(28))
                self.platform = platform.map { String($0.prefix(14)) }
                expectedAtEpoch = expectedAt.epochSeconds
                self.status = status == .onTime ? nil : status?.rawValue
                self.hasExpectedTime = hasExpectedTime
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                lineIDRaw = try container.decodeIfPresent(String.self, forKey: .lineIDRaw)
                directionRaw = try container.decodeIfPresent(String.self, forKey: .directionRaw)
                id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
                destination = try container.decodeIfPresent(String.self, forKey: .destination) ?? "Check front of train"
                platform = try container.decodeIfPresent(String.self, forKey: .platform)
                expectedAtEpoch = try container.decodeIfPresent(Int.self, forKey: .expectedAtEpoch) ?? 0
                status = try container.decodeIfPresent(String.self, forKey: .status)
                hasExpectedTime = try container.decodeIfPresent(Bool.self, forKey: .hasExpectedTime) ?? true
            }
        }

        /// Only infer a heading when every visible row has the same known direction.
        public var commonDirection: DepartureDirectionFilter? {
            guard let raw = departures.first?.directionRaw,
                  let direction = DepartureDirectionFilter(rawValue: raw), direction != .any,
                  departures.allSatisfy({ $0.directionRaw == raw }) else { return nil }
            return direction
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
            departures.filter { (!$0.hasExpectedTime && !$0.isCancelled)
                || $0.expectedAt.timeIntervalSince(date) > -DepartureTimeline.departedGrace }
        }
    }
}

extension Date {
    var epochSeconds: Int { Int(timeIntervalSince1970.rounded()) }

    init(epochSeconds: Int) {
        self.init(timeIntervalSince1970: TimeInterval(epochSeconds))
    }
}
