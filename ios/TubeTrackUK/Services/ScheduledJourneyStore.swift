import ActivityKit
import Foundation
import TubeTrackCore

enum ScheduleCredentials {
    static var key: String {
        let defaults = UserDefaults.standard
        let name = "scheduledJourneys.key.\(AppInstall.identifier)"
        if let value = defaults.string(forKey: name) { return value }
        let value = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(value, forKey: name)
        return value
    }
}

@MainActor @Observable
final class ScheduledJourneyStore {
    private(set) var journeys: [ScheduledJourney] = []
    private(set) var maximumJourneys = ScheduledJourney.maximumCount
    private(set) var isSaving = false
    private(set) var isLoading = false
    private(set) var setupError: String?
    private var revision = 0
    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private let cacheKey = "scheduledJourneys.cache.\(AppInstall.identifier)"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let observesTokens: Bool

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         baseURL: URL = TubeTrackAPIConfiguration.app.baseURL, pushToken: String? = nil,
         observesTokens: Bool = true) {
        self.defaults = defaults
        self.session = session
        self.baseURL = baseURL
        self.pushToken = pushToken
        self.observesTokens = observesTokens
        if let data = defaults.data(forKey: cacheKey),
           let response = try? JSONDecoder().decode(Response.self, from: data) { apply(response) }
    }

    func start() {
        guard observesTokens, tokenTask == nil else { return }
        tokenTask = Task { [weak self] in
            for await token in Activity<DepartureActivityAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled, let self else { return }
                self.pushToken = token.map { String(format: "%02x", $0) }.joined()
                do { try await self.registerDevice() }
                catch { self.setupError = error.localizedDescription }
            }
        }
    }

    func refresh() async {
        start()
        guard !isSaving, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response: Response = try await request(method: "GET")
            apply(response)
            try await registerDevice()
            setupError = DepartureActivityBridge.areActivitiesEnabled ? nil
                : "Live Activities are disabled. Enable them for Tube Track in Settings to receive your scheduled boards."
        } catch { setupError = error.localizedDescription }
    }

    func save(_ journey: ScheduledJourney) async throws {
        var next = journeys.filter { $0.id != journey.id }
        next.append(journey)
        try await replace(next)
    }

    func delete(_ journey: ScheduledJourney) async throws {
        try await replace(journeys.filter { $0.id != journey.id })
    }

    func save(_ journey: ScheduledJourney, replacing conflicts: [ScheduledJourney]) async throws {
        // Only remove the exact journeys the user reviewed. A refresh while the
        // confirmation is open must not silently expand the deletion.
        guard !conflicts.isEmpty,
              Set(conflicts) == Set(journey.conflictingJourneys(in: journeys)) else {
            throw ScheduleError("Your journeys changed. Review the conflicts and try again.")
        }
        let removedIDs = Set(conflicts.map(\.id))
        let next = journeys.filter { $0.id != journey.id && !removedIDs.contains($0.id) } + [journey]
        // One revision-checked write: a failed save never deletes the old journey.
        try await replace(next)
    }

    private func replace(_ next: [ScheduledJourney]) async throws {
        guard !isSaving, !isLoading else { throw ScheduleError("Journeys are syncing. Please try again.") }
        if let error = ScheduledJourney.validationError(for: next, maximum: maximumJourneys) { throw ScheduleError(error) }
        isSaving = true
        defer { isSaving = false }
        // Pausing/deleting remains possible when permission has been disabled.
        if next.contains(where: { $0.enabled && !journeys.contains($0) }) {
            guard DepartureActivityBridge.areActivitiesEnabled else {
                throw ScheduleError("Enable Live Activities for Tube Track in Settings to schedule a journey.")
            }
            try await registerDevice()
        }
        let previous = journeys
        let response: Response = try await request(method: "PUT", body: SaveBody(journeys: next, revision: revision))
        apply(response)
        setupError = nil
        // Close affected activities immediately on this device as well as through APNs.
        for id in DepartureActivityBridge.trackedActivityIDs() {
            guard let attributes = DepartureActivityBridge.attributes(for: id),
                  let scheduleID = attributes.scheduleID else { continue }
            if previous.first(where: { $0.id == scheduleID }) != response.journeys.first(where: { $0.id == scheduleID }) {
                await DepartureActivityBridge.end(activityID: id, dismissAfter: 0)
            }
        }
    }

    private func registerDevice() async throws {
        let token = pushToken ?? Activity<DepartureActivityAttributes>.pushToStartToken.map {
            $0.map { String(format: "%02x", $0) }.joined()
        }
        guard let token else { throw ScheduleError("Live Activity setup is not ready. Check your connection and try again.") }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let _: Empty = try await request(method: "PUT", path: "/device", body: DeviceBody(
            token: token, activitiesEnabled: DepartureActivityBridge.areActivitiesEnabled,
            frequentPushesEnabled: DepartureActivityBridge.frequentPushesEnabled, environment: environment))
    }

    private func apply(_ response: Response) {
        journeys = response.journeys
        revision = response.revision
        maximumJourneys = response.maximumJourneys
        if let data = try? JSONEncoder().encode(response) { defaults.set(data, forKey: cacheKey) }
    }

    private func request<R: Decodable>(method: String, path: String = "") async throws -> R {
        try await request(method: method, path: path, body: Optional<Empty>.none)
    }

    private func request<R: Decodable, B: Encodable>(method: String, path: String = "", body: B?) async throws -> R {
        var request = URLRequest(url: baseURL.appending(path: "/api/v1/scheduled-journeys\(path)"))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(AppInstall.identifier, forHTTPHeaderField: "X-TubeTrack-Install")
        request.setValue(ScheduleCredentials.key, forHTTPHeaderField: "X-TubeTrack-Schedule-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScheduleError("Could not contact the journey service.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 409 { throw ScheduleError("Your journeys changed. Close this editor and reload your journeys before trying again.") }
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error.message
            throw ScheduleError(message ?? "Scheduling is temporarily unavailable. Please try again.")
        }
        return try JSONDecoder().decode(R.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    private struct Response: Codable { let journeys: [ScheduledJourney]; let revision: Int; let maximumJourneys: Int }
    private struct SaveBody: Encodable { let journeys: [ScheduledJourney]; let revision: Int }
    private struct DeviceBody: Encodable { let token: String; let activitiesEnabled: Bool; let frequentPushesEnabled: Bool; let environment: String }
    private struct Empty: Codable {}
    private struct ServerError: Decodable { let error: Detail; struct Detail: Decodable { let message: String } }
}

struct ScheduleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
