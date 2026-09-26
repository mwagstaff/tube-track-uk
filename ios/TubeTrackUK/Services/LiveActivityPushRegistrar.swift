import Foundation
import OSLog
import TubeTrackCore

/// Tells the Tube Track API where to push a tracked board.
///
/// Registration is best-effort by design. If it fails, the activity is still
/// correct — it just stops updating once the app goes away, which is exactly
/// what happens when a push is dropped anyway. So nothing here is allowed to
/// surface an error to the passenger or block starting an activity.
///
/// There is no client credential. One baked into the app would be readable by
/// anyone who unpacks it, so it would have bought obfuscation rather than
/// authentication; the server bounds abuse with rate limits and an entry cap
/// instead. App Attest is the real answer if this ever needs one.
struct LiveActivityPushRegistrar: LiveActivityPushRegistering {
    let baseURL: URL
    let installID: String
    let session: URLSession

    private static let logger = Logger(
        subsystem: "dev.skynolimit.TubeTrackUK",
        category: "LiveActivityPush"
    )

    init(
        baseURL: URL = TubeTrackAPIConfiguration.app.baseURL,
        installID: String = AppInstall.identifier,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.installID = installID
        self.session = session
    }

    func register(
        token: String,
        attributes: DepartureActivityAttributes,
        frequentPushesEnabled: Bool
    ) async throws {
        let stopIDs = attributes.isRiver ? [attributes.stationHubID]
            : StationIndex.bundled.hub(containing: attributes.stationHubID)?.stopIDs ?? [attributes.stationHubID]
        let body = RegistrationBody(
            activityId: attributes.activityID,
            token: token,
            lineId: attributes.lineIDRaw,
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
        request.setValue(installID, forHTTPHeaderField: "X-TubeTrack-Install")
        request.setValue("ios_app", forHTTPHeaderField: "X-TubeTrack-Surface")
        request.setValue(AppInstall.appVersion, forHTTPHeaderField: "X-TubeTrack-App-Version")
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
