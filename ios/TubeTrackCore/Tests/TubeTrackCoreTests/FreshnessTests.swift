import Foundation
import Testing
@testable import TubeTrackCore

struct FreshnessTests {
    private let updatedAt = ISO8601DateFormatter().date(from: "2026-09-25T19:27:00Z")!

    private func freshness(afterSeconds seconds: TimeInterval, isCached: Bool = false) -> Freshness {
        Freshness.evaluate(
            updatedAt: updatedAt,
            now: updatedAt.addingTimeInterval(seconds),
            isCached: isCached
        )
    }

    @Test func tiersFollowTheAgeOfTheSnapshot() {
        #expect(freshness(afterSeconds: 0).tier == .fresh)
        #expect(freshness(afterSeconds: 119).tier == .fresh)
        #expect(freshness(afterSeconds: 120).tier == .ageing)
        #expect(freshness(afterSeconds: 359).tier == .ageing)
        #expect(freshness(afterSeconds: 360).tier == .stale)
        #expect(Freshness.evaluate(updatedAt: nil, now: updatedAt).tier == .unavailable)
    }

    @Test func countdownsAreWithdrawnOnceTheSnapshotIsStale() {
        #expect(freshness(afterSeconds: 60).showsCountdowns)
        #expect(freshness(afterSeconds: 300).showsCountdowns)
        #expect(!freshness(afterSeconds: 600).showsCountdowns)
        #expect(!Freshness.evaluate(updatedAt: nil, now: updatedAt).showsCountdowns)
    }

    @Test func summaryTellsThePassengerHowOldTheDataIs() {
        let now = updatedAt.addingTimeInterval(240)
        #expect(freshness(afterSeconds: 10).summary(at: updatedAt.addingTimeInterval(10)) == "Updated at 20:27, just now")
        #expect(freshness(afterSeconds: 120).summary(at: updatedAt.addingTimeInterval(120)) == "Updated at 20:27, 2 minutes ago")
        #expect(freshness(afterSeconds: 240).summary(at: now) == "Updated at 20:27, 4 minutes ago")
        #expect(freshness(afterSeconds: 240, isCached: true).summary(at: now) == "Updated at 20:27, 4 minutes ago")
        #expect(freshness(afterSeconds: 900).summary(at: updatedAt.addingTimeInterval(900)) == "Updated at 20:27, 15 minutes ago")
        #expect(Freshness.evaluate(updatedAt: nil, now: now).summary(at: now) == "No live data")
    }

    @Test func aSnapshotFromTheFutureIsNotTreatedAsAncient() {
        // Server clock slightly ahead of the device must not read as stale.
        let ahead = Freshness.evaluate(updatedAt: updatedAt, now: updatedAt.addingTimeInterval(-30))
        #expect(ahead.tier == .fresh)
        #expect(ahead.summary(at: updatedAt.addingTimeInterval(-30)) == "Updated at 20:27, just now")
    }

    @Test func cachedDataIsAlwaysDegradedEvenWhenRecent() {
        #expect(!freshness(afterSeconds: 10).isDegraded)
        #expect(freshness(afterSeconds: 10, isCached: true).isDegraded)
        #expect(freshness(afterSeconds: 200).isDegraded)
    }
}
