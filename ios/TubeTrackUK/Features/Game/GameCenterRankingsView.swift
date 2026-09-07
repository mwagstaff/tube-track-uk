import GameKit
import SwiftUI

private enum GameCenterRankingPeriod: String, CaseIterable, Identifiable {
    case today
    case week
    case allTime

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "This Week"
        case .allTime: "All Time"
        }
    }

    var timeScope: GKLeaderboard.TimeScope {
        switch self {
        case .today: .today
        case .week: .week
        case .allTime: .allTime
        }
    }
}

private struct GameCenterRankingRow: Identifiable, Equatable {
    let id: String
    let rank: Int
    let playerName: String
    let formattedScore: String
    let isLocalPlayer: Bool

    init(_ entry: GKLeaderboard.Entry) {
        id = "\(entry.rank)-\(entry.player.gamePlayerID)"
        rank = entry.rank
        playerName = entry.player.displayName
        formattedScore = entry.formattedScore
        isLocalPlayer = entry.player.gamePlayerID == GKLocalPlayer.local.gamePlayerID
    }
}

struct GameCenterRankingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var leaderboard: GameCenterLeaderboard
    @State private var period: GameCenterRankingPeriod = .allTime
    @State private var entries: [GameCenterRankingRow] = []
    @State private var localPlayerEntry: GameCenterRankingRow?
    @State private var totalPlayerCount = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(initialLeaderboard: GameCenterLeaderboard) {
        _leaderboard = State(initialValue: initialLeaderboard)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls

                Group {
                    if isLoading {
                        ProgressView("Loading rankings…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage {
                        ContentUnavailableView {
                            Label("Rankings unavailable", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Try Again") {
                                reloadToken += 1
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if entries.isEmpty {
                        ContentUnavailableView(
                            "No scores yet",
                            systemImage: "trophy",
                            description: Text("Be the first player on this leaderboard.")
                        )
                    } else {
                        rankingsList
                    }
                }
            }
            .navigationTitle("Game Center Rankings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: loadID) {
            await loadRankings()
        }
    }

    @State private var reloadToken = 0

    private var loadID: String {
        "\(leaderboard.id)-\(period.rawValue)-\(reloadToken)"
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Leaderboard", selection: $leaderboard) {
                ForEach(GameCenterLeaderboard.allCases) { leaderboard in
                    Text(leaderboard.title).tag(leaderboard)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Time period", selection: $period) {
                ForEach(GameCenterRankingPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .background(.bar)
    }

    private var rankingsList: some View {
        List {
            if let localPlayerEntry, !entries.contains(where: \.isLocalPlayer) {
                Section("Your Position") {
                    rankingRow(localPlayerEntry)
                }
            }

            Section {
                ForEach(entries) { entry in
                    rankingRow(entry)
                }
            } header: {
                Text(totalPlayerCount == 1 ? "1 Player" : "\(totalPlayerCount) Players")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadRankings()
        }
    }

    private func rankingRow(_ entry: GameCenterRankingRow) -> some View {
        HStack(spacing: 12) {
            Text("\(entry.rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Text(entry.playerName)
                .font(entry.isLocalPlayer ? .headline : .body)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text(entry.formattedScore)
                .font(.headline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .listRowBackground(entry.isLocalPlayer ? Color.yellow.opacity(0.18) : nil)
    }

    @MainActor
    private func loadRankings() async {
        isLoading = true
        errorMessage = nil

        do {
            let leaderboards = try await GKLeaderboard.loadLeaderboards(IDs: [leaderboard.id])
            guard let loadedLeaderboard = leaderboards.first else {
                throw GameCenterRankingsError.leaderboardUnavailable
            }

            let (localEntry, leaderboardEntries, playerCount) = try await loadedLeaderboard.loadEntries(
                for: .global,
                timeScope: period.timeScope,
                range: NSRange(location: 1, length: 100)
            )

            guard !Task.isCancelled else { return }
            localPlayerEntry = localEntry.map(GameCenterRankingRow.init)
            entries = leaderboardEntries.map(GameCenterRankingRow.init)
            totalPlayerCount = playerCount
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            entries = []
            localPlayerEntry = nil
            totalPlayerCount = 0
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

private enum GameCenterRankingsError: LocalizedError {
    case leaderboardUnavailable

    var errorDescription: String? {
        "Game Center could not find this leaderboard. Please try again shortly."
    }
}
