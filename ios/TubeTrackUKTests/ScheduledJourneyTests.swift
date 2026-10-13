import Foundation
import Testing
import TubeTrackCore

struct ScheduledJourneyTests {
    private var board: ScheduledBoard {
        ScheduledBoard(hub: StationHub(id: "940GZZLUOXC", name: "Oxford Circus",
            stopIDs: ["940GZZLUOXC"], lineIDs: [.central]), line: .central, direction: .eastbound)
    }

    @Test func railSchedulesRoundTripWithoutChangingLegacyBoards() throws {
        let station = try #require(ScheduledBoard.railStation(id: "nr:KTH"))
        let rail = ScheduledBoard(station: station, operatorID: "national-rail:SE", operatorName: "Southeastern", direction: .northbound)
        #expect(rail.stopIds == ["KTH"])
        #expect(rail.isNationalRail)
        #expect(ScheduledBoard.departure(station: station, serviceID: "national-rail:SE", serviceName: "Southeastern", direction: .northbound) == rail)
        #expect(ScheduledBoard.departure(station: station, serviceID: "national-rail:unknown", serviceName: "Unknown", direction: .any) == nil)
        let journey = ScheduledJourney.suggested(outbound: rail)
        #expect(try JSONDecoder().decode(ScheduledJourney.self, from: JSONEncoder().encode(journey)) == journey)
        #expect(ScheduledJourney.validationError(for: [journey]) == nil)
        let missingOperator = ScheduledBoard(station: station, operatorID: "national-rail:", operatorName: nil)
        #expect(ScheduledJourney.validationError(for: [.suggested(outbound: missingOperator)]) != nil)
        let legacy = try JSONDecoder().decode(ScheduledBoard.self, from: Data(#"{"hubId":"940GZZLUOXC","stationName":"Oxford Circus","lineId":"central","direction":"eastbound","stopIds":["940GZZLUOXC"]}"#.utf8))
        #expect(legacy == board)
        #expect(legacy.operatorName == nil)
    }

    @Test func callingStopsSurviveSaveAndEdit() throws {
        var filtered = board
        filtered.destinationIDs = ["HUBBAN"]
        let journey = ScheduledJourney.suggested(outbound: filtered, returning: board)
        var decoded = try JSONDecoder().decode(ScheduledJourney.self, from: JSONEncoder().encode(journey))
        #expect(decoded.morning?.board.destinationIDs == ["HUBBAN"])
        #expect(decoded.afternoon?.board.destinationIDs == nil)
        #expect(filtered.callingAtSummary == "Bank")
        decoded.morning?.board.destinationIDs = []
        let cleared = try JSONDecoder().decode(ScheduledJourney.self, from: JSONEncoder().encode(decoded))
        #expect(cleared.morning?.board.callingAtSummary == "All departures")
    }

    @Test func suggestedCommuteUsesWeekdaysAndRequestedWindows() {
        var returning = board
        returning.direction = board.direction.reversed
        let journey = ScheduledJourney.suggested(outbound: board, returning: returning)
        #expect(journey.days == [1, 2, 3, 4, 5])
        #expect(journey.morning?.timeSummary == "07:30–09:30")
        #expect(journey.afternoon?.timeSummary == "16:30–18:30")
        #expect(journey.afternoon?.board.direction == .westbound)
        #expect(ScheduledJourney.validationError(for: [journey]) == nil)
        #expect(ScheduledJourney.suggested(outbound: board).afternoon == nil)
        for direction in DepartureDirectionFilter.allCases {
            #expect(direction.reversed.reversed == direction)
        }
    }

    @Test func unnamedReplacementSummaryOmitsPlaceholderName() {
        let window = ScheduledJourneyWindow(startMinute: 480, endMinute: 600, board: board)
        let unnamed = ScheduledJourney(name: "  ", morning: window)
        #expect(unnamed.replacementSummary == "Weekdays\nMorning: Oxford Circus · 08:00–10:00")
        let named = ScheduledJourney(name: "Office", morning: window)
        #expect(named.replacementSummary.hasPrefix("“Office” · Weekdays"))
    }

    @Test func scheduleDirectionsOnlyIncludeTheSelectedLine() {
        func prediction(_ line: TubeLineID, _ direction: String) -> TfLArrivalPrediction {
            TfLArrivalPrediction(id: UUID().uuidString, vehicleId: nil, lineId: line.rawValue,
                stationName: "East Croydon", naptanId: nil, platformName: nil, direction: direction,
                destinationName: nil, destinationNaptanId: nil, towards: nil,
                expectedArrival: nil, timeToStation: 60, currentLocation: nil)
        }
        let arrivals = [prediction(.thameslink, "northbound"), prediction(.thameslink, "southbound"),
                        prediction(.central, "eastbound")]
        #expect(DepartureDirectionFilter.available(in: arrivals, lineID: TubeLineID.thameslink.rawValue)
                == [.any, .northbound, .southbound])
        #expect(DepartureDirectionFilter.available(in: [], lineID: TubeLineID.thameslink.rawValue) == [.any])
    }

    @Test func acceptsEitherOrBothWindows() {
        let morning = ScheduledJourneyWindow(startMinute: 480, endMinute: 600, board: board)
        let afternoon = ScheduledJourneyWindow(startMinute: 960, endMinute: 1080, board: board)
        for journey in [ScheduledJourney(morning: morning), ScheduledJourney(afternoon: afternoon),
                        ScheduledJourney(morning: morning, afternoon: afternoon)] {
            #expect(ScheduledJourney.validationError(for: [journey]) == nil)
        }
        #expect(ScheduledJourney.validationError(for: [ScheduledJourney()]) != nil)
    }

    @Test func screenshotWindowsDoNotOverlap() {
        let morningBoard = ScheduledBoard(hub: StationHub(id: "940GZZLUCHL", name: "Chancery Lane",
            stopIDs: ["940GZZLUCHL"], lineIDs: [.central]), line: .central)
        let afternoonBoard = ScheduledBoard(hub: StationHub(id: "HUBABW", name: "Abbey Wood",
            stopIDs: ["910GABWD"], lineIDs: [.thameslink]), line: .thameslink)
        let journey = ScheduledJourney(days: [1, 2, 3, 4, 5],
            morning: .init(startMinute: 480, endMinute: 600, board: morningBoard),
            afternoon: .init(startMinute: 960, endMinute: 1080, board: afternoonBoard))
        #expect(ScheduledJourney.validationError(for: [journey]) == nil)
        #expect(ScheduledJourney.validationError(for: journey, existing: [journey]) == nil)
    }

    @Test func anotherJourneyConflictNamesItsStationWindowAndSharedDays() throws {
        let saved = ScheduledJourney(name: "Office", days: [1, 3],
            morning: .init(startMinute: 480, endMinute: 600, board: board))
        let draft = ScheduledJourney(morning: .init(startMinute: 540, endMinute: 660, board: board))
        let error = try #require(ScheduledJourney.validationError(for: draft, existing: [saved]))
        #expect(error.contains("another enabled journey"))
        #expect(error.contains("Office"))
        #expect(error.contains("Oxford Circus (08:00–10:00)"))
        #expect(error.contains("Mon, Wed"))
        #expect(error.contains("Journeys → My scheduled journeys"))
        var paused = saved
        paused.enabled = false
        #expect(ScheduledJourney.validationError(for: draft, existing: [paused]) == nil)
    }

    @Test func editingAJourneyDoesNotCompareAgainstItsPreviousTimesOrCountItTwice() {
        let saved = ScheduledJourney(morning: .init(startMinute: 480, endMinute: 600, board: board))
        var draft = saved
        draft.morning?.startMinute = 510
        #expect(ScheduledJourney.validationError(for: draft, existing: [saved], maximum: 1) == nil)
    }

    @Test func conflictsIncludeEveryOverlappingJourneyButExcludePausedAdjacentAndOtherDays() {
        let draft = ScheduledJourney(morning: .init(startMinute: 480, endMinute: 600, board: board),
                                     afternoon: .init(startMinute: 960, endMinute: 1080, board: board))
        let first = ScheduledJourney(morning: draft.morning)
        let second = ScheduledJourney(afternoon: draft.afternoon)
        let adjacent = ScheduledJourney(morning: .init(startMinute: 600, endMinute: 660, board: board))
        let weekend = ScheduledJourney(days: [6, 7], morning: draft.morning)
        let paused = ScheduledJourney(enabled: false, morning: draft.morning)
        #expect(draft.conflictingJourneys(in: [draft, first, second, adjacent, weekend, paused]) == [first, second])
        #expect(first.replacementSummary.contains("Oxford Circus · 08:00–10:00"))
    }

    @Test func validatesDurationAndSelectedDays() {
        for (start, end) in [(480, 601), (480, 480), (1380, 60), (-1, 60)] {
            let journey = ScheduledJourney(morning: .init(startMinute: start, endMinute: end, board: board))
            #expect(ScheduledJourney.validationError(for: [journey]) != nil)
        }
        let journey = ScheduledJourney(days: [], morning: .init(startMinute: 480, endMinute: 600, board: board))
        #expect(ScheduledJourney.validationError(for: [journey]) != nil)
    }

    @Test func overlapChecksIncludeBothPeriodsButAllowAdjacentWindowsAndDifferentDays() {
        let a = ScheduledJourney(morning: .init(startMinute: 480, endMinute: 600, board: board))
        var b = ScheduledJourney(afternoon: .init(startMinute: 599, endMinute: 660, board: board))
        #expect(ScheduledJourney.validationError(for: [a, b]) != nil)
        b.afternoon?.startMinute = 600
        #expect(ScheduledJourney.validationError(for: [a, b]) == nil)
        b.afternoon?.startMinute = 599
        b.days = [6, 7]
        #expect(ScheduledJourney.validationError(for: [a, b]) == nil)
        b.days = a.days
        b.enabled = false
        #expect(ScheduledJourney.validationError(for: [a, b]) == nil)
        var same = a
        same.afternoon = b.afternoon
        #expect(ScheduledJourney.validationError(for: [same]) != nil)
    }

    @Test func pausedJourneysStillCountTowardsTheLimit() {
        let journeys = (0..<4).map { _ in ScheduledJourney(enabled: false,
            morning: .init(startMinute: 480, endMinute: 600, board: board)) }
        #expect(ScheduledJourney.validationError(for: journeys) != nil)
        #expect(ScheduledJourney.validationError(for: journeys, maximum: 4) == nil)
    }

    @Test func wireFormatMatchesServerAndUsesMinuteValuesRatherThanDates() throws {
        let journey = ScheduledJourney(id: "journey-0001", name: "Office", days: [1, 3, 5],
            morning: .init(startMinute: 480, endMinute: 600, board: board))
        let data = try JSONEncoder().encode(journey)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let morning = try #require(object["morning"] as? [String: Any])
        let board = try #require(morning["board"] as? [String: Any])
        #expect(morning["startMinute"] as? Int == 480)
        #expect(board["direction"] as? String == "eastbound")
        #expect(board["hubId"] as? String == "940GZZLUOXC")
        #expect(try JSONDecoder().decode(ScheduledJourney.self, from: data) == journey)
    }

    @Test func remoteActivityDecodesScheduleOwnershipAndTwoHourEnd() throws {
        let json = #"{"activityID":"scheduled-1234","scheduleID":"journey-0001","stationHubID":"940GZZLUOXC","stationName":"Oxford Circus","lineIDRaw":"central","direction":"Eastbound","directionFilterRaw":"eastbound","startedAtEpoch":1790665200,"hardEndsAtEpoch":1790672400}"#
        let attributes = try JSONDecoder().decode(DepartureActivityAttributes.self, from: Data(json.utf8))
        #expect(attributes.scheduleID == "journey-0001")
        #expect(attributes.hardEndsAt.timeIntervalSince(attributes.startedAt) == 7200)
        #expect(attributes.directionFilter == .eastbound)
        let manual = try JSONDecoder().decode(DepartureActivityAttributes.self, from: Data("{}".utf8))
        #expect(manual.scheduleID == nil)
    }
}
