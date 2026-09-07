import Foundation

struct TubeGameAchievement: Equatable, Identifiable, Sendable {
    let category: String
    let period: String
    let value: Int

    var isGameCenter = false

    var id: String { category + period + String(isGameCenter) }
    var message: String {
        isGameCenter
            ? "New \(period) best on Game Center: \(category)!"
            : "New \(period) best: \(category)!"
    }

    static func merging(local: [Self], gameCenter: [Self]) -> [Self] {
        gameCenter + local.filter { local in !gameCenter.contains { $0.category == local.category } }
    }
}

/// Independent of the points leaderboard: a run outside the top ten can still
/// set a record in another category. Day/week boundaries follow the local calendar.
struct TubeGamePersonalBests: Codable {
    var allTime: [String: Int] = [:]
    var daily: [String: Int] = [:]
    var weekly: [String: Int] = [:]
    var day: Date?
    var week: Date?

    mutating func record(
        _ record: TubeGameScoreRecord,
        calendar: Calendar = .current
    ) -> [TubeGameAchievement] {
        let nextDay = calendar.startOfDay(for: record.playedAt)
        let nextWeek = calendar.dateInterval(of: .weekOfYear, for: record.playedAt)?.start ?? nextDay
        if day != nextDay { daily = [:]; day = nextDay }
        if week != nextWeek { weekly = [:]; week = nextWeek }
        let metrics = [
            ("score", record.score),
            ("stations", record.stationsEaten),
            ("lines cleared", record.linesCleared),
            ("termini", record.terminusStationsReached),
            ("combo", record.maxCombo),
        ]
        var achievements: [TubeGameAchievement] = []
        for (category, value) in metrics {
            let period: String?
            if value > allTime[category, default: 0] {
                period = "personal"
            } else if value > weekly[category, default: 0] {
                period = "weekly personal"
            } else if value > daily[category, default: 0] {
                period = "daily personal"
            } else {
                period = nil
            }
            if let period {
                achievements.append(.init(category: category, period: period, value: value))
            }
            allTime[category] = max(allTime[category, default: 0], value)
            weekly[category] = max(weekly[category, default: 0], value)
            daily[category] = max(daily[category, default: 0], value)
        }
        return achievements
    }
}
