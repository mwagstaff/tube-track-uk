import Foundation
import Observation

private enum TubeGameScoreFormat {
    static let currentRulesVersion = 1
}

enum TubeGameScoreEndReason: String, Codable, Equatable, Sendable {
    case completed
    case collision
    case networkCleared
    case manualQuit

    fileprivate var isHighScoreEligible: Bool {
        switch self {
        case .completed, .collision, .networkCleared:
            true
        case .manualQuit:
            false
        }
    }
}

struct TubeGameScoreRecord: Codable, Identifiable, Equatable, Sendable {
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

    init(
        id: UUID = UUID(),
        score: Int,
        stationsEaten: Int,
        maxCombo: Int,
        configuredDuration: TimeInterval,
        elapsedTime: TimeInterval,
        endReason: TubeGameScoreEndReason,
        playedAt: Date = Date(),
        runSeed: UInt64,
        graphGeneratedAt: String,
        rulesVersion: Int = TubeGameScoreFormat.currentRulesVersion
    ) {
        self.id = id
        self.score = score
        self.stationsEaten = stationsEaten
        self.maxCombo = maxCombo
        self.configuredDuration = configuredDuration
        self.elapsedTime = elapsedTime
        self.endReason = endReason
        self.playedAt = playedAt
        self.runSeed = runSeed
        self.graphGeneratedAt = graphGeneratedAt
        self.rulesVersion = rulesVersion
    }

    var shareText: String {
        let stationDescription = stationsEaten == 1 ? "1 station" : "\(stationsEaten) stations"
        return "I scored \(score) points in Station Chase on TubeTrack UK, eating \(stationDescription) with a best combo of \(maxCombo). Can you beat my score?"
    }

    fileprivate var isValid: Bool {
        score >= 0
            && stationsEaten >= 0
            && maxCombo >= 0
            && configuredDuration.isFinite
            && configuredDuration > 0
            && elapsedTime.isFinite
            && elapsedTime >= 0
            && !graphGeneratedAt.isEmpty
            && rulesVersion > 0
    }
}

@MainActor
@Observable
final class TubeGameHighScoreStore {
    static let currentRulesVersion = TubeGameScoreFormat.currentRulesVersion
    static let maximumScoreCount = 10

    private static let currentStorageVersion = 1
    private static let defaultStorageKey = "TubeTrackUK.StationChase.highScores"

    private(set) var scores: [TubeGameScoreRecord]

    var bestScore: Int {
        scores.first?.score ?? 0
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = TubeGameHighScoreStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        scores = Self.loadScores(from: defaults, storageKey: storageKey)
    }

    /// Adds an eligible finished run to the local leaderboard. Manual quits are never recorded.
    @discardableResult
    func submit(_ record: TubeGameScoreRecord) -> Bool {
        guard record.endReason.isHighScoreEligible,
              record.isValid,
              record.rulesVersion == Self.currentRulesVersion else {
            return false
        }

        scores.removeAll { $0.id == record.id }
        scores.append(record)
        scores = Self.rankedTopTen(scores)
        persist()
        return scores.contains { $0.id == record.id }
    }

    func shareText(for record: TubeGameScoreRecord) -> String {
        record.shareText
    }

    private func persist() {
        let archive = ScoreArchive(version: Self.currentStorageVersion, scores: scores)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func loadScores(
        from defaults: UserDefaults,
        storageKey: String
    ) -> [TubeGameScoreRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let archive = try? JSONDecoder().decode(ScoreArchive.self, from: data),
              archive.version == currentStorageVersion else {
            return []
        }

        return rankedTopTen(
            archive.scores.filter {
                $0.endReason.isHighScoreEligible
                    && $0.isValid
                    && $0.rulesVersion == currentRulesVersion
            }
        )
    }

    private static func rankedTopTen(
        _ records: [TubeGameScoreRecord]
    ) -> [TubeGameScoreRecord] {
        let ranked = records.sorted(by: ranksBefore)
        var seenIDs = Set<UUID>()
        var result: [TubeGameScoreRecord] = []
        result.reserveCapacity(min(maximumScoreCount, ranked.count))

        for record in ranked where seenIDs.insert(record.id).inserted {
            result.append(record)
            if result.count == maximumScoreCount {
                break
            }
        }

        return result
    }

    private static func ranksBefore(
        _ lhs: TubeGameScoreRecord,
        _ rhs: TubeGameScoreRecord
    ) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.stationsEaten != rhs.stationsEaten {
            return lhs.stationsEaten > rhs.stationsEaten
        }
        if lhs.maxCombo != rhs.maxCombo {
            return lhs.maxCombo > rhs.maxCombo
        }
        if lhs.playedAt != rhs.playedAt {
            return lhs.playedAt < rhs.playedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct ScoreArchive: Codable {
    let version: Int
    let scores: [TubeGameScoreRecord]
}
