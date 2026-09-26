import Foundation
import Testing
@testable import TubeTrackUK

struct CardUpdateFooterTests {
    @Test func sourceAgeUsesLondonTimeAndNeverCallsOldDataJustNow() {
        let now = ISO8601DateFormatter().date(from: "2026-09-25T10:01:30Z")!
        let fresh = CardUpdateText.resolve(updatedAt: now.addingTimeInterval(-10), now: now, offline: false, stale: false, staleAfter: 120)
        #expect(fresh.text == "Last updated just now, at 11:01")
        #expect(fresh.warning == nil)
        let old = CardUpdateText.resolve(updatedAt: now.addingTimeInterval(-121), now: now, offline: false, stale: false, staleAfter: 120)
        #expect(old.text == "Last updated 2 minutes ago, at 10:59")
        #expect(old.warning != nil)
        let flagged = CardUpdateText.resolve(updatedAt: now, now: now, offline: false, stale: true, staleAfter: 120)
        #expect(flagged.warning != nil && flagged.symbol == "exclamationmark.icloud")
        let offline = CardUpdateText.resolve(updatedAt: now, now: now, offline: true, stale: false, staleAfter: 120)
        #expect(offline.symbol == "wifi.slash" && offline.warning!.contains("Offline"))
        let missing = CardUpdateText.resolve(updatedAt: nil, now: now, offline: true, stale: false, staleAfter: 120)
        #expect(missing.text == "Waiting for the first update" && missing.warning != nil)
    }
}
