import Foundation

/// The rules that keep a tracked departure board honest and finite.
///
/// A Live Activity cannot fetch anything itself — it renders whatever state it
/// was last handed. So the only two things standing between a passenger and a
/// confidently-wrong Lock Screen are `staleDate` (iOS visibly dims the activity
/// past it) and knowing when to end. Both live here, pure and testable.
public enum DepartureActivityPolicy {
    /// A tracked board expires on its own. Long enough for a delayed commute,
    /// short enough that a forgotten activity isn't still there at bedtime.
    public static let maximumDuration: TimeInterval = 90 * 60

    /// How long an *app-driven* update stays presentable.
    ///
    /// The app refreshes arrivals every few tens of seconds and those updates
    /// cost no budget at all, so while the app is feeding the activity we can
    /// promise data this fresh. Once the app goes away the server takes over
    /// and sets a wider window on each push — see `pushStaleWindow`.
    public static let staleWindow: TimeInterval = 3 * 60

    /// Without frequent updates the server pushes far less often, so the
    /// activity has to tolerate longer gaps before dimming.
    public static let relaxedStaleWindow: TimeInterval = 7 * 60

    /// Priority-5 snapshots refresh exact minute labels without consuming the
    /// APNs high-priority budget. Stale dates allow for delayed delivery.
    public static let pushStaleWindow: TimeInterval = 3 * 60
    public static let relaxedPushStaleWindow: TimeInterval = 7 * 60
    public static let heartbeat: TimeInterval = 30
    public static let relaxedHeartbeat: TimeInterval = 60

    /// Give up when nothing has arrived for this long — a frozen board is
    /// worse than none.
    public static let silenceBeforeAbandoning: TimeInterval = 20 * 60

    /// An empty board is only final once it has stayed empty; mid-fetch blips
    /// must not end a perfectly good activity.
    public static let emptyBoardGrace: TimeInterval = 3 * 60

    public static func staleDate(
        updatedAt: Date,
        frequentPushesEnabled: Bool,
        hardEndsAt: Date
    ) -> Date {
        let window = frequentPushesEnabled ? staleWindow : relaxedStaleWindow
        return min(updatedAt.addingTimeInterval(window), hardEndsAt)
    }

    /// Ranks competing activities on the Lock Screen: the sooner the next
    /// train, the more the passenger wants to see it.
    public static func relevanceScore(state: DepartureActivityAttributes.ContentState, now: Date) -> Double {
        guard let next = state.upcoming(at: now).first else { return 0 }
        let minutes = max(0, next.expectedAt.timeIntervalSince(now) / 60)
        return max(0, 100 - minutes)
    }

    public enum EndReason: String, Sendable {
        case boardEmpty
        case cap
        case abandoned
        case userEnded

        public var message: String {
            switch self {
            case .boardEmpty: "No more departures"
            case .cap: "Tracking finished"
            case .abandoned: "Live updates stopped"
            case .userEnded: "Tracking stopped"
            }
        }
    }

    /// Why this activity should end now, if it should.
    public static func endReason(
        state: DepartureActivityAttributes.ContentState,
        hardEndsAt: Date,
        lastUpdatedAt: Date,
        now: Date
    ) -> EndReason? {
        if now >= hardEndsAt { return .cap }
        if now.timeIntervalSince(lastUpdatedAt) >= silenceBeforeAbandoning { return .abandoned }
        if state.upcoming(at: now).isEmpty,
           now.timeIntervalSince(lastUpdatedAt) >= emptyBoardGrace {
            return .boardEmpty
        }
        return nil
    }
}
