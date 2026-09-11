import GameKit
import Observation
import UIKit

enum GameCenterLeaderboard: String, CaseIterable, Identifiable, Sendable {
    case score
    case stationsEaten
    case linesCleared
    case terminusStationsReached
    case timeSurvived

    var id: String {
        switch self {
        case .score:
            "stationchase.score.v1"
        case .stationsEaten:
            "stationchase.stations.v1"
        case .linesCleared:
            "stationchase.lines.v1"
        case .terminusStationsReached:
            "stationchase.termini.v1"
        case .timeSurvived:
            "stationchase.time.v1"
        }
    }

    var title: String {
        switch self {
        case .score: "High Score"
        case .stationsEaten: "Stations Eaten"
        case .linesCleared: "Lines Cleared"
        case .terminusStationsReached: "Terminus Stations Reached"
        case .timeSurvived: "Time Survived"
        }
    }
}

enum GameCenterAuthenticationState: Equatable {
    case notStarted
    case authenticating
    case authenticated(displayName: String)
    case unavailable
}

enum GameCenterSubmissionState: Equatable {
    case idle
    case queued(recordID: UUID)
    case submitting(recordID: UUID)
    case submitted(recordID: UUID)
    case failed(recordID: UUID)

    var recordID: UUID? {
        switch self {
        case .idle: nil
        case let .queued(id), let .submitting(id), let .submitted(id), let .failed(id): id
        }
    }
}

@MainActor
@Observable
final class GameCenterService {
    private(set) var authenticationState: GameCenterAuthenticationState = .notStarted
    private(set) var submissionState: GameCenterSubmissionState = .idle
    private(set) var availableLeaderboardIDs: Set<String> = []
    private(set) var isOffline = false
    private(set) var pendingScoreRecords: [TubeGameScoreRecord]

    @ObservationIgnored private var hasStartedAuthentication = false
    @ObservationIgnored private var hasRequestedAuthentication = false
    @ObservationIgnored private var synchronizationTask: Task<Void, Never>?
    @ObservationIgnored private var synchronizationRequested = false
    @ObservationIgnored private var synchronizeAfterCurrentSubmissions = false
    @ObservationIgnored private var submittingRecordIDs: Set<UUID> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "TubeTrackUK.StationChase.pendingGameCenterScores.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        pendingScoreRecords = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([TubeGameScoreRecord].self, from: $0) } ?? []
    }

    var isAuthenticated: Bool {
        GKLocalPlayer.local.isAuthenticated
    }

    var rankingsAvailable: Bool {
        !isOffline && isAuthenticated && Self.requiredLeaderboardIDs.isSubset(of: availableLeaderboardIDs)
    }

    func setOffline(_ offline: Bool) {
        guard offline != isOffline else { return }
        isOffline = offline
        synchronizationTask?.cancel()
        if offline {
            if !isAuthenticated {
                hasStartedAuthentication = false
            }
            if case let .submitting(recordID) = submissionState {
                submissionState = .queued(recordID: recordID)
            }
        } else if hasRequestedAuthentication {
            authenticate()
        }
    }

    func authenticate() {
        hasRequestedAuthentication = true
        guard !isOffline else { return }
        if hasStartedAuthentication {
            guard isAuthenticated else { return }
            requestSynchronization()
            return
        }
        hasStartedAuthentication = true
        authenticationState = .authenticating

        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isOffline else { return }

                if let viewController {
                    self.authenticationState = .authenticating
                    self.presentAuthentication(viewController)
                    return
                }

                if GKLocalPlayer.local.isAuthenticated {
                    self.requestSynchronization()
                } else {
                    _ = error
                    self.availableLeaderboardIDs = []
                    self.authenticationState = .unavailable
                }
            }
        }
    }

    @discardableResult
    func submit(_ record: TubeGameScoreRecord) async -> [TubeGameAchievement] {
        guard record.endReason != .manualQuit else { return [] }
        if !pendingScoreRecords.contains(where: { $0.id == record.id }) {
            pendingScoreRecords.append(record)
            persistPendingScores()
        }
        submissionState = .queued(recordID: record.id)
        guard !isOffline else { return [] }
        return await submitPendingRecord(record, includeAchievements: true)
    }

    private func submitPendingRecord(
        _ record: TubeGameScoreRecord,
        includeAchievements: Bool
    ) async -> [TubeGameAchievement] {
        guard !isOffline, !Task.isCancelled,
              submittingRecordIDs.insert(record.id).inserted else { return [] }
        defer {
            submittingRecordIDs.remove(record.id)
            if synchronizeAfterCurrentSubmissions, submittingRecordIDs.isEmpty {
                synchronizeAfterCurrentSubmissions = false
                if !pendingScoreRecords.isEmpty {
                    requestSynchronization()
                }
            }
        }
        guard rankingsAvailable else {
            if submissionState.recordID == record.id {
                submissionState = .failed(recordID: record.id)
            }
            return []
        }
        if submissionState.recordID == record.id {
            submissionState = .submitting(recordID: record.id)
        }

        // Read before submitting: after submission the new score is already the
        // baseline, which would hide precisely the record we want to celebrate.
        let achievements = includeAchievements ? await personalBestsBeaten(by: record) : []
        do {
            let scores: [(GameCenterLeaderboard, Int)] = [
                (.score, record.score), (.stationsEaten, record.stationsEaten),
                (.linesCleared, record.linesCleared),
                (.terminusStationsReached, record.terminusStationsReached),
                (.timeSurvived, record.timeSurvivedSeconds),
            ]
            for (leaderboard, score) in scores {
                try Task.checkCancellation()
                guard !isOffline else { throw CancellationError() }
                try await GKLeaderboard.submitScore(
                    score,
                    context: record.rulesVersion,
                    player: GKLocalPlayer.local,
                    leaderboardIDs: [leaderboard.id]
                )
            }
            pendingScoreRecords.removeAll { $0.id == record.id }
            persistPendingScores()
            if submissionState.recordID == record.id {
                submissionState = .submitted(recordID: record.id)
            }
            return achievements
        } catch {
            if submissionState.recordID == record.id {
                submissionState = isOffline || Task.isCancelled
                    ? .queued(recordID: record.id)
                    : .failed(recordID: record.id)
            }
            return []
        }
    }

    private func personalBestsBeaten(by record: TubeGameScoreRecord) async -> [TubeGameAchievement] {
        guard let boards = try? await GKLeaderboard.loadLeaderboards(IDs: GameCenterLeaderboard.allCases.map(\.id)) else {
            return [] // An unavailable baseline must never be treated as zero.
        }
        var achievements: [TubeGameAchievement] = []
        for category in GameCenterLeaderboard.allCases {
            guard let board = boards.first(where: { $0.baseLeaderboardID == category.id }) else { continue }
            let periods: [(GKLeaderboard.TimeScope, String)] = [
                (.allTime, "personal"), (.week, "weekly personal"), (.today, "daily personal"),
            ]
            for (scope, period) in periods {
                guard !Task.isCancelled, !isOffline else { return [] }
                do {
                    let (localEntry, _, _) = try await board.loadEntries(
                        for: .global, timeScope: scope, range: NSRange(location: 1, length: 1)
                    )
                    if let achievement = Self.personalBest(
                        record: record, category: category, previousScore: localEntry?.score, period: period
                    ) {
                        achievements.append(achievement)
                        break // Keep the strongest period per category; share cards stay concise.
                    }
                } catch { continue }
            }
        }
        return achievements
    }

    static func personalBest(
        record: TubeGameScoreRecord, category: GameCenterLeaderboard,
        previousScore: Int?, period: String
    ) -> TubeGameAchievement? {
        let metric: (String, Int)
        switch category {
        case .score: metric = ("score", record.score)
        case .stationsEaten: metric = ("stations", record.stationsEaten)
        case .linesCleared: metric = ("lines cleared", record.linesCleared)
        case .terminusStationsReached: metric = ("termini", record.terminusStationsReached)
        case .timeSurvived: metric = ("time survived", record.timeSurvivedSeconds)
        }
        guard record.endReason != .manualQuit, metric.1 > max(0, previousScore ?? 0) else { return nil }
        return .init(category: metric.0, period: period, value: metric.1, isGameCenter: true)
    }

    func show(_ leaderboard: GameCenterLeaderboard) {
        guard rankingsAvailable else { return }
        GKAccessPoint.shared.trigger(
            leaderboardID: leaderboard.id,
            playerScope: .global,
            timeScope: .allTime,
            handler: nil
        )
    }

    private func validateConfiguration() async {
        guard !isOffline, !Task.isCancelled else { return }
        do {
            let leaderboards = try await GKLeaderboard.loadLeaderboards(
                IDs: GameCenterLeaderboard.allCases.map(\.id)
            )
            guard !isOffline, !Task.isCancelled else { return }
            availableLeaderboardIDs = Set(leaderboards.map(\.baseLeaderboardID))

            if rankingsAvailable {
                authenticationState = .authenticated(
                    displayName: GKLocalPlayer.local.displayName
                )
                // Local records survive app termination, including runs that did
                // not make the local top ten. Retry only after Game Center is ready.
                for record in pendingScoreRecords {
                    guard !isOffline, !Task.isCancelled else { return }
                    if submittingRecordIDs.contains(record.id) {
                        // A score submitted by the results screen may still be
                        // finishing its pre-disconnection GameKit request.
                        synchronizeAfterCurrentSubmissions = true
                        continue
                    }
                    _ = await submitPendingRecord(record, includeAchievements: false)
                    if pendingScoreRecords.contains(where: { $0.id == record.id }) {
                        break // Avoid repeating requests while Game Center is unavailable.
                    }
                }
            } else {
                authenticationState = .unavailable
            }
        } catch {
            guard !isOffline, !Task.isCancelled else { return }
            availableLeaderboardIDs = []
            authenticationState = .unavailable
        }
    }

    private func requestSynchronization() {
        synchronizationRequested = true
        guard !isOffline, synchronizationTask == nil else { return }
        synchronizationRequested = false
        synchronizationTask = Task { [weak self] in
            await self?.validateConfiguration()
            guard let self else { return }
            self.synchronizationTask = nil
            if self.synchronizationRequested, !self.isOffline {
                // Keep the cancelled task until it actually finishes, so rapid
                // disconnect/reconnect transitions cannot orphan its successor.
                self.requestSynchronization()
            }
        }
    }

    private func persistPendingScores() {
        guard let data = try? JSONEncoder().encode(pendingScoreRecords) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static let requiredLeaderboardIDs = Set(
        GameCenterLeaderboard.allCases.map(\.id)
    )

    private func presentAuthentication(_ viewController: UIViewController) {
        guard let presenter = Self.topViewController() else {
            authenticationState = .unavailable
            return
        }
        presenter.present(viewController, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController

        return topViewController(from: root)
    }

    private static func topViewController(from viewController: UIViewController?) -> UIViewController? {
        if let presented = viewController?.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = viewController as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tabs = viewController as? UITabBarController {
            return topViewController(from: tabs.selectedViewController)
        }
        return viewController
    }
}
