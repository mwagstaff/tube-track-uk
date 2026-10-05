import Foundation
import Testing
@testable import TubeTrackCore

struct DepartureCountdownFormatStyleTests {
    private let expectedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [
        (-60.0, "Due"), (0, "Due"), (0.5, "Due"), (59.999, "Due"),
        (60, "1 min"), (119.999, "1 min"), (120, "2 mins"),
        (179.999, "2 mins"), (1200, "20 mins"),
    ])
    func minutesAndDue(seconds: Double, label: String) {
        let style = DepartureCountdownFormatStyle(expectedAt: expectedAt)
        #expect(style.format(expectedAt.addingTimeInterval(-seconds)) == label)
    }

    @Test func distantDepartureIncludesClockTime() throws {
        let departure = try #require(ISO8601DateFormatter().date(from: "2026-10-05T22:31:00Z"))
        let style = DepartureCountdownFormatStyle(expectedAt: departure)
        #expect(style.format(departure.addingTimeInterval(-1380)) == "23 mins (23:31)")
    }

    @Test func aNewSnapshotAdvancesFromMinutesToDue() {
        let style = DepartureCountdownFormatStyle(expectedAt: expectedAt)
        #expect(style.format(expectedAt.addingTimeInterval(-125)) == "2 mins")
        #expect(style.format(expectedAt.addingTimeInterval(-65)) == "1 min")
        #expect(style.format(expectedAt.addingTimeInterval(-5)) == "Due")
    }
}
