import Foundation
import Testing
@testable import TubeTrackCore

struct DepartureBoardContinuityTests {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func board(empty: Bool = false, stale: Bool = false, unavailable: Int = 0) throws -> CustomDepartureBoard {
        let rows = empty ? "[]" : #"[{"id":"train","lineId":"national-rail:SE","expectedArrival":"2027-01-15T08:01:00Z"}]"#
        let json = """
        {"arrivals":\(rows),"updatedAt":1800000000,"unavailableSources":\(unavailable),"unverifiedCount":0,"stale":\(stale)}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            return ISO8601DateFormatter().date(from: try value.decode(String.self))!
        }
        return try decoder.decode(CustomDepartureBoard.self, from: Data(json.utf8))
    }

    @Test func ninetySecondCutoffKeepsTheSnapshotVisible() throws {
        let saved = try board()
        #expect(saved.displayReferenceDate(at: timestamp.addingTimeInterval(90)) == timestamp.addingTimeInterval(90))
        let later = timestamp.addingTimeInterval(600)
        #expect(saved.displayReferenceDate(at: later) == timestamp)
        #expect(saved.upcoming(at: saved.displayReferenceDate(at: later)).count == 1)
        #expect(saved.displayReferenceDate(at: timestamp.addingTimeInterval(30), interrupted: true) == timestamp)
    }

    @Test func unavailableEmptyResponsesRetainDataAndOriginalTimestamp() throws {
        let saved = try board()
        for incoming in [try board(empty: true, stale: true), try board(empty: true, unavailable: 1)] {
            let retained = incoming.retainingLastAvailable(saved)
            #expect(retained.arrivals.map(\.id) == ["train"])
            #expect(retained.updatedAt == saved.updatedAt)
            #expect(retained.stale)
        }
        #expect(try board(empty: true).retainingLastAvailable(saved).arrivals.isEmpty)
        #expect(try board(empty: true, stale: true).retainingLastAvailable(nil).arrivals.isEmpty)
        let recovered = try board().retainingLastAvailable(board(stale: true))
        #expect(!recovered.stale)
        #expect(recovered.displayReferenceDate(at: timestamp.addingTimeInterval(10)) == timestamp.addingTimeInterval(10))
    }
}
