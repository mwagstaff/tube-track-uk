import Foundation
import Testing
@testable import TubeTrackUK

struct GameCenterServiceTests {
    @Test @MainActor func offlineRunsRemainLocalAndPersistForLaterGameCenterSync() async throws {
        let suiteName = "GameCenterServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = GameCenterService(defaults: defaults)
        service.setOffline(true)
        service.authenticate()

        #expect(!service.rankingsAvailable)
        #expect(service.authenticationState == .notStarted)

        let localScores = TubeGameHighScoreStore(defaults: defaults)
        var runs: [TubeGameScoreRecord] = []
        for score in 1 ... 12 {
            let record = TubeGameScoreRecord(
                score: score, stationsEaten: score, maxCombo: 1,
                configuredDuration: 60, elapsedTime: 40, endReason: .collision,
                runSeed: UInt64(score), graphGeneratedAt: "bundled"
            )
            runs.append(record)
            localScores.submit(record)
            #expect(await service.submit(record) == [])
            #expect(service.submissionState == .queued(recordID: record.id))
        }

        #expect(localScores.scores.count == 10)
        #expect(localScores.bestScore == 12)
        #expect(!localScores.latestAchievements.isEmpty)
        #expect(service.pendingScoreRecords == runs)
        #expect(GameCenterService(defaults: defaults).pendingScoreRecords == runs)
        #expect(TubeGameHighScoreStore(defaults: defaults).scores == localScores.scores)

        // Retrying the same run never queues it twice, even after an app restart.
        let restored = GameCenterService(defaults: defaults)
        restored.setOffline(true)
        let firstRun = try #require(runs.first)
        _ = await restored.submit(firstRun)
        #expect(restored.pendingScoreRecords == runs)
    }

    @Test @MainActor func offlineManualQuitDoesNotQueueAScore() async throws {
        let suiteName = "GameCenterServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = GameCenterService(defaults: defaults)
        service.setOffline(true)
        let record = TubeGameScoreRecord(
            score: 100, stationsEaten: 10, maxCombo: 1,
            configuredDuration: 60, elapsedTime: 40, endReason: .manualQuit,
            runSeed: 1, graphGeneratedAt: "bundled"
        )

        #expect(await service.submit(record) == [])
        #expect(service.pendingScoreRecords.isEmpty)
        #expect(service.submissionState == .idle)
        #expect(GameCenterService(defaults: defaults).pendingScoreRecords.isEmpty)
    }

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
        let timeAchievement = try #require(GameCenterService.personalBest(
            record: record, category: .timeSurvived, previousScore: 39, period: "personal"))
        #expect(timeAchievement.value == 40)
        #expect(timeAchievement.category == "time survived")
        #expect(GameCenterService.personalBest(record: record, category: .timeSurvived,
            previousScore: 40, period: "personal") == nil)
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
        #expect(GameCenterLeaderboard.timeSurvived.id == "stationchase.time.v1")
        #expect(Set(GameCenterLeaderboard.allCases.map(\.id)).count == 5)
    }
}
