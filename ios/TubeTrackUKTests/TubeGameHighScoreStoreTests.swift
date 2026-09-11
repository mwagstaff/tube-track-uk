import Foundation
import Testing
@testable import TubeTrackUK

struct TubeGameHighScoreStoreTests {
    @Test @MainActor func eligibleScorePersistsAndProvidesShareCopy() throws {
        let suite = try TestDefaults()
        defer { suite.remove() }

        let record = makeRecord(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            score: 240,
            stationsEaten: 12,
            maxCombo: 4,
            endReason: .completed
        )
        let store = TubeGameHighScoreStore(defaults: suite.defaults)

        #expect(store.submit(record))
        #expect(store.bestScore == 240)

        let restored = TubeGameHighScoreStore(defaults: suite.defaults)
        #expect(restored.scores == [record])
        #expect(restored.shareText(for: record) == record.shareText)
        #expect(record.shareText.contains("Track-Man"))
        #expect(record.shareText.contains("TubeTrack UK"))
        #expect(record.shareText.contains("42 seconds"))
        #expect(!record.shareText.localizedCaseInsensitiveContains("Pac-Man"))
    }

    @Test func timeSurvivedIsClampedAndRoundedDown() {
        #expect(makeRecord(score: 1, elapsedTime: 42.9).timeSurvivedSeconds == 42)
        #expect(makeRecord(score: 1, elapsedTime: 75).timeSurvivedSeconds == 60)
        #expect(makeRecord(score: 1, elapsedTime: -1).timeSurvivedSeconds == 0)
    }

    @Test @MainActor func leaderboardKeepsOnlyTheTenHighestScores() throws {
        let suite = try TestDefaults()
        defer { suite.remove() }
        let store = TubeGameHighScoreStore(defaults: suite.defaults)

        for score in 1...12 {
            let suffix = String(format: "%012d", score)
            let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-\(suffix)"))
            #expect(store.submit(makeRecord(id: id, score: score)))
        }

        #expect(store.scores.count == 10)
        #expect(store.scores.map(\.score) == Array((3...12).reversed()))

        let restored = TubeGameHighScoreStore(defaults: suite.defaults)
        #expect(restored.scores == store.scores)
    }

    @Test @MainActor func tiesUseStationsThenComboThenOldestDateThenID() throws {
        let suite = try TestDefaults()
        defer { suite.remove() }
        let store = TubeGameHighScoreStore(defaults: suite.defaults)
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let thirdID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let fourthID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let fifthID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000005"))

        let records = [
            makeRecord(id: fifthID, score: 100, stationsEaten: 6, maxCombo: 2, playedAt: 10),
            makeRecord(id: fourthID, score: 100, stationsEaten: 7, maxCombo: 1, playedAt: 40),
            makeRecord(id: thirdID, score: 100, stationsEaten: 6, maxCombo: 3, playedAt: 20),
            makeRecord(id: secondID, score: 100, stationsEaten: 6, maxCombo: 3, playedAt: 10),
            makeRecord(id: firstID, score: 100, stationsEaten: 6, maxCombo: 3, playedAt: 10),
        ]
        for record in records {
            #expect(store.submit(record))
        }

        #expect(store.scores.map(\.id) == [fourthID, firstID, secondID, thirdID, fifthID])
    }

    @Test @MainActor func corruptAndUnknownStorageVersionsLoadAsEmpty() throws {
        let suite = try TestDefaults()
        defer { suite.remove() }

        suite.defaults.set(Data("not-json".utf8), forKey: TestDefaults.storageKey)
        #expect(TubeGameHighScoreStore(defaults: suite.defaults).scores.isEmpty)

        let unknownArchive = TestArchive(
            version: 999,
            scores: [makeRecord(score: 999)]
        )
        suite.defaults.set(try JSONEncoder().encode(unknownArchive), forKey: TestDefaults.storageKey)
        #expect(TubeGameHighScoreStore(defaults: suite.defaults).scores.isEmpty)
    }

    @Test @MainActor func versionOneScoresMigrateWithNoClearedLines() throws {
        let suite = try TestDefaults()
        defer { suite.remove() }
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000042"))
        let legacy = LegacyScoreArchive(
            version: 1,
            scores: [LegacyScoreRecord(
                id: id,
                score: 240,
                stationsEaten: 12,
                maxCombo: 4,
                configuredDuration: 60,
                elapsedTime: 42,
                endReason: .completed,
                playedAt: Date(timeIntervalSince1970: 100),
                runSeed: 123,
                graphGeneratedAt: "2026-08-23T20:26:26.921154+00:00",
                rulesVersion: 1
            )]
        )
        suite.defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: TestDefaults.storageKey
        )

        let restored = TubeGameHighScoreStore(defaults: suite.defaults)
        #expect(restored.scores.count == 1)
        #expect(restored.scores.first?.id == id)
        #expect(restored.scores.first?.linesCleared == 0)
    }

    @Test @MainActor func manualQuitIsExcludedFromLeaderboardAndPersistence() throws {
        let suite = try TestDefaults()
        defer { suite.remove() }
        let store = TubeGameHighScoreStore(defaults: suite.defaults)
        let quit = makeRecord(score: 500, endReason: .manualQuit)

        #expect(!store.submit(quit))
        #expect(store.scores.isEmpty)
        #expect(store.bestScore == 0)
        #expect(TubeGameHighScoreStore(defaults: suite.defaults).scores.isEmpty)
    }

    @Test @MainActor func submitReportsWhenScoreMissesTheTopTen() throws {
        let suite = try TestDefaults()
        defer { suite.remove() }
        let store = TubeGameHighScoreStore(defaults: suite.defaults)

        for score in 100 ... 109 {
            #expect(store.submit(makeRecord(score: score)))
        }

        #expect(!store.submit(makeRecord(score: 1)))
        #expect(store.scores.map(\.score) == Array((100 ... 109).reversed()))
    }

    private func makeRecord(
        id: UUID = UUID(),
        score: Int,
        stationsEaten: Int = 1,
        maxCombo: Int = 1,
        elapsedTime: TimeInterval = 42,
        playedAt: TimeInterval = 100,
        endReason: TubeGameScoreEndReason = .collision
    ) -> TubeGameScoreRecord {
        TubeGameScoreRecord(
            id: id,
            score: score,
            stationsEaten: stationsEaten,
            maxCombo: maxCombo,
            configuredDuration: 60,
            elapsedTime: elapsedTime,
            endReason: endReason,
            playedAt: Date(timeIntervalSince1970: playedAt),
            runSeed: 123,
            graphGeneratedAt: "2026-08-23T20:26:26.921154+00:00"
        )
    }
}

private struct TestArchive: Codable {
    let version: Int
    let scores: [TubeGameScoreRecord]
}

private struct LegacyScoreArchive: Encodable {
    let version: Int
    let scores: [LegacyScoreRecord]
}

private struct LegacyScoreRecord: Encodable {
    let id: UUID
    let score: Int
    let stationsEaten: Int
    let maxCombo: Int
    let configuredDuration: TimeInterval
    let elapsedTime: TimeInterval
    let endReason: TubeGameScoreEndReason
    let playedAt: Date
    let runSeed: UInt64
    let graphGeneratedAt: String
    let rulesVersion: Int
}

private struct TestDefaults {
    static let storageKey = "TubeTrackUK.StationChase.highScores"

    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "TubeGameHighScoreStoreTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
