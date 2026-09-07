import GameKit
import Observation
import UIKit

enum GameCenterLeaderboard: String, CaseIterable, Identifiable, Sendable {
    case score
    case stationsEaten
    case linesCleared
    case terminusStationsReached

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
        }
    }

    var title: String {
        switch self {
        case .score: "High Score"
        case .stationsEaten: "Stations Eaten"
        case .linesCleared: "Lines Cleared"
        case .terminusStationsReached: "Terminus Stations Reached"
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
    case submitting(recordID: UUID)
    case submitted(recordID: UUID)
    case failed(recordID: UUID)
}

@MainActor
@Observable
final class GameCenterService {
    private(set) var authenticationState: GameCenterAuthenticationState = .notStarted
    private(set) var submissionState: GameCenterSubmissionState = .idle
    private(set) var availableLeaderboardIDs: Set<String> = []

    @ObservationIgnored private var hasStartedAuthentication = false

    var isAuthenticated: Bool {
        GKLocalPlayer.local.isAuthenticated
    }

    var rankingsAvailable: Bool {
        isAuthenticated && Self.requiredLeaderboardIDs.isSubset(of: availableLeaderboardIDs)
    }

    func authenticate() {
        guard !hasStartedAuthentication else { return }
        hasStartedAuthentication = true
        authenticationState = .authenticating

        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let viewController {
                    self.authenticationState = .authenticating
                    self.presentAuthentication(viewController)
                    return
                }

                if GKLocalPlayer.local.isAuthenticated {
                    await self.validateConfiguration()
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
        guard rankingsAvailable else {
            submissionState = .failed(recordID: record.id)
            return []
        }
        submissionState = .submitting(recordID: record.id)

        // Read before submitting: after submission the new score is already the
        // baseline, which would hide precisely the record we want to celebrate.
        let achievements = await personalBestsBeaten(by: record)
        guard !Task.isCancelled else { return [] }
        do {
            try await GKLeaderboard.submitScore(
                record.score,
                context: record.rulesVersion,
                player: GKLocalPlayer.local,
                leaderboardIDs: [GameCenterLeaderboard.score.id]
            )
            try await GKLeaderboard.submitScore(
                record.stationsEaten,
                context: record.rulesVersion,
                player: GKLocalPlayer.local,
                leaderboardIDs: [GameCenterLeaderboard.stationsEaten.id]
            )
            try await GKLeaderboard.submitScore(
                record.linesCleared,
                context: record.rulesVersion,
                player: GKLocalPlayer.local,
                leaderboardIDs: [GameCenterLeaderboard.linesCleared.id]
            )
            try await GKLeaderboard.submitScore(
                record.terminusStationsReached,
                context: record.rulesVersion,
                player: GKLocalPlayer.local,
                leaderboardIDs: [GameCenterLeaderboard.terminusStationsReached.id]
            )
            if submissionState == .submitting(recordID: record.id) {
                submissionState = .submitted(recordID: record.id)
            }
            return achievements
        } catch {
            if submissionState == .submitting(recordID: record.id) {
                submissionState = .failed(recordID: record.id)
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
                guard !Task.isCancelled else { return [] }
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
        do {
            let leaderboards = try await GKLeaderboard.loadLeaderboards(
                IDs: GameCenterLeaderboard.allCases.map(\.id)
            )
            availableLeaderboardIDs = Set(leaderboards.map(\.baseLeaderboardID))

            if rankingsAvailable {
                authenticationState = .authenticated(
                    displayName: GKLocalPlayer.local.displayName
                )
            } else {
                authenticationState = .unavailable
            }
        } catch {
            availableLeaderboardIDs = []
            authenticationState = .unavailable
        }
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
