import Foundation

/// Exact departure-board wording for the latest Live Activity snapshot.
/// Render as plain text: custom live FormatStyles cannot be decoded by iOS outside
/// the widget extension. App refreshes and server pushes advance the snapshot.
public struct DepartureCountdownFormatStyle: FormatStyle, Sendable {
    public let expectedAt: Date

    public init(expectedAt: Date) {
        self.expectedAt = expectedAt
    }

    public func format(_ value: Date) -> String {
        let minutes = remainingMinutes(at: value)
        guard minutes > 0 else { return "Due" }
        return StationDepartureMetadata.departureTimeLabel(
            expectedAt: expectedAt,
            seconds: expectedAt.timeIntervalSince(value),
            minutes: minutes
        )
    }

    private func remainingMinutes(at date: Date) -> Int {
        Int(max(0, expectedAt.timeIntervalSince(date) / 60).rounded(.down))
    }
}
