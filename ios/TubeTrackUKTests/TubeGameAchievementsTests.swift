import Foundation
import SwiftUI
import Testing
@testable import TubeTrackUK

struct TubeGameAchievementsTests {
    private func record(score: Int = 100, stations: Int = 5, lines: Int = 0, termini: Int = 0, combo: Int = 3, elapsed: TimeInterval = 42, day: Int = 0) -> TubeGameScoreRecord {
        .init(score: score, stationsEaten: stations, linesCleared: lines, terminusStationsReached: termini, maxCombo: combo, configuredDuration: 60, elapsedTime: elapsed, endReason: .collision, playedAt: Date(timeIntervalSince1970: 1_780_315_200 + Double(day) * 86_400), runSeed: 1, graphGeneratedAt: "test")
    }

    @Test func tiesAndZeroMetricsDoNotCelebrate() {
        var bests = TubeGamePersonalBests()
        #expect(bests.record(record()).map(\.category) == ["score", "stations", "combo", "time survived"])
        #expect(bests.record(record()).isEmpty)
        #expect(bests.record(record(score: 0, stations: 0, combo: 0)).isEmpty)
    }

    @Test func timeSurvivedUsesOnlyCompletedSeconds() {
        var bests = TubeGamePersonalBests()
        let first = bests.record(record(score: 0, stations: 0, combo: 0, elapsed: 42.9))
        #expect(first == [.init(category: "time survived", period: "personal", value: 42)])
        #expect(first.first?.formattedValue == "42s")
        #expect(bests.record(record(score: 0, stations: 0, combo: 0, elapsed: 42.99)).isEmpty)
        #expect(bests.record(record(score: 0, stations: 0, combo: 0, elapsed: 43.1)).map(\.category) == ["time survived"])
    }

    @Test func dailyAndWeeklyRecordsResetWithoutLosingAllTimeRecords() {
        var bests = TubeGamePersonalBests()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        _ = bests.record(record(score: 900), calendar: calendar)
        let daily = bests.record(record(score: 100, day: 1), calendar: calendar)
        #expect(daily.contains { $0.category == "score" && $0.period == "daily personal" })
        let weekly = bests.record(record(score: 200, day: 8), calendar: calendar)
        #expect(weekly.contains { $0.category == "score" && $0.period == "weekly personal" })
        #expect(bests.allTime["score"] == 900)
        let otherCategories = bests.record(record(score: 50, lines: 1, termini: 2, day: 8), calendar: calendar)
        #expect(otherCategories.map(\.category) == ["lines cleared", "termini"])
    }

    @Test @MainActor func categoryRecordsOutsideTopTenPersistAndQuitDoesNotCelebrate() throws {
        let name = "Achievements.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TubeGameHighScoreStore(defaults: defaults)
        for score in 100...110 { store.submit(record(score: score)) }
        #expect(!store.submit(record(score: 1, stations: 50)))
        #expect(store.latestAchievements.map(\.category) == ["stations"])
        let restored = TubeGameHighScoreStore(defaults: defaults)
        restored.submit(record(score: 2, stations: 49))
        #expect(restored.latestAchievements.isEmpty)
        let quit = TubeGameScoreRecord(score: 1000, stationsEaten: 100, maxCombo: 100, configuredDuration: 60, elapsedTime: 20, endReason: .manualQuit, runSeed: 1, graphGeneratedAt: "test")
        #expect(!restored.submit(quit))
        #expect(restored.latestAchievements.isEmpty)
    }

    @Test @MainActor func scoreCardExportsOpaqueHighResolutionPNG() throws {
        let card = TubeGameScoreCard(record: record(score: 576, stations: 29, lines: 1, termini: 2, combo: 8), achievements: [.init(category: "score", period: "daily personal", value: 576)])
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.isOpaque = true
        let image = try #require(renderer.uiImage)
        #expect(image.cgImage?.width == 1440)
        let png = try #require(image.pngData())
        #expect(png.count > 10_000)
        // Keep a rendered artifact for visual inspection in the simulator container.
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Track-Man-score-preview.png")
        try png.write(to: url)
    }
}
