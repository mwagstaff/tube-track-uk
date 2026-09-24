import Foundation
import OSLog
import TubeTrackCore

/// Tells the Tube Track API where to push a tracked board.
///
/// Registration is best-effort by design. If it fails, the activity is still
/// correct — it just stops updating once the app goes away, which is exactly
/// what happens when a push is dropped anyway. So nothing here is allowed to
/// surface an error to the passenger or block starting an activity.
struct LiveActivityPushRegistrar: LiveActivityPushRegistering {
    let baseURL: URL
    let clientSecret: String
    let installID: String
    let session: URLSession

    private static let logger = Logger(
        subsystem: "dev.skynolimit.TubeTrackUK",
        category: "LiveActivityPush"
    )

    init(
        baseURL: URL = TubeTrackAPIConfiguration.app.baseURL,
        clientSecret: String = AppSecrets.pushClientSecret,
        installID: String = AppInstall.identifier,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.clientSecret = clientSecret
        self.installID = installID
        self.session = session
    }

    var isConfigured: Bool { !clientSecret.isEmpty }

    func register(
        token: String,
        attributes: DepartureActivityAttributes,
        frequentPushesEnabled: Bool
    ) async throws {
        guard isConfigured, let lineID = attributes.lineID else { return }

        let stopIDs = StationIndex.bundled.hub(containing: attributes.stationHubID)?.stopIDs
            ?? [attributes.stationHubID]
        let body = RegistrationBody(
            activityId: attributes.activityID,
            token: token,
            lineId: lineID.rawValue,
            direction: attributes.directionFilterRaw,
            hubId: attributes.stationHubID,
            stopIds: stopIDs,
            frequentPushesEnabled: frequentPushesEnabled
        )

        var request = self.request(path: "/api/v1/push/live-activities", method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Self.logger.warning("Push registration refused: \(status, privacy: .public)")
            throw TubeTrackAPIClientError.httpStatus(status)
        }
        Self.logger.notice("Registered \(attributes.activityID, privacy: .public) for push")
    }

    func unregister(activityID: String) async {
        guard isConfigured else { return }
        let request = self.request(
            path: "/api/v1/push/live-activities/\(activityID)",
            method: "DELETE"
        )
        // The server treats this as idempotent, and an activity that has already
        // ended locally is no worse off if the call never lands.
        _ = try? await session.data(for: request)
    }

    private func request(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(installID, forHTTPHeaderField: "X-TubeTrack-Install")
        request.timeoutInterval = 15
        return request
    }

    private struct RegistrationBody: Encodable {
        let activityId: String
        let token: String
        let lineId: String
        let direction: String
        let hubId: String
        let stopIds: [String]
        let frequentPushesEnabled: Bool
    }
}

/// A stable, anonymous id for this install.
///
/// Not the IDFV and not anything Apple hands out: it exists only so the server
/// can rate-limit and namespace subscriptions, and it is never sent anywhere
/// else. Stored in the App Group so the widget extension would see the same one.
enum AppInstall {
    private static let key = "pushInstallIdentifier"

    static var identifier: String {
        if let existing = AppGroup.defaults?.string(forKey: key) { return existing }
        // The server accepts [0-9A-Za-z-]{8,64}, which a UUID satisfies.
        let created = UUID().uuidString
        AppGroup.defaults?.set(created, forKey: key)
        return created
    }
}

/// Build-time secrets, injected through `Configuration/Shared.xcconfig` so they
/// are not literals in source.
///
/// This one is obfuscation rather than authentication — it ships inside the app,
/// so anyone who unpacks the binary has it. It raises the cost of casual abuse
/// of the registration endpoint and nothing more; what actually bounds the
/// damage is the server's rate limiting and entry cap. App Attest is the real
/// answer and is deliberately left for its own change.
enum AppSecrets {
    static var pushClientSecret: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TubeTrackPushClientSecret")
            as? String else {
            return ""
        }
        // An unset xcconfig variable arrives as the literal placeholder.
        return value.hasPrefix("$(") ? "" : value
    }
}
