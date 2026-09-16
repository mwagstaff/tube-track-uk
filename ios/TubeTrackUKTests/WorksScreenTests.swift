import Foundation
import Testing
@testable import TubeTrackUK

struct WorksScreenTests {
    @Test func quickDatesResolveFromTodayInTheLondonCalendar() throws {
        let monday = try #require(londonDate(year: 2026, month: 8, day: 31, hour: 12))
        let tuesday = try #require(londonDate(year: 2026, month: 9, day: 1))
        let saturday = try #require(londonDate(year: 2026, month: 9, day: 5))
        let sunday = try #require(londonDate(year: 2026, month: 9, day: 6))

        #expect(
            WorksDateSelection.today.date(relativeTo: monday)
                == LondonRailDate.startOfDay(for: monday)
        )
        #expect(WorksDateSelection.tomorrow.date(relativeTo: monday) == tuesday)
        #expect(WorksDateSelection.saturday.date(relativeTo: monday) == saturday)
        #expect(WorksDateSelection.sunday.date(relativeTo: monday) == sunday)
    }

    @Test func weekendQuickDatesAlwaysPointToTheNextWeekend() throws {
        let saturday = try #require(londonDate(year: 2026, month: 9, day: 5, hour: 12))
        let sunday = try #require(londonDate(year: 2026, month: 9, day: 6, hour: 12))
        let followingSaturday = try #require(londonDate(year: 2026, month: 9, day: 12))
        let followingSunday = try #require(londonDate(year: 2026, month: 9, day: 13))

        #expect(WorksDateSelection.saturday.date(relativeTo: saturday) == followingSaturday)
        #expect(WorksDateSelection.sunday.date(relativeTo: sunday) == followingSunday)
    }

    @Test func selectingTodayIncludesOngoingWorkThatStartedInThePast() throws {
        let today = try #require(londonDate(year: 2026, month: 8, day: 31))
        let work = EngineeringWork(
            id: "bank-holiday-work",
            title: "Part closure",
            detail: "Ongoing engineering work",
            lineIDs: [.northern],
            affectedStationIDs: [],
            affectedSegmentIDs: [],
            startDate: try #require(londonDate(year: 2026, month: 8, day: 29)),
            endDate: try #require(londonDate(year: 2026, month: 9, day: 1)),
            source: .unifiedAPI,
            fetchedAt: today,
            confidence: .lineOnly
        )

        #expect(LondonRailDate.works([work], overlapping: today) == [work])
    }

    @Test @MainActor func showDisruptedLinesSyncsTheMapDateAndHighlightState() throws {
        let selectedDate = try #require(londonDate(year: 2026, month: 9, day: 6))
        let appState = TubeAppState()
        appState.selectedTab = .map
        appState.showsWorks = true
        appState.selectedMapNetworkStat = .majorIssues

        appState.showDisruptionsOnMap(for: .custom(selectedDate))

        #expect(appState.selectedTab == .map)
        #expect(!appState.showsWorks)
        #expect(appState.disruptionDateSelection == .custom(selectedDate))
        #expect(appState.selectedDisruptionDate == selectedDate)
        #expect(appState.disruptionHighlightScope == .all)
        #expect(appState.disruptionDisplayMode == .issues)
        #expect(appState.disruptionOverviewFocusGeneration == 1)
        #expect(!appState.isViewingLiveStatus)
    }

    private func londonDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0
    ) -> Date? {
        LondonRailDate.calendar.date(
            from: DateComponents(
                timeZone: LondonRailDate.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour
            )
        )
    }
}
