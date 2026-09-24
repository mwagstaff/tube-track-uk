import Foundation

/// The App Group shared by the app and its widget extension. Everything the
/// widgets read that the app wrote lives under this container.
public enum AppGroup {
    public static let suiteName = "group.dev.skynolimit.TubeTrackUK"

    private static let recentStationIDsKey = "recentStationIDs"
    private static let maximumRecentStations = 8

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Offline snapshots (`status.json` and friends) live here so the widget
    /// extension can fall back to the app's most recent download.
    public static var snapshotDirectory: URL? {
        containerURL?.appending(path: "OfflineSnapshots", directoryHint: .isDirectory)
    }

    /// Stations the passenger selected in the app most recently, newest first.
    /// The departures widget offers these before asking for a search.
    public static var recentStationIDs: [String] {
        defaults?.stringArray(forKey: recentStationIDsKey) ?? []
    }

    private static let trackedActivityKey = "trackedLiveActivityID"

    /// The Live Activity currently tracking a departure board, if any. Shared
    /// so the widget extension can tell whether a board is already being
    /// tracked without asking ActivityKit.
    public static var trackedActivityID: String? {
        defaults?.string(forKey: trackedActivityKey)
    }

    public static func recordTrackedActivity(id: String?) {
        guard let defaults else { return }
        if let id {
            defaults.set(id, forKey: trackedActivityKey)
        } else {
            defaults.removeObject(forKey: trackedActivityKey)
        }
    }

    public static func recordRecentStation(id: String) {
        guard let defaults else { return }
        var identifiers = recentStationIDs.filter { $0 != id }
        identifiers.insert(id, at: 0)
        defaults.set(Array(identifiers.prefix(maximumRecentStations)), forKey: recentStationIDsKey)
    }
}
