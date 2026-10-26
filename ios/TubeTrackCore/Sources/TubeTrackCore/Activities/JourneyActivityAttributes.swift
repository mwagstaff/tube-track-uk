import Foundation

public struct JourneyActivityAttributes: Codable, Sendable, Hashable {
    public let sessionID: String
    public let destination: String
    public let endsAtEpoch: Int
    public let origin: String?

    public init(sessionID: String, destination: String, endsAtEpoch: Int, origin: String? = nil) {
        self.sessionID = sessionID; self.destination = destination; self.endsAtEpoch = endsAtEpoch
        self.origin = origin
    }

    public static func shortStationName(_ name: String) -> String {
        for suffix in [" DLR Station", " Underground Station", " Rail Station", " Railway Station", " Overground Station"] {
            if name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        return name
    }

    public func summary(for state: ContentState) -> String {
        let start = origin ?? (state.headline.hasPrefix("Board at ") ? String(state.headline.dropFirst(9)) : nil)
        let end = Self.shortStationName(destination)
        return start.map { "\(Self.shortStationName($0)) → \(end)" } ?? "Journey to \(end)"
    }

    public struct ContentState: Codable, Sendable, Hashable {
        public struct Departure: Codable, Sendable, Hashable, Identifiable {
            public let id: String
            public let destination: String
            public let platform: String?
            public let expectedAtEpoch: Int?
            public let status: String?
        }
        public var phase: String
        public var legIndex: Int
        public var headline: String
        public var nextStop: String
        public var destination: String
        public var nextArrivalEpoch: Int?
        public var finalArrivalEpoch: Int?
        public var boardTitle: String?
        public var departures: [Departure]
        public var updatedAtEpoch: Int
        public var staleAtEpoch: Int
        public var message: String
        public var sequence: Int

        public func isStale(at date: Date) -> Bool { date.timeIntervalSince1970 >= Double(staleAtEpoch) }
    }
}

#if canImport(ActivityKit) && !os(macOS)
import ActivityKit
extension JourneyActivityAttributes: ActivityAttributes {}
#endif
