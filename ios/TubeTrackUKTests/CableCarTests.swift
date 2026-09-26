import Foundation
import Testing
@testable import TubeTrackUK

struct CableCarTests {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func hours(validThrough: String = "2027-04-30", bankHolidays: [String] = [], exceptions: [String: CableCarHours.Window] = [:]) throws -> CableCarHours {
        let bundled = try #require(RiverBundle.load("CableCarHours", as: CableCarHours.self))
        return .init(sourceURL: bundled.sourceURL, reviewedOn: "2026-09-25", validFrom: "2026-09-25", validThrough: validThrough,
                     weekly: bundled.weekly, bankHolidays: bankHolidays, exceptions: exceptions)
    }
    func status(_ severity: Int, reason: String? = nil, periods: [TfLValidityPeriod] = []) -> CableCarStatus {
        .init(id: "london-cable-car", name: "London Cable Car", entries: [
            .init(id: 0, statusSeverity: severity, statusSeverityDescription: severity == 10 ? "Good Service" : severity == 4 ? "Planned Closure" : "No Service", reason: reason, validityPeriods: periods)
        ])
    }
    func resolve(_ now: Date, severity: Int = 10, stale: Bool = false, age: Double = 0, hours: CableCarHours?, works: [CableCarWork] = []) -> CableCarPresentation {
        CableCarPolicy.resolve(now: now, status: status(severity), updatedAt: now.addingTimeInterval(-age), stale: stale, hours: hours, works: works)
    }

    @Test func goodServiceOvernightDoesNotMeanOpenAndBoundariesAreExclusive() throws {
        let hours = try hours()
        #expect(resolve(date("2026-09-25T00:00:00Z"), hours: hours).kind == .scheduledClosed)
        #expect(resolve(date("2026-09-25T07:59:59Z"), hours: hours).kind == .scheduledClosed)
        #expect(resolve(date("2026-09-25T08:00:00Z"), hours: hours).kind == .open)
        #expect(resolve(date("2026-09-25T20:59:59Z"), hours: hours).kind == .open)
        #expect(resolve(date("2026-09-25T21:00:00Z"), hours: hours).kind == .scheduledClosed)
        #expect(!resolve(date("2026-09-25T00:00:00Z"), hours: hours).isIssue)
        #expect(!resolve(date("2026-09-25T00:00:00Z"), severity: 20, hours: hours).isIssue)
    }

    @Test func freshSuspensionWinsButExpiredStatusNeverClosesAnOtherwiseOpenService() throws {
        let now = date("2026-09-25T12:00:00Z"), hours = try hours()
        #expect(resolve(now, severity: 2, hours: hours).kind == .suspended)
        #expect(resolve(now, severity: 2, stale: true, hours: hours).kind == .unknown)
        #expect(resolve(now, severity: 2, age: 121, hours: hours).kind == .unknown)
        #expect(resolve(now, severity: 999, hours: hours).kind == .unknown)
        #expect(resolve(now, severity: 9, hours: hours).kind == .disrupted)
        #expect(!resolve(now, severity: 5, hours: hours).isClosed)
        #expect(resolve(now, hours: nil).kind == .unknown)
        let expired = status(2, periods: [.init(fromDate: now.addingTimeInterval(-3600), toDate: now)])
        #expect(CableCarPolicy.resolve(now: now, status: expired, updatedAt: now, stale: false, hours: hours, works: []).kind == .unknown)
    }

    @Test func londonCalendarHandlesDSTBankHolidaysExceptionsAndScheduleExpiry() throws {
        let hours = try hours(bankHolidays: ["2026-12-28"], exceptions: ["2026-12-25": .init(opens: nil, closes: nil)])
        let summer = date("2026-10-24T00:00:00Z"), winter = date("2026-10-25T00:00:00Z")
        #expect(try #require(hours.intervals(on: summer, now: summer)?.first).start == date("2026-10-24T08:00:00Z"))
        #expect(try #require(hours.intervals(on: winter, now: winter)?.first).start == date("2026-10-25T09:00:00Z"))
        let holiday = date("2026-12-28T12:00:00Z")
        #expect(try #require(hours.intervals(on: holiday, now: holiday)?.first).start == date("2026-12-28T09:00:00Z"))
        let christmas = date("2026-12-25T12:00:00Z")
        #expect(hours.intervals(on: christmas, now: christmas) == [])
        #expect(hours.nextOpening(after: christmas, now: christmas) == date("2026-12-26T09:00:00Z"))
        let expired = try self.hours(validThrough: "2026-10-24")
        #expect(expired.intervals(on: winter, now: winter) == nil)
        #expect(resolve(winter, hours: expired).kind == .unknown)
        var conflicting = hours
        conflicting.isVerified = false
        #expect(conflicting.intervals(on: summer, now: summer) == nil)
    }

    @Test func plannedClosureHasExactValidityAndNextOpeningSkipsMaintenance() throws {
        let start = date("2026-09-25T08:00:00Z"), end = date("2026-09-25T10:00:00Z")
        let work = CableCarWork(id: "maintenance", title: "Planned Closure", reason: "Maintenance", severity: 4, start: start, end: end)
        let hours = try hours()
        #expect(resolve(start, hours: hours, works: [work]).kind == .plannedClosed)
        #expect(resolve(end, hours: hours, works: [work]).kind == .open)
        #expect(hours.nextOpening(after: start.addingTimeInterval(-1), now: start, closures: [work]) == end)
        #expect(work.overlaps(DisruptionTimeWindow.am.interval(on: start)))
        #expect(!work.overlaps(DisruptionTimeWindow.pm.interval(on: start)))
    }

    @Test @MainActor func selectionsFavouritesAndLayerSurviveWithoutAffectingRailAndRiver() throws {
        let suite = "CableCarTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        let terminal = try #require(app.cableCar.network.terminals.first)
        #expect(app.cableCar.network.terminals.count == 2)
        #expect(app.cableCar.network.terminals.allSatisfy { CableCarSchematic.anchors[$0.id] != nil })
        app.selectedStationID = "old"
        app.river.selectedPierId = "old-pier"
        app.selectCableCar(terminal: terminal)
        #expect(app.selectedStationID == nil && !app.river.hasSelection)
        #expect(app.cableCar.hasSelection && app.cableCar.selectedTerminalID == terminal.id)
        #expect(defaults.bool(forKey: "cableCarEnabled"))
        app.favourites.toggle(.terminal(terminal))
        app.favourites.toggle(.init(stopId: "rail", name: "Rail station", kind: .station))
        #expect(FavouriteStopsStore(defaults: defaults).stops.count == 2)
        app.select(pier: try #require(app.river.network.piers.first))
        #expect(!app.cableCar.hasSelection && app.cableCar.isEnabled)
        app.selectCableCar(); app.cableCar.isEnabled = false
        #expect(!app.cableCar.hasSelection)
        #expect(!defaults.bool(forKey: "cableCarEnabled"))
    }

    @Test func partialDayAndDisjointClosuresCannotBecomeAnAllDayClosure() {
        let morning = DateInterval(start: date("2026-09-25T05:00:00Z"), end: date("2026-09-25T11:00:00Z"))
        func closure(_ start: String, _ end: String) -> CableCarWork {
            .init(id: start, title: "Planned Closure", reason: nil, severity: 4, start: date(start), end: date(end))
        }
        let early = closure("2026-09-25T05:00:00Z", "2026-09-25T08:00:00Z")
        let late = closure("2026-09-25T09:00:00Z", "2026-09-25T11:00:00Z")
        #expect(!CableCarPolicy.covers([morning], with: [early, late]))
        let bridge = closure("2026-09-25T08:00:00Z", "2026-09-25T09:00:00Z")
        #expect(CableCarPolicy.covers([morning], with: [late, early, bridge]))
        #expect(!CableCarPolicy.covers([], with: [early]))
    }

    @Test @MainActor func savedStatusRetainsAgeAndNeverBecomesFreshOnRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let now = date("2026-09-25T12:00:00Z")
        try await cache.save(CableCarSnapshot(data: status(2), updatedAt: now.addingTimeInterval(-3600)), named: "cable-car-status.json")
        let work = CableCarWork(id: "saved", title: "Planned Closure", reason: "Maintenance", severity: 4,
            start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        try await cache.save(CableCarSnapshot(data: CableCarWorks(from: "2026-09-25", to: "2026-09-26", undatedCount: 0, works: [work]),
            updatedAt: now.addingTimeInterval(-3600)), named: "cable-car-works.json")
        let suite = "CableCarCacheTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cable = CableCarState(client: TubeTrackAPIClient(), defaults: defaults, cache: cache)
        cable.isEnabled = true
        await cable.restore()
        cable.updatePresentation(now: now)
        #expect(cable.statusUpdatedAt == now.addingTimeInterval(-3600))
        #expect(cable.statusStale)
        #expect(cable.presentation.kind == .unknown)
        #expect(cable.isOverviewUnconfirmed && cable.overviewIssueCount == 0)
        cable.setContext(date: now, windows: [.am, .pm], offline: true)
        #expect(cable.presentation.kind == .planned)
        #expect(!cable.presentation.isClosed)
        #expect(cable.presentation.headline.contains("unconfirmed"))
        #expect(cable.isOverviewUnconfirmed && cable.overviewIssueCount == 0)
        cable.setContext(date: now, windows: [.overnight], offline: true)
        cable.updatePresentation(now: now)
        #expect(cable.presentation.kind == .scheduledClosed)
        #expect(!cable.presentation.isIssue)
    }
}
