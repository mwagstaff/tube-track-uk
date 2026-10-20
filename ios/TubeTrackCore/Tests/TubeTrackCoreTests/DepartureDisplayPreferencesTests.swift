import Foundation
import Testing
@testable import TubeTrackCore

struct DepartureDisplayPreferencesTests {
    @Test(arguments: DepartureTransitType.allCases)
    func defaultsAndOverrides(type: DepartureTransitType) throws {
        var preferences = DepartureDisplayPreferences()
        #expect(preferences.matchesRealWorld)
        #expect(preferences.usesClockOverOneHour)
        #expect(preferences.format(for: type, seconds: 120) == type.defaultFormat)
        preferences[type] = type.defaultFormat == .clock ? .minutes : .clock
        #expect(preferences.format(for: type, seconds: 120) == type.defaultFormat)
        preferences.matchesRealWorld = false
        #expect(preferences.format(for: type, seconds: 120) == preferences[type])
        let restored = try JSONDecoder().decode(DepartureDisplayPreferences.self,
            from: JSONEncoder().encode(preferences))
        #expect(restored == preferences)
        preferences.matchesRealWorld = true
        preferences.matchesRealWorld = false
        #expect(preferences[type] == restored[type])
    }

    @Test(arguments: DepartureTransitType.allCases)
    func hourBoundaryAndPrecedence(type: DepartureTransitType) {
        var preferences = DepartureDisplayPreferences()
        preferences.matchesRealWorld = false
        preferences[type] = .minutes
        #expect(preferences.format(for: type, seconds: 3599) == .minutes)
        #expect(preferences.format(for: type, seconds: 3600) == .minutes)
        #expect(preferences.format(for: type, seconds: 3600.01) == .clock)
        preferences.usesClockOverOneHour = false
        #expect(preferences.format(for: type, seconds: 7200) == .minutes)
    }

    @Test(arguments: [
        ("national-rail:SE", DepartureTransitType.nationalRail), ("thameslink", .nationalRail),
        ("central", .underground), ("windrush", .overground), ("elizabeth", .elizabeth),
        ("dlr", .dlr), ("tram", .tram), ("rb1", .riverBus)
    ])
    func mapsTransport(line: String, type: DepartureTransitType) {
        #expect(DepartureTransitType(lineID: line) == type)
    }

    @Test func clockUsesLondonTimeAcrossSummerWinterAndMidnight() throws {
        for (timestamp, expected) in [("2026-10-05T22:31:00Z", "23:31"),
                                      ("2026-12-05T23:31:00Z", "23:31"),
                                      ("2026-10-05T23:05:00Z", "00:05")] {
            let departure = try #require(ISO8601DateFormatter().date(from: timestamp))
            let style = DepartureCountdownFormatStyle(expectedAt: departure, transitType: .nationalRail)
            #expect(style.format(departure.addingTimeInterval(-120)) == expected)
            #expect(StationDepartureMetadata.departureTimeLabel(expectedAt: departure,
                seconds: 120, minutes: 2, transitType: .nationalRail) == expected)
        }
    }

    @Test func mixedBoardModeSurvivesCodingAndOldPayloadsStillDecode() throws {
        let departure = DepartureActivityAttributes.ContentState.Departure(
            id: "rail", destination: "London", platform: nil, expectedAt: .now,
            lineIDRaw: "national-rail:SE")
        let decoded = try JSONDecoder().decode(DepartureActivityAttributes.ContentState.Departure.self,
            from: JSONEncoder().encode(departure))
        #expect(decoded.lineIDRaw == "national-rail:SE")
        let legacy = try JSONDecoder().decode(DepartureActivityAttributes.ContentState.Departure.self,
            from: Data(#"{"id":"old","expectedAtEpoch":1800000000}"#.utf8))
        #expect(legacy.lineIDRaw == nil)
    }
}
