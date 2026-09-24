import Foundation
import Testing
@testable import TubeTrackCore

struct WidgetRefreshPolicyTests {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    /// 2026-09-21 is a Monday, 2026-09-26 a Saturday, 2026-09-27 a Sunday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func commutingPeaksGetTheTightestInterval() {
        #expect(WidgetRefreshPolicy.interval(at: date(21, 8), calendar: calendar) == WidgetRefreshPolicy.peakInterval)
        #expect(WidgetRefreshPolicy.interval(at: date(21, 17, 30), calendar: calendar) == WidgetRefreshPolicy.peakInterval)
        #expect(WidgetRefreshPolicy.interval(at: date(21, 12), calendar: calendar) == WidgetRefreshPolicy.standardInterval)
        #expect(WidgetRefreshPolicy.interval(at: date(21, 2), calendar: calendar) == WidgetRefreshPolicy.overnightInterval)
    }

    @Test func weekendsHaveNoCommutingPeak() {
        #expect(WidgetRefreshPolicy.interval(at: date(26, 8), calendar: calendar) == WidgetRefreshPolicy.standardInterval)
        #expect(WidgetRefreshPolicy.interval(at: date(27, 17, 30), calendar: calendar) == WidgetRefreshPolicy.standardInterval)
        // Overnight still applies at the weekend.
        #expect(WidgetRefreshPolicy.interval(at: date(26, 3), calendar: calendar) == WidgetRefreshPolicy.overnightInterval)
    }

    @Test func peakBoundariesAreHalfOpen() {
        #expect(WidgetRefreshPolicy.interval(at: date(21, 7), calendar: calendar) == WidgetRefreshPolicy.peakInterval)
        #expect(WidgetRefreshPolicy.interval(at: date(21, 9, 29), calendar: calendar) == WidgetRefreshPolicy.peakInterval)
        #expect(WidgetRefreshPolicy.interval(at: date(21, 9, 30), calendar: calendar) == WidgetRefreshPolicy.standardInterval)
        #expect(WidgetRefreshPolicy.interval(at: date(21, 19), calendar: calendar) == WidgetRefreshPolicy.standardInterval)
    }

    @Test func aReloadDueJustBeforePeakIsPulledForwardToThePeak() {
        // 06:50 + 30 min would land at 07:20, twenty minutes into the commute.
        let pulled = WidgetRefreshPolicy.nextReload(after: date(21, 6, 50), calendar: calendar)
        #expect(pulled == date(21, 7))
    }

    @Test func pullingForwardNeverAsksForAnImmediateReload() {
        // 06:58 is two minutes from the peak; the floor keeps us honest.
        let pulled = WidgetRefreshPolicy.nextReload(after: date(21, 6, 58), calendar: calendar)
        #expect(pulled == date(21, 7, 3))
    }

    @Test func offPeakReloadsAreNotPulledForward() {
        #expect(WidgetRefreshPolicy.nextReload(after: date(21, 12), calendar: calendar) == date(21, 12, 30))
        #expect(WidgetRefreshPolicy.nextReload(after: date(21, 2), calendar: calendar) == date(21, 4))
    }

    /// The whole point of the policy: a day of requests has to fit the budget
    /// WidgetKit actually grants (roughly 40–70 for a frequently viewed widget).
    @Test func aFullWeekdayStaysWithinTheReloadBudget() {
        var cursor = date(21, 0)
        let end = date(22, 0)
        var reloads = 0
        while cursor < end {
            cursor = WidgetRefreshPolicy.nextReload(after: cursor, calendar: calendar)
            reloads += 1
            #expect(reloads < 200, "policy failed to advance")
        }
        #expect(reloads <= 70, "asked for \(reloads) reloads, over Apple's budget")
        #expect(reloads >= 30, "asked for only \(reloads) reloads, wasting available budget")
    }
}
