import Foundation

/// When a widget should ask WidgetKit for its next reload.
///
/// WidgetKit budgets a frequently-viewed widget to roughly 40–70 reloads a day.
/// Asking for more does not buy fresher data — the system simply throttles the
/// widget, and it ends up staler than one that asked for less. So the budget is
/// spent where it is worth most: tightest around the commute, loosest overnight.
///
/// Reloads the passenger triggers (tapping refresh, opening the app) and
/// server-driven pushes are on top of this and are not billed the same way.
public enum WidgetRefreshPolicy {
    public static let peakInterval: TimeInterval = 15 * 60
    public static let standardInterval: TimeInterval = 30 * 60
    public static let overnightInterval: TimeInterval = 120 * 60
    /// Never ask for a reload sooner than this, whatever else is going on.
    public static let minimumInterval: TimeInterval = 5 * 60

    /// Weekday commuting peaks, in minutes from local midnight.
    static let morningPeak = (start: 7 * 60, end: 9 * 60 + 30)
    static let eveningPeak = (start: 16 * 60 + 30, end: 19 * 60)
    /// Between these the network is mostly closed and nothing changes.
    static let overnight = (start: 0 * 60 + 30, end: 5 * 60)

    public static func interval(at date: Date, calendar: Calendar = .current) -> TimeInterval {
        let minutes = minutesIntoDay(date, calendar: calendar)
        if minutes >= overnight.start && minutes < overnight.end {
            return overnightInterval
        }
        if isWeekday(date, calendar: calendar), isPeak(minutes) {
            return peakInterval
        }
        return standardInterval
    }

    /// The next reload date, pulled forward when a peak is about to start so the
    /// widget is current for the walk to the station rather than 20 minutes into it.
    public static func nextReload(after date: Date, calendar: Calendar = .current) -> Date {
        let candidate = date.addingTimeInterval(interval(at: date, calendar: calendar))
        guard let peakStart = nextPeakStart(after: date, calendar: calendar), peakStart < candidate else {
            return candidate
        }
        return max(peakStart, date.addingTimeInterval(minimumInterval))
    }

    static func isPeak(_ minutesIntoDay: Int) -> Bool {
        (minutesIntoDay >= morningPeak.start && minutesIntoDay < morningPeak.end)
            || (minutesIntoDay >= eveningPeak.start && minutesIntoDay < eveningPeak.end)
    }

    private static func isWeekday(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        // Calendar weekday is 1 = Sunday, 7 = Saturday.
        return weekday != 1 && weekday != 7
    }

    private static func minutesIntoDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// The start of the next weekday peak window, searching today and tomorrow.
    private static func nextPeakStart(after date: Date, calendar: Calendar) -> Date? {
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date),
                  isWeekday(day, calendar: calendar) else {
                continue
            }
            for peak in [morningPeak, eveningPeak] {
                guard let start = calendar.date(
                    bySettingHour: peak.start / 60,
                    minute: peak.start % 60,
                    second: 0,
                    of: day
                ), start > date else {
                    continue
                }
                return start
            }
        }
        return nil
    }
}
