import Foundation
import Testing
@testable import TubeTrackUK

struct GameCenterServiceTests {
    @Test @MainActor func onlineBestIsIndependentOfHigherLocalScores() throws {
        let record = TubeGameScoreRecord(score: 479, stationsEaten: 25, maxCombo: 5,
            configuredDuration: 60, elapsedTime: 40, endReason: .collision,
            runSeed: 1, graphGeneratedAt: "test")
        let achievement = try #require(GameCenterService.personalBest(
            record: record, category: .score, previousScore: 171, period: "personal"))
        #expect(achievement.isGameCenter)
        #expect(achievement.value == 479)
        #expect(achievement.message.contains("Game Center"))
        #expect(GameCenterService.personalBest(record: record, category: .score,
            previousScore: 479, period: "personal") == nil)
        #expect(GameCenterService.personalBest(record: record, category: .score,
            previousScore: 593, period: "personal") == nil)
        #expect(GameCenterService.personalBest(record: record, category: .score,
            previousScore: nil, period: "daily personal") != nil)
        #expect(GameCenterService.personalBest(record: record, category: .linesCleared,
            previousScore: nil, period: "personal") == nil)
        let merged = TubeGameAchievement.merging(
            local: [.init(category: "score", period: "daily personal", value: 479),
                    .init(category: "combo", period: "personal", value: 5)],
            gameCenter: [achievement])
        #expect(merged.map(\.category) == ["score", "combo"])
        #expect(merged.first?.isGameCenter == true)
    }

    @Test func leaderboardIdentifiersAreStableAndVersioned() {
        #expect(GameCenterLeaderboard.score.id == "stationchase.score.v1")
        #expect(GameCenterLeaderboard.stationsEaten.id == "stationchase.stations.v1")
        #expect(GameCenterLeaderboard.linesCleared.id == "stationchase.lines.v1")
        #expect(GameCenterLeaderboard.terminusStationsReached.id == "stationchase.termini.v1")
        #expect(Set(GameCenterLeaderboard.allCases.map(\.id)).count == 4)
    }
}
