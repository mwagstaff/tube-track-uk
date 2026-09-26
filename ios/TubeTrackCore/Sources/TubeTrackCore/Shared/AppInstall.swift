import Foundation

/// Random identifier for this installation, shared by the iOS app and its widgets.
/// A watch installation has its own App Group container and therefore its own ID.
public enum AppInstall {
    private static let key = "pushInstallIdentifier"

    public static var identifier: String {
        let defaults = AppGroup.defaults ?? .standard
        if let existing = defaults.string(forKey: key) { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: key)
        return created
    }

    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
