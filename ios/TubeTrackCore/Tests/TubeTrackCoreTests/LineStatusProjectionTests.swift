import XCTest
@testable import TubeTrackCore

final class LineStatusProjectionTests: XCTestCase {
    func testChosenOrderAndMissingLineRemainVisible() {
        let statuses = [
            TfLLineStatus(id: .central, name: "Central", lineStatuses: [
                TfLStatusEntry(
                    id: 1, statusSeverity: 9, statusSeverityDescription: "Minor delays",
                    reason: "Central Line: Minor delays due to a signal fault"
                )
            ]),
            TfLLineStatus(id: .bakerloo, name: "Bakerloo", lineStatuses: [
                TfLStatusEntry(id: 2, statusSeverity: 10, statusSeverityDescription: "Good service")
            ])
        ]

        let rows = LineStatusProjection.rows(
            from: statuses, lineIDs: [.bakerloo, .victoria, .central]
        )

        XCTAssertEqual(rows.map(\.lineID), [.bakerloo, .victoria, .central])
        XCTAssertEqual(rows.map(\.condition), [
            .good("Good service"), .updating, .minorDisruption("Minor delays")
        ])
        XCTAssertEqual(rows.last?.reason, "Minor delays due to a signal fault")
    }
}
