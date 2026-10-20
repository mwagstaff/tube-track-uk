import Foundation

/// Exact departure-board wording for the latest Live Activity snapshot.
/// Render as plain text: custom live FormatStyles cannot be decoded by iOS outside
/// the widget extension. App refreshes and server pushes advance the snapshot.
public struct DepartureCountdownFormatStyle: FormatStyle, Sendable {
    public let expectedAt: Date
    public let transitType: DepartureTransitType
    public let preferences: DepartureDisplayPreferences

    public static let clockTime = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: TimeZone(identifier: "Europe/London")!,
        calendar: Calendar(identifier: .gregorian)
    )

    public init(expectedAt: Date, transitType: DepartureTransitType = .underground,
                preferences: DepartureDisplayPreferences = .init()) {
        self.transitType = transitType
        self.preferences = preferences
        self.expectedAt = expectedAt
    }

    public func format(_ value: Date) -> String {
        let minutes = remainingMinutes(at: value)
        return StationDepartureMetadata.departureTimeLabel(
            expectedAt: expectedAt, seconds: expectedAt.timeIntervalSince(value), minutes: minutes,
            transitType: transitType, preferences: preferences
        )
    }

    private func remainingMinutes(at date: Date) -> Int {
        Int(max(0, expectedAt.timeIntervalSince(date) / 60).rounded(.down))
    }
}
