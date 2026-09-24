import Foundation
import Testing
@testable import TubeTrackCore

struct DepartureActivityTests {
    private let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func arrival(
        id: String,
        line: TubeLineID = .northern,
        platform: String? = "Southbound - Platform 8",
        destination: String = "Morden Underground Station",
        seconds: Int
    ) -> TfLArrivalPrediction {
        TfLArrivalPrediction(
            id: id, vehicleId: "v\(id)", lineId: line.rawValue, stationName: "Kentish Town",
            naptanId: "940GZZLUKSH", platformName: platform, direction: nil,
            destinationName: destination, destinationNaptanId: nil, towards: nil,
            expectedArrival: updatedAt.addingTimeInterval(TimeInterval(seconds)),
            timeToStation: seconds, currentLocation: nil
        )
    }

    private func sampleState(departures: Int = 3, from offset: Int = 120) -> DepartureActivityAttributes.ContentState {
        let arrivals = (0..<departures).map { index in
            arrival(id: "\(index)", seconds: offset + index * 240)
        }
        return DepartureActivityBoard.contentState(
            from: arrivals, lineID: .northern, direction: .southbound,
            condition: .minorDisruption("Minor delays"), updatedAt: updatedAt, sequence: 1
        )
    }

    // MARK: - Wire format

    @Test func timesCrossTheWireAsEpochSecondsNotSwiftDates() throws {
        let state = sampleState()
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state)
        ) as? [String: Any]
        let departures = try #require(json?["departures"] as? [[String: Any]])
        // A plain number a server can produce without knowing anything about
        // Swift's reference date.
        #expect(departures.first?["expectedAtEpoch"] as? Int == 1_800_000_120)
        #expect(json?["updatedAtEpoch"] as? Int == 1_800_000_000)
    }

    @Test func contentStateRoundTripsAndStaysWellUnderThePushLimit() throws {
        let state = sampleState()
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DepartureActivityAttributes.ContentState.self, from: encoded)
        #expect(decoded == state)
        // APNs rejects payloads over 4KB outright, and the content state is
        // only part of one.
        #expect(encoded.count < 1_500, "content state grew to \(encoded.count) bytes")
    }

    @Test func aStateFromAnOlderServerStillDecodes() throws {
        // Every field defaulted: a push that predates a field we later added
        // must not freeze the activity.
        let sparse = Data(#"{"departures":[{"destination":"Morden","expectedAtEpoch":1800000120}]}"#.utf8)
        let decoded = try JSONDecoder().decode(DepartureActivityAttributes.ContentState.self, from: sparse)
        #expect(decoded.departures.count == 1)
        #expect(decoded.departures[0].platform == nil)
        #expect(decoded.sequence == 0)
        #expect(decoded.conditionHeadline == nil)
    }

    @Test func longNamesAreTruncatedSoTheRowCannotBloatThePayload() {
        let departure = DepartureActivityAttributes.ContentState.Departure(
            id: "1",
            destination: String(repeating: "Wimbledon ", count: 12),
            platform: String(repeating: "Platform 12 ", count: 4),
            expectedAt: updatedAt
        )
        #expect(departure.destination.count == 28)
        #expect(departure.platform?.count == 14)
    }

    // MARK: - Board projection

    @Test func boardKeepsTheSoonestThreeInTheChosenDirection() {
        let arrivals = [
            arrival(id: "late", seconds: 900),
            arrival(id: "soon", seconds: 60),
            arrival(id: "mid", seconds: 300),
            arrival(id: "other", platform: "Northbound - Platform 7", destination: "Edgware", seconds: 30),
        ]
        let state = DepartureActivityBoard.contentState(
            from: arrivals, lineID: .northern, direction: .southbound,
            condition: nil, updatedAt: updatedAt, sequence: 0
        )
        #expect(state.departures.map(\.id) == ["vsoon", "vmid", "vlate"])
        #expect(state.departures.allSatisfy { $0.destination == "Morden" })
    }

    @Test func aHealthyLineCarriesNoHeadline() {
        let state = DepartureActivityBoard.contentState(
            from: [arrival(id: "1", seconds: 120)], lineID: .northern, direction: .any,
            condition: .good("Good service"), updatedAt: updatedAt, sequence: 0
        )
        #expect(state.conditionHeadline == nil)
        #expect(state.conditionRank == LineServiceCondition.good("Good service").severityRank)
    }

    @Test func departedTrainsDropOffTheBoardAsTimePasses() {
        // Departures at +60s, +300s and +540s from the snapshot.
        let state = sampleState(from: 60)
        #expect(state.upcoming(at: updatedAt).count == 3)
        #expect(state.upcoming(at: updatedAt.addingTimeInterval(120)).count == 2)
        #expect(state.upcoming(at: updatedAt.addingTimeInterval(400)).count == 1)
        #expect(state.upcoming(at: updatedAt.addingTimeInterval(700)).isEmpty)
    }

    // MARK: - Policy

    @Test func staleDateTracksWhetherFrequentUpdatesAreAllowed() {
        let hardEnd = updatedAt.addingTimeInterval(DepartureActivityPolicy.maximumDuration)
        let frequent = DepartureActivityPolicy.staleDate(
            updatedAt: updatedAt, frequentPushesEnabled: true, hardEndsAt: hardEnd
        )
        let relaxed = DepartureActivityPolicy.staleDate(
            updatedAt: updatedAt, frequentPushesEnabled: false, hardEndsAt: hardEnd
        )
        #expect(frequent == updatedAt.addingTimeInterval(DepartureActivityPolicy.staleWindow))
        #expect(relaxed == updatedAt.addingTimeInterval(DepartureActivityPolicy.relaxedStaleWindow))
        // The heartbeat has to land inside the window the server sets, with
        // room for one dropped push, or the board dims between perfectly
        // healthy pushes.
        #expect(DepartureActivityPolicy.heartbeat < DepartureActivityPolicy.pushStaleWindow)
        #expect(DepartureActivityPolicy.relaxedHeartbeat < DepartureActivityPolicy.relaxedPushStaleWindow)
    }

    @Test func staleDateNeverOutlivesTheActivityItself() {
        let hardEnd = updatedAt.addingTimeInterval(60)
        let stale = DepartureActivityPolicy.staleDate(
            updatedAt: updatedAt, frequentPushesEnabled: true, hardEndsAt: hardEnd
        )
        #expect(stale == hardEnd)
    }

    @Test func endReasonsFireOnlyWhenTheyShould() {
        let hardEnd = updatedAt.addingTimeInterval(DepartureActivityPolicy.maximumDuration)
        let state = sampleState()

        #expect(DepartureActivityPolicy.endReason(
            state: state, hardEndsAt: hardEnd, lastUpdatedAt: updatedAt, now: updatedAt
        ) == nil)

        #expect(DepartureActivityPolicy.endReason(
            state: state, hardEndsAt: hardEnd, lastUpdatedAt: updatedAt, now: hardEnd
        ) == .cap)

        #expect(DepartureActivityPolicy.endReason(
            state: state, hardEndsAt: hardEnd, lastUpdatedAt: updatedAt,
            now: updatedAt.addingTimeInterval(DepartureActivityPolicy.silenceBeforeAbandoning)
        ) == .abandoned)
    }

    @Test func anEmptyBoardOnlyEndsTheActivityOnceItStaysEmpty() {
        let hardEnd = updatedAt.addingTimeInterval(DepartureActivityPolicy.maximumDuration)
        let empty = DepartureActivityAttributes.ContentState(
            departures: [], updatedAt: updatedAt, conditionRank: 4, conditionHeadline: nil, sequence: 1
        )
        // A momentary empty board mid-refresh must not kill the activity.
        #expect(DepartureActivityPolicy.endReason(
            state: empty, hardEndsAt: hardEnd, lastUpdatedAt: updatedAt,
            now: updatedAt.addingTimeInterval(60)
        ) == nil)
        #expect(DepartureActivityPolicy.endReason(
            state: empty, hardEndsAt: hardEnd, lastUpdatedAt: updatedAt,
            now: updatedAt.addingTimeInterval(DepartureActivityPolicy.emptyBoardGrace)
        ) == .boardEmpty)
    }

    @Test func relevanceFavoursTheSoonestDeparture() {
        let soon = sampleState(from: 60)
        let later = sampleState(from: 900)
        #expect(
            DepartureActivityPolicy.relevanceScore(state: soon, now: updatedAt)
                > DepartureActivityPolicy.relevanceScore(state: later, now: updatedAt)
        )
    }

    @Test("A tracked board drops the direction TfL repeats in the platform name")
    func platformLabelsLoseTheDirectionTheHeaderAlreadyCarries() {
        let state = DepartureActivityBoard.contentState(
            from: [arrival(id: "1", platform: "Eastbound - Platform 2", seconds: 120)],
            lineID: .northern, direction: .any, condition: nil,
            updatedAt: .now, sequence: 1
        )
        #expect(state.departures.first?.platform == "Platform 2")
    }
}
