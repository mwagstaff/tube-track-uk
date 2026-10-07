import Foundation
import Testing
import TubeTrackCore
@testable import TubeTrackUK

struct NationalRailTrackingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [
        ("Platform 1", "P1"), ("Platform 12A", "P12A"), ("Platform A", "PA"),
        ("  platform 2  ", "P2"), ("3", "P3"), ("P4", "P4"),
        ("Platform to be confirmed", nil), ("Platform to be", nil), ("", nil)
    ])
    func platformPillsUseOnlyKnownIdentifiers(platform: String, label: String?) {
        let departure = DepartureActivityAttributes.ContentState.Departure(
            id: "platform", destination: "Victoria", platform: platform, expectedAt: now)
        #expect(departure.platformPillLabel == label)
    }

    @Test(arguments: ["national-rail:SE", "thameslink", "central", "rb6"])
    func platformsAreShownForNationalRailAndThameslink(line: String) {
        let attributes = DepartureActivityAttributes(activityID: "platform", stationHubID: "HUBBEK",
            stationName: "Beckenham Junction", lineIDRaw: line, direction: "All departures", directionFilter: .any,
            startedAt: now, hardEndsAt: now.addingTimeInterval(5400))
        #expect(attributes.showsPlatforms == ["national-rail:SE", "thameslink"].contains(line))
    }

    @Test func liveActivityTimePillsSwitchToClockTimeBeyondTwentyMinutes() throws {
        let departure = try #require(ISO8601DateFormatter().date(from: "2026-10-06T18:27:00Z"))
        let style = DepartureCountdownFormatStyle(expectedAt: departure)
        #expect(style.format(departure.addingTimeInterval(-1200)) == "20 mins")
        #expect(style.format(departure.addingTimeInterval(-1200.001)) == "19:27")
        #expect(style.format(departure.addingTimeInterval(-1320)) == "19:27")
        #expect(style.format(departure.addingTimeInterval(-120)) == "2 mins")
        #expect(style.format(departure.addingTimeInterval(-59)) == "Due")
        let midnight = try #require(ISO8601DateFormatter().date(from: "2026-10-06T23:05:00Z"))
        #expect(DepartureCountdownFormatStyle(expectedAt: midnight).format(midnight.addingTimeInterval(-1800)) == "00:05")
    }

    private func prediction(_ id: String, line: String = "national-rail:SE", minutes: Int,
                            status: RailServiceStatus = .onTime, confirmed: Bool = true,
                            direction: DepartureDirectionFilter? = .northbound) -> TfLArrivalPrediction {
        let time = now.addingTimeInterval(Double(minutes * 60))
        return TfLArrivalPrediction(id: id, vehicleId: nil, lineId: line, stationName: nil,
            naptanId: "BKJ", platformName: "Platform 2", direction: direction?.rawValue,
            destinationName: "London Victoria", destinationNaptanId: nil, towards: nil,
            expectedArrival: confirmed ? time : nil, timeToStation: nil, currentLocation: nil,
            scheduledDeparture: time, serviceStatus: status, operatorName: "Southeastern")
    }

    @Test func operatorGroupsHaveStableDirectionalBoardsAndKeepUnknownServicesVisible() throws {
        let arrivals = [prediction("southbound", minutes: 2, direction: .southbound),
            prediction("northbound", minutes: 1),
            prediction("eastbound", minutes: 3, direction: .eastbound),
            prediction("westbound", minutes: 4, direction: .westbound),
            prediction("unknown", minutes: 5, direction: nil)]
        let operatorGroup = try #require(NationalRailDepartureGroup.groups(from: arrivals).first)
        #expect(operatorGroup.id == "national-rail:SE")
        let groups = operatorGroup.directionGroups
        #expect(groups.map(\.direction) == [.northbound, .southbound, .eastbound, .westbound, .any])
        #expect(groups.map(\.id) == ["national-rail:SE:northbound", "national-rail:SE:southbound",
            "national-rail:SE:eastbound", "national-rail:SE:westbound", "national-rail:SE"])
        #expect(groups.map(\.directionLabel) == ["Northbound", "Southbound", "Eastbound", "Westbound", "Other departures"])
        #expect(groups.map { $0.arrivals.map(\.id) } == [["northbound"], ["southbound"], ["eastbound"], ["westbound"], ["unknown"]])
    }

    @Test func trackingFiltersDirectionAndUsesOnlyThatDirectionsDisruptions() {
        let arrivals = [prediction("northbound", minutes: 1),
            prediction("southbound", minutes: 2, status: .cancelled, direction: .southbound),
            prediction("unknown", minutes: 3, direction: nil)]
        let northbound = DepartureActivityBoard.nationalRailContentState(from: arrivals,
            operatorID: "national-rail:SE", updatedAt: now, sequence: 1, direction: .northbound)
        #expect(northbound.departures.map(\.id) == ["northbound"])
        #expect(northbound.conditionRank == 4 && northbound.conditionHeadline == "Departures on time")
        let southbound = DepartureActivityBoard.nationalRailContentState(from: arrivals,
            operatorID: "national-rail:SE", updatedAt: now, sequence: 1, direction: .southbound)
        #expect(southbound.departures.map(\.id) == ["southbound"])
        #expect(southbound.conditionRank == 1 && southbound.conditionHeadline == "Cancellations")
        let all = DepartureActivityBoard.nationalRailContentState(from: arrivals,
            operatorID: "national-rail:SE", updatedAt: now, sequence: 1)
        #expect(all.departures.count == 3)
    }

    @Test func trackingFiltersOperatorsOrdersTrainsAndKeepsFourUniqueRows() {
        let first = prediction("first", minutes: 1)
        let arrivals = [prediction("last", minutes: 30), prediction("other", line: "national-rail:SN", minutes: 0),
                        prediction("third", minutes: 3), first, first, prediction("second", minutes: 2),
                        prediction("fourth", minutes: 4)]
        let state = DepartureActivityBoard.nationalRailContentState(from: arrivals,
            operatorID: "national-rail:SE", updatedAt: now, sequence: 7)
        #expect(state.departures.map(\.id) == ["first", "second", "third", "fourth"])
        #expect(state.departures.allSatisfy { $0.platform == "Platform 2" })
        #expect(state.updatedAt == now && state.sequence == 7)
        #expect(state.conditionRank == 4 && state.conditionHeadline == "Departures on time")
    }

    @Test func unconfirmedDelayIsRetainedWithoutInventingACountdown() throws {
        let state = DepartureActivityBoard.nationalRailContentState(from: [
            prediction("delayed", minutes: -10, status: .delayed, confirmed: false),
            prediction("cancelled", minutes: 2, status: .cancelled)],
            operatorID: "national-rail:SE", updatedAt: now, sequence: 1)
        #expect(state.departures[0].isDelayed && !state.departures[0].hasExpectedTime)
        #expect(state.upcoming(at: now.addingTimeInterval(300)).map(\.id) == ["delayed"])
        #expect(state.departures[1].isCancelled)
        #expect(state.conditionRank == 1 && state.conditionHeadline == "Cancellations")
        let decoded = try JSONDecoder().decode(DepartureActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func operatorNameAndStationLinkSurviveRelaunch() throws {
        let attributes = DepartureActivityAttributes(activityID: "rail", stationHubID: "nr:BKJ",
            stationName: "Beckenham Junction", lineIDRaw: "national-rail:SE", direction: "All departures",
            directionFilter: .any, startedAt: now, hardEndsAt: now.addingTimeInterval(5400),
            operatorName: "Southeastern")
        let decoded = try JSONDecoder().decode(DepartureActivityAttributes.self,
            from: JSONEncoder().encode(attributes))
        #expect(decoded == attributes && decoded.isNationalRailOperator)
        #expect(decoded.lineName == "Southeastern")
        #expect(DeepLink(url: decoded.deepLink.url) == .station(id: "nr:BKJ", line: nil))
        let old = try JSONDecoder().decode(DepartureActivityAttributes.self,
            from: Data(#"{"lineIDRaw":"central"}"#.utf8))
        #expect(old.operatorName == nil && old.lineName == "Central")
        let departure = try JSONDecoder().decode(DepartureActivityAttributes.ContentState.Departure.self,
            from: Data(#"{"id":"old","expectedAtEpoch":1800000000}"#.utf8))
        #expect(departure.hasExpectedTime)
    }
}
