import Foundation

public struct JourneyActivityAttributes: Codable, Sendable, Hashable {
    public let sessionID: String
    public let destination: String
    public let endsAtEpoch: Int

    public init(sessionID: String, destination: String, endsAtEpoch: Int) {
        self.sessionID = sessionID; self.destination = destination; self.endsAtEpoch = endsAtEpoch
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
