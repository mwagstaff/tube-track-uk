import Foundation
import Testing
@testable import TubeTrackCore

struct DepartureCountdownFormatStyleTests {
    private let expectedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [
        (-60.0, "Due"), (0, "Due"), (0.5, "Due"), (59.999, "Due"),
        (60, "1 min"), (119.999, "1 min"), (120, "2 mins"),
        (179.999, "2 mins"), (3600, "60 mins"),
    ])
    func minutesAndDue(seconds: Double, label: String) {
        let style = DepartureCountdownFormatStyle(expectedAt: expectedAt)
        #expect(style.format(expectedAt.addingTimeInterval(-seconds)) == label)
    }

    @Test func aNewSnapshotAdvancesFromMinutesToDue() {
        let style = DepartureCountdownFormatStyle(expectedAt: expectedAt)
        #expect(style.format(expectedAt.addingTimeInterval(-125)) == "2 mins")
        #expect(style.format(expectedAt.addingTimeInterval(-65)) == "1 min")
        #expect(style.format(expectedAt.addingTimeInterval(-5)) == "Due")
    }
}
