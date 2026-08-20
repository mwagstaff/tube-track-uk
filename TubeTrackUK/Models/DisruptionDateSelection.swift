import Foundation

enum LondonRailDate {
    static let timeZone = TimeZone(identifier: "Europe/London")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = timeZone
        return calendar
    }

    static func startOfDay(
        for date: Date,
        calendar: Calendar = LondonRailDate.calendar
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    static func dayInterval(
        for date: Date,
        calendar: Calendar = LondonRailDate.calendar
    ) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    static func upcoming(
        weekday: Int,
        from referenceDate: Date,
        calendar: Calendar = LondonRailDate.calendar
    ) -> Date {
        let start = calendar.startOfDay(for: referenceDate)
        let currentWeekday = calendar.component(.weekday, from: start)
        let dayOffset = (weekday - currentWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: dayOffset, to: start) ?? start
    }

    static func works(
        _ works: [EngineeringWork],
        overlapping date: Date,
        calendar: Calendar = LondonRailDate.calendar
    ) -> [EngineeringWork] {
        let interval = dayInterval(for: date, calendar: calendar)
        return works.filter { work in
            work.startDate < interval.end && work.endDate > interval.start
        }
    }

    static func works(
        _ works: [EngineeringWork],
        overlappingAny windows: Set<DisruptionTimeWindow>,
        on date: Date,
        calendar: Calendar = LondonRailDate.calendar
    ) -> [EngineeringWork] {
        guard !windows.isEmpty else { return [] }
        let intervals = windows.map { $0.interval(on: date, calendar: calendar) }
        return works.filter { work in
            intervals.contains { interval in
                work.startDate < interval.end && work.endDate > interval.start
            }
        }
    }

    static func dateIdentifier(
        for date: Date,
        calendar: Calendar = LondonRailDate.calendar
    ) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return [
            components.year,
            components.month,
            components.day,
            components.hour,
            components.minute,
        ]
        .map { String($0 ?? 0) }
        .joined(separator: "-")
    }

    static func formatted(_ date: Date, dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}

enum DisruptionTimeWindow: String, CaseIterable, Identifiable, Sendable {
    case am
    case pm
    case overnight

    static let defaultSelected: Set<Self> = [.am, .pm]

    var id: Self { self }

    var title: String {
        switch self {
        case .am: "AM"
        case .pm: "PM"
        case .overnight: "Overnight"
        }
    }

    var rangeTitle: String {
        switch self {
        case .am: "06:00 to 11:59"
        case .pm: "12:00 to 23:59"
        case .overnight: "00:00 to 05:59"
        }
    }

    var symbol: String {
        switch self {
        case .am: "sunrise.fill"
        case .pm: "sun.max.fill"
        case .overnight: "moon.stars.fill"
        }
    }

    func interval(
        on date: Date,
        calendar: Calendar = LondonRailDate.calendar
    ) -> DateInterval {
        let day = LondonRailDate.dayInterval(for: date, calendar: calendar)
        let sixAM = calendar.date(
            bySettingHour: 6,
            minute: 0,
            second: 0,
            of: day.start
        ) ?? day.start
        let noon = calendar.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: day.start
        ) ?? sixAM

        switch self {
        case .am:
            return DateInterval(start: sixAM, end: noon)
        case .pm:
            return DateInterval(start: noon, end: day.end)
        case .overnight:
            return DateInterval(start: day.start, end: sixAM)
        }
    }
}

enum DisruptionDateSelection: Equatable, Sendable {
    case today
    case thisSaturday
    case thisSunday
    case custom(Date)

    func date(
        relativeTo referenceDate: Date = .now,
        calendar: Calendar = LondonRailDate.calendar
    ) -> Date {
        switch self {
        case .today:
            return calendar.startOfDay(for: referenceDate)
        case .thisSaturday:
            return LondonRailDate.upcoming(
                weekday: 7,
                from: referenceDate,
                calendar: calendar
            )
        case .thisSunday:
            return LondonRailDate.upcoming(
                weekday: 1,
                from: referenceDate,
                calendar: calendar
            )
        case let .custom(date):
            return calendar.startOfDay(for: date)
        }
    }
}
