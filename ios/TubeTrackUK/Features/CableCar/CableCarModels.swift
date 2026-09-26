import CoreLocation
import Foundation
import SwiftUI

struct CableCarTerminal: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var railStationID: String? {
        switch id {
        case "940GZZALGWP": "940GZZLUNGW"
        case "940GZZALRDK": "940GZZDLRVC"
        default: nil
        }
    }
    var railStationName: String { id == "940GZZALGWP" ? "North Greenwich" : "Royal Victoria" }
}

struct CableCarNetwork: Codable, Sendable {
    struct Coordinate: Codable, Sendable {
        let latitude: Double
        let longitude: Double
        var location: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }
    let id: String
    let name: String
    let terminals: [CableCarTerminal]
    let coordinates: [Coordinate]
    static let empty = CableCarNetwork(id: "london-cable-car", name: "London Cable Car", terminals: [], coordinates: [])
}

struct CableCarStatus: Codable, Sendable {
    let id: String
    let name: String
    let entries: [TfLStatusEntry]
}

struct CableCarHours: Codable, Sendable {
    struct Window: Codable, Sendable {
        let opens: Int?
        let closes: Int?
    }
    let sourceURL: String
    let reviewedOn: String
    let validFrom: String
    let validThrough: String
    let weekly: [String: Window]
    let bankHolidays: [String]
    /// An exception with null opens/closes explicitly means no scheduled service.
    let exceptions: [String: Window]
    var isVerified: Bool? = nil

    func intervals(on date: Date, now: Date) -> [DateInterval]? {
        let day = Self.dayKey(date), today = Self.dayKey(now)
        guard isVerified != false, today <= validThrough, today >= validFrom, day >= validFrom, day <= validThrough else { return nil }
        let weekday = bankHolidays.contains(day) ? 1 : LondonRailDate.calendar.component(.weekday, from: date)
        guard let window = exceptions[day] ?? weekly[String(weekday)] else { return nil }
        if window.opens == nil && window.closes == nil { return [] }
        guard let opens = window.opens, let closes = window.closes,
              (0..<1440).contains(opens), (1...1440).contains(closes), closes > opens else { return nil }
        let calendar = LondonRailDate.calendar
        guard let start = calendar.date(bySettingHour: opens / 60, minute: opens % 60, second: 0, of: date),
              let end = closes == 1440 ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
                : calendar.date(bySettingHour: closes / 60, minute: closes % 60, second: 0, of: date) else { return nil }
        return [DateInterval(start: start, end: end)]
    }

    func nextOpening(after date: Date, now: Date, closures: [CableCarWork] = []) -> Date? {
        for offset in 0..<32 {
            guard let day = LondonRailDate.calendar.date(byAdding: .day, value: offset, to: date),
                  let intervals = intervals(on: day, now: now) else { return nil }
            for interval in intervals where interval.end > date {
                var candidate = max(date, interval.start)
                for closure in closures.filter(\.closesService).sorted(by: { $0.start < $1.start }) {
                    if closure.start <= candidate && closure.end > candidate { candidate = closure.end }
                }
                if candidate < interval.end { return candidate }
            }
        }
        return nil
    }
    static func dayKey(_ date: Date) -> String { LondonRailDate.formatted(date, dateFormat: "yyyy-MM-dd") }
}

struct CableCarWork: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let reason: String?
    let severity: Int
    let start: Date
    let end: Date
    var closesService: Bool { CableCarPolicy.closureSeverities.contains(severity) }
    func overlaps(_ interval: DateInterval) -> Bool { start < interval.end && end > interval.start }
    var timeDescription: String {
        "\(LondonRailDate.formatted(start, dateFormat: "d MMM HH:mm")) – \(LondonRailDate.formatted(end, dateFormat: "d MMM HH:mm"))"
    }
}

struct CableCarWorks: Codable, Sendable {
    let from: String
    let to: String
    let undatedCount: Int
    let works: [CableCarWork]
    func covers(_ date: Date) -> Bool {
        let key = CableCarHours.dayKey(date)
        return key >= from && key < to
    }
}

struct CableCarPresentation: Equatable, Sendable {
    enum Kind: String, Sendable { case open, scheduledClosed, suspended, plannedClosed, disrupted, unknown, planned }
    let kind: Kind
    let headline: String
    let detail: String
    let schedule: String
    var isClosed: Bool { [.scheduledClosed, .suspended, .plannedClosed].contains(kind) }
    var isIssue: Bool { [.suspended, .plannedClosed, .disrupted].contains(kind) }
    var routeTint: Color { [.open, .disrupted].contains(kind) ? .red : .secondary }
    var symbol: String {
        switch kind {
        case .open: "checkmark.circle.fill"
        case .scheduledClosed: "moon.zzz.fill"
        case .suspended: "exclamationmark.octagon.fill"
        case .plannedClosed, .planned: "calendar"
        case .disrupted: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

enum CableCarPolicy {
    // From TfL's cable-car severity catalogue. Partial/access restrictions are
    // deliberately not converted into whole-service closures.
    static let closureSeverities: Set<Int> = [1, 2, 3, 4, 16, 20]
    static let disruptionSeverities: Set<Int> = [0, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 17, 19]

    static func covers(_ intervals: [DateInterval], with works: [CableCarWork]) -> Bool {
        !intervals.isEmpty && intervals.allSatisfy { interval in
            var covered = interval.start
            for work in works.filter(\.closesService).sorted(by: { $0.start < $1.start }) where work.start <= covered && work.end > covered {
                covered = work.end
            }
            return covered >= interval.end
        }
    }

    static func isActive(_ entry: TfLStatusEntry, at date: Date) -> Bool {
        guard let periods = entry.validityPeriods, !periods.isEmpty else { return true }
        return periods.contains { period in
            if let start = period.fromDate, let end = period.toDate { return start <= date && date < end }
            return period.isNow == true
        }
    }

    static func resolve(now: Date, status: CableCarStatus?, updatedAt: Date?, stale: Bool,
                        hours: CableCarHours?, works: [CableCarWork]) -> CableCarPresentation {
        let intervals = hours?.intervals(on: now, now: now)
        let currentInterval = intervals?.first { $0.start <= now && now < $0.end }
        let hoursText = intervals.map { spans in
            spans.isEmpty ? "No scheduled service today" : "Published hours " + spans.map {
                "\(LondonRailDate.formatted($0.start, dateFormat: "HH:mm"))–\(LondonRailDate.formatted($0.end, dateFormat: "HH:mm"))"
            }.joined(separator: ", ")
        } ?? "Opening hours unavailable"
        let fresh = !stale && updatedAt.map { now.timeIntervalSince($0) >= -30 && now.timeIntervalSince($0) <= 120 } == true
        let active = fresh ? (status?.entries ?? []).filter { isActive($0, at: now) } : []
        if let closure = active.first(where: { closureSeverities.contains($0.statusSeverity) }) {
            if closure.statusSeverity == 20, intervals != nil, currentInterval == nil {
                let next = hours?.nextOpening(after: now, now: now, closures: works)
                return .init(kind: .scheduledClosed, headline: "Closed", detail: closure.reason ?? "Outside published opening hours",
                    schedule: next.map { "Next scheduled opening \(LondonRailDate.formatted($0, dateFormat: "EEE d MMM, HH:mm"))" } ?? hoursText)
            }
            let planned = closure.statusSeverity == 4
            return .init(kind: planned ? .plannedClosed : .suspended, headline: planned ? "Closed · planned work" : "Closed · \(closure.statusSeverityDescription.lowercased())",
                         detail: closure.reason ?? closure.statusSeverityDescription, schedule: hoursText)
        }
        if let work = works.first(where: { $0.closesService && $0.start <= now && now < $0.end }) {
            return .init(kind: .plannedClosed, headline: "Closed · planned work", detail: "\(work.reason ?? work.title)\n\(work.timeDescription)", schedule: hoursText)
        }
        if let intervals, currentInterval == nil {
            let next = hours?.nextOpening(after: now, now: now, closures: works)
            let nextText = next.map { "Next scheduled opening \(LondonRailDate.formatted($0, dateFormat: "EEE d MMM, HH:mm"))" }
                ?? (intervals.isEmpty ? "No scheduled service today" : "Next opening not yet confirmed")
            return .init(kind: .scheduledClosed, headline: "Closed", detail: "Outside published opening hours", schedule: nextText)
        }
        if let issue = active.first(where: { disruptionSeverities.contains($0.statusSeverity) }) {
            return .init(kind: .disrupted, headline: issue.statusSeverityDescription, detail: issue.reason ?? "TfL reports a service change", schedule: hoursText)
        }
        if currentInterval != nil, !active.isEmpty, active.allSatisfy({ $0.statusSeverity == 10 || $0.statusSeverity == 18 }) {
            return .init(kind: .open, headline: "Open · good service", detail: "TfL reports good service", schedule: hoursText)
        }
        return .init(kind: .unknown, headline: "Status unavailable", detail: active.first?.reason ?? active.first?.statusSeverityDescription ?? "Live service status could not be confirmed", schedule: hoursText)
    }
}
