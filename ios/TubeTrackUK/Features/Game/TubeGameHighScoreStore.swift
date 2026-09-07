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
    let linesCleared: Int
    let terminusStationsReached: Int
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
        linesCleared: Int = 0,
        terminusStationsReached: Int = 0,
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
        self.linesCleared = linesCleared
        self.terminusStationsReached = terminusStationsReached
        self.maxCombo = maxCombo
        self.configuredDuration = configuredDuration
        self.elapsedTime = elapsedTime
        self.endReason = endReason
        self.playedAt = playedAt
        self.runSeed = runSeed
        self.graphGeneratedAt = graphGeneratedAt
        self.rulesVersion = rulesVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case score
        case stationsEaten
        case linesCleared
        case terminusStationsReached
        case maxCombo
        case configuredDuration
        case elapsedTime
        case endReason
        case playedAt
        case runSeed
        case graphGeneratedAt
        case rulesVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        score = try container.decode(Int.self, forKey: .score)
        stationsEaten = try container.decode(Int.self, forKey: .stationsEaten)
        linesCleared = try container.decodeIfPresent(Int.self, forKey: .linesCleared) ?? 0
        terminusStationsReached = try container.decodeIfPresent(
            Int.self,
            forKey: .terminusStationsReached
        ) ?? 0
        maxCombo = try container.decode(Int.self, forKey: .maxCombo)
        configuredDuration = try container.decode(TimeInterval.self, forKey: .configuredDuration)
        elapsedTime = try container.decode(TimeInterval.self, forKey: .elapsedTime)
        endReason = try container.decode(TubeGameScoreEndReason.self, forKey: .endReason)
        playedAt = try container.decode(Date.self, forKey: .playedAt)
        runSeed = try container.decode(UInt64.self, forKey: .runSeed)
        graphGeneratedAt = try container.decode(String.self, forKey: .graphGeneratedAt)
        rulesVersion = try container.decode(Int.self, forKey: .rulesVersion)
    }

    var shareText: String {
        let stationDescription = stationsEaten == 1 ? "1 station" : "\(stationsEaten) stations"
        let terminusDescription = terminusStationsReached == 1
            ? "1 terminus"
            : "\(terminusStationsReached) termini"
        return "I scored \(score) points in Track Attack on TubeTrack UK, eating \(stationDescription) and reaching \(terminusDescription), with a best combo of \(maxCombo). Can you beat my score?"
    }

    fileprivate var isValid: Bool {
        score >= 0
            && stationsEaten >= 0
            && linesCleared >= 0
            && terminusStationsReached >= 0
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

    private static let currentStorageVersion = 2
    // Keep the legacy key so existing players retain their scores after the rename.
    private static let defaultStorageKey = "TubeTrackUK.StationChase.highScores"

    private(set) var scores: [TubeGameScoreRecord]
    private(set) var latestAchievements: [TubeGameAchievement] = []
    @ObservationIgnored private var personalBests: TubeGamePersonalBests

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
        let loadedScores = Self.loadScores(from: defaults, storageKey: storageKey)
        scores = loadedScores
        if let data = defaults.data(forKey: storageKey + ".personalBests.v1"),
           let saved = try? JSONDecoder().decode(TubeGamePersonalBests.self, from: data) {
            personalBests = saved
        } else {
            var migrated = TubeGamePersonalBests()
            for record in loadedScores.sorted(by: { $0.playedAt < $1.playedAt }) {
                _ = migrated.record(record)
            }
            personalBests = migrated
        }
    }

    /// Adds an eligible finished run to the local leaderboard. Manual quits are never recorded.
    @discardableResult
    func submit(_ record: TubeGameScoreRecord) -> Bool {
        latestAchievements = []
        guard record.endReason.isHighScoreEligible,
              record.isValid,
              record.rulesVersion == Self.currentRulesVersion else {
            return false
        }

        latestAchievements = personalBests.record(record)
        if let data = try? JSONEncoder().encode(personalBests) {
            defaults.set(data, forKey: storageKey + ".personalBests.v1")
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
              (1 ... currentStorageVersion).contains(archive.version) else {
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
        if lhs.linesCleared != rhs.linesCleared {
            return lhs.linesCleared > rhs.linesCleared
        }
        if lhs.terminusStationsReached != rhs.terminusStationsReached {
            return lhs.terminusStationsReached > rhs.terminusStationsReached
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
