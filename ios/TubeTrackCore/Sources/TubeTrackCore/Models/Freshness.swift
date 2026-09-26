import Foundation

/// How much a passenger should trust the departures or status on screen.
///
/// Widgets and Live Activities cannot fetch on demand, so what they show is
/// always a snapshot of some age. This is the single place that decides when
/// that age stops being an implementation detail and starts being something
/// the passenger needs told.
public struct Freshness: Equatable, Sendable {
    public enum Tier: Equatable, Sendable {
        /// Recent enough to present as live.
        case fresh
        /// Usable, but the age is worth showing.
        case ageing
        /// Too old to put numbers against: countdowns would be fiction.
        case stale
        /// Nothing to show at all.
        case unavailable
    }

    /// Below this, the snapshot reads as "now".
    public static let ageingThreshold: TimeInterval = 2 * 60
    /// Above this, countdowns are withdrawn rather than shown wrong.
    public static let staleThreshold: TimeInterval = 6 * 60

    public let tier: Tier
    public let updatedAt: Date?
    /// The data came from a cache, or the server flagged its own copy stale.
    public let isCached: Bool

    public init(tier: Tier, updatedAt: Date?, isCached: Bool = false) {
        self.tier = tier
        self.updatedAt = updatedAt
        self.isCached = isCached
    }

    public static func evaluate(
        updatedAt: Date?,
        now: Date = .now,
        isCached: Bool = false
    ) -> Freshness {
        guard let updatedAt else {
            return Freshness(tier: .unavailable, updatedAt: nil, isCached: isCached)
        }
        // A clock that has run backwards (or a server slightly ahead of us)
        // must not read as ancient.
        let age = max(0, now.timeIntervalSince(updatedAt))
        let tier: Tier = switch age {
        case ..<ageingThreshold: .fresh
        case ..<staleThreshold: .ageing
        default: .stale
        }
        return Freshness(tier: tier, updatedAt: updatedAt, isCached: isCached)
    }

    /// Whether times may still be shown as counting down.
    public var showsCountdowns: Bool {
        switch tier {
        case .fresh, .ageing: true
        case .stale, .unavailable: false
        }
    }

    /// Whether the presentation should be visually de-emphasised.
    public var isDegraded: Bool {
        tier != .fresh || isCached
    }

    public var symbolName: String {
        switch tier {
        case .fresh: "dot.radiowaves.left.and.right"
        case .ageing, .stale: "clock.arrow.circlepath"
        case .unavailable: "wifi.slash"
        }
    }

    /// Include the source clock time as well as its age, so a remembered
    /// snapshot cannot look like a fresh update after the widget has aged.
    public func summary(at now: Date = .now) -> String {
        guard let updatedAt else { return "No live data" }
        let age = Int(max(0, now.timeIntervalSince(updatedAt)))
        let relative: String
        switch age {
        case ..<60:
            relative = "just now"
        case ..<3600:
            let minutes = age / 60
            relative = "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        case ..<86400:
            let hours = age / 3600
            relative = "\(hours) hour\(hours == 1 ? "" : "s") ago"
        default:
            let days = age / 86400
            relative = "\(days) day\(days == 1 ? "" : "s") ago"
        }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_GB")
        clock.timeZone = TimeZone(identifier: "Europe/London")!
        clock.dateFormat = "HH:mm"
        return "Updated at \(clock.string(from: updatedAt)), \(relative)"
    }

    /// What to say instead of a departure board once the snapshot is stale.
    public var withdrawnCountdownMessage: String {
        "Open TubeTrack for live times"
    }
}
