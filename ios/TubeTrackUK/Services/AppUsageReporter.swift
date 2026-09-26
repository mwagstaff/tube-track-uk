import Foundation
import TubeTrackCore

/// Best-effort product usage signals. They never delay a screen or block offline use.
@MainActor
enum AppUsageReporter {
    private static var foregroundSessionReported = false

    static func becameActive(feature: String) {
        guard !foregroundSessionReported else { return }
        foregroundSessionReported = true
        post(event: "app_open", feature: feature)
    }

    static func enteredBackground() {
        foregroundSessionReported = false
    }

    static func openedFeature(_ feature: String) {
        guard foregroundSessionReported else { return }
        post(event: "feature_open", feature: feature)
    }

    private static func post(event: String, feature: String) {
        let installID = AppInstall.identifier
        let appVersion = AppInstall.appVersion
        let url = TubeTrackAPIConfiguration.app.baseURL.appending(path: "/api/v1/usage")
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(installID, forHTTPHeaderField: "X-TubeTrack-Install")
            request.setValue("ios_app", forHTTPHeaderField: "X-TubeTrack-Surface")
            request.setValue(appVersion, forHTTPHeaderField: "X-TubeTrack-App-Version")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "event": event, "feature": feature
            ])
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
