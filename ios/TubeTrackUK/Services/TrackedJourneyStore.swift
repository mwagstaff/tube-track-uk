import ActivityKit
import Foundation
import Observation
import TubeTrackCore

struct TrackedJourney: Codable, Identifiable, Sendable {
    let id: String
    let plan: PlannedJourney
    let scheduleID: String?
    let legIndex: Int
    let phase: String
    let revision: Int
    let startedAt: Date
    let endsAt: Date
    let state: JourneyActivityAttributes.ContentState?
    let boards: [String: CustomDepartureBoard]?
    let boardedService: TfLArrivalPrediction?
    var transitIndices: [Int] { plan.legs.indices.filter { !["walking", "transfer"].contains(plan.legs[$0].mode) } }
    var currentLeg: JourneyLeg { plan.legs[legIndex] }
    var boardIndex: Int? { phase == "onboard" ? transitIndices.first(where: { $0 > legIndex }) : legIndex }
}

struct TrackedRouteSchedule: Codable, Identifiable, Sendable {
    let id: String
    let plan: PlannedJourney
    let date: Date?
    let days: [Int]
    let minute: Int
    let enabled: Bool
    let message: String?
}

@MainActor @Observable
final class TrackedJourneyStore {
    private(set) var active: TrackedJourney?
    private(set) var schedules: [TrackedRouteSchedule] = []
    private(set) var busy = false
    var error: String?
    var showsJourney = false
    var locationEnabled = false
    let location = JourneyLocationTracker()
    private var revision = -1
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private var tokenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var registeredDeviceState: String?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var cacheKey: String { "trackedRoutes.v1.\(AppInstall.identifier)" }

    init(defaults: UserDefaults = .standard, baseURL: URL = TubeTrackAPIConfiguration.app.baseURL) {
        self.defaults = defaults; self.baseURL = baseURL
        if let data = defaults.data(forKey: "trackedRoutes.v1.\(AppInstall.identifier)"),
           let saved = try? Self.decoder.decode(Response.self, from: data) { apply(saved) }
        locationEnabled = active != nil && defaults.string(forKey: "journeyLocation.session") == active?.id
        location.onProgress = { [weak self] index, phase in
            guard let self, let active = self.active, !self.busy else { return }
            Task { await self.progress(index: index, phase: phase, id: active.id, automatic: true) }
        }
        location.onRefresh = { [weak self] in
            guard let self, Date.now.timeIntervalSince(self.lastRefresh) >= 30 else { return }
            Task { await self.refresh() }
        }
    }

    private struct Response: Codable { let active: TrackedJourney?; let schedules: [TrackedRouteSchedule]; let revision: Int }
    private struct Envelope<T: Decodable>: Decodable { let data: T }
    private struct ServerFailure: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid journey date")) }
            return date
        }
        return decoder
    }
    private func apply(_ response: Response) {
        guard response.revision >= revision else { return }
        let previousID = active?.id
        active = response.active; schedules = response.schedules; revision = response.revision
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(response) { defaults.set(data, forKey: cacheKey) }
        if let previousID, previousID != active?.id { Task { await JourneyActivityBridge.end(previousID) } }
        location.session = active
        if active == nil { locationEnabled = false; location.stop(); defaults.removeObject(forKey: "journeyLocation.session") }
    }
    private func request(_ path: String = "", method: String = "GET", body: [String: Any]? = nil) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: "/api/v2/tracked-journeys" + path))
        request.httpMethod = method; request.timeoutInterval = 30
        request.setValue(AppInstall.identifier, forHTTPHeaderField: "X-TubeTrack-Install")
        request.setValue(ScheduleCredentials.key, forHTTPHeaderField: "X-TubeTrack-Schedule-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ScheduleError((try? Self.decoder.decode(ServerFailure.self, from: data).error.message)
                ?? "Journey tracking is unavailable. Check your connection and that the server supports tracked routes.")
        }
        return try Self.decoder.decode(Envelope<Response>.self, from: data).data
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        lastRefresh = .now
        do {
            if let token = Activity<JourneyActivityAttributes>.pushToStartToken { await registerDevice(token) }
            apply(try await request()); error = nil; await updateActivity()
        }
        catch { self.error = error.localizedDescription }
    }
    func start(_ journey: PlannedJourney, searchID: String?, replacing: Bool = false) async {
        guard let searchID, !busy else { error = "Refresh route suggestions before starting."; return }
        busy = true; defer { busy = false }
        do {
            var body: [String: Any] = ["searchID": searchID, "journeyID": journey.id]
            if replacing, let active { body["replaceID"] = active.id; body["replaceRevision"] = active.revision }
            apply(try await request("/start", method: "POST", body: body))
            showsJourney = true; error = nil
            try JourneyActivityBridge.start(active)
            observeActivities()
        } catch { self.error = error.localizedDescription }
    }
    func progress(index: Int, phase: String, id: String, boardedID: String? = nil, automatic: Bool = false) async {
        guard let active, active.id == id, !busy else { return }
        busy = true; defer { busy = false }
        var body: [String: Any] = ["id": id, "revision": active.revision, "legIndex": index, "phase": phase]
        if let boardedID { body["boardedID"] = boardedID }
        do {
            apply(try await request("/progress", method: "PUT", body: body)); error = nil
            if !automatic { location.suppressAutomaticUntil = .now.addingTimeInterval(90) }
            if phase == "complete" { await JourneyActivityBridge.end(id); showsJourney = false }
            else { await updateActivity() }
        } catch { self.error = error.localizedDescription }
    }
    func setLocation(_ enabled: Bool) {
        locationEnabled = enabled
        if enabled { defaults.set(active?.id, forKey: "journeyLocation.session") } else { defaults.removeObject(forKey: "journeyLocation.session") }
        if enabled { location.session = active; location.start() } else { location.stop() }
    }
    func resumeLocation() { if locationEnabled, active != nil { location.start() } }
    func schedule(_ journey: PlannedJourney, searchID: String?, date: Date?, days: [Int], minute: Int, editingID: String? = nil) async -> Bool {
        guard searchID != nil || editingID != nil else { error = "Refresh route suggestions before scheduling."; return false }
        while busy {
            do { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() } catch { return false }
        }
        busy = true; defer { busy = false }
        do {
            guard ActivityAuthorizationInfo().areActivitiesEnabled,
                  let token = Activity<JourneyActivityAttributes>.pushToStartToken else {
                throw ScheduleError("Live Activity setup is not ready. Enable Live Activities and try again shortly.")
            }
            apply(try await request("/device", method: "PUT", body: ["token": token.hex, "environment": Self.environment, "activitiesEnabled": true]))
            var body: [String: Any] = ["journeyID": journey.id, "days": days, "minute": minute]
            if let searchID { body["searchID"] = searchID }
            if let date { body["date"] = date.ISO8601Format() }
            apply(try await request(editingID.map { "/schedules/" + $0 } ?? "/schedules", method: editingID == nil ? "POST" : "PUT", body: body)); error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteSchedule(_ id: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let oldID = active?.id
        do {
            apply(try await request("/schedules/\(id)", method: "DELETE")); error = nil
            if active == nil, let oldID { await JourneyActivityBridge.end(oldID) }
        } catch { self.error = error.localizedDescription }
    }
    func run() async {
        observeActivities()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await _ in Activity<JourneyActivityAttributes>.activityUpdates {
                    guard !Task.isCancelled else { return }
                    await self?.discoveredActivity()
                }
            }
            group.addTask { [weak self] in
                for await token in Activity<JourneyActivityAttributes>.pushToStartTokenUpdates {
                    guard !Task.isCancelled else { return }
                    await self?.registerDevice(token)
                }
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            await group.waitForAll()
        }
    }
    private func registerDevice(_ token: Data) async {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let key = token.hex + String(enabled)
        guard registeredDeviceState != key else { return }
        do {
            apply(try await request("/device", method: "PUT", body: ["token": token.hex, "environment": Self.environment, "activitiesEnabled": enabled]))
            registeredDeviceState = key
        } catch { /* Retry at the next schedule save; ordinary in-app tracking remains available. */ }
    }
    private func discoveredActivity() async { observeActivities(); await refresh() }
    private func observeActivities() {
        for activity in Activity<JourneyActivityAttributes>.activities {
            let id = activity.attributes.sessionID
            guard tokenTasks[id] == nil else { continue }
            tokenTasks[id] = Task { [weak self] in
                if let token = JourneyActivityBridge.token(id) { await self?.registerToken(token, id: id) }
                for await token in JourneyActivityBridge.tokens(id) {
                    guard !Task.isCancelled else { return }
                    await self?.registerToken(token, id: id)
                }
            }
        }
        let live = Set(Activity<JourneyActivityAttributes>.activities.map { $0.attributes.sessionID })
        for id in tokenTasks.keys where !live.contains(id) { tokenTasks.removeValue(forKey: id)?.cancel() }
    }
    private func registerToken(_ token: Data, id: String) async {
        for attempt in 0..<3 {
            do {
                apply(try await request("/token", method: "PUT", body: ["id": id, "token": token.hex, "environment": Self.environment])); return
            } catch { if attempt == 2 { self.error = "Background journey updates could not be registered. Reopen the app to retry." } }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    private func updateActivity() async {
        guard let active, let state = active.state else { return }
        await JourneyActivityBridge.update(active.id, state: state)
    }
    private static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }

enum JourneyActivityBridge {
    static func start(_ journey: TrackedJourney?) throws {
        guard let journey, let state = journey.state, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard !Activity<JourneyActivityAttributes>.activities.contains(where: { $0.attributes.sessionID == journey.id }) else { return }
        _ = try Activity.request(attributes: JourneyActivityAttributes(sessionID: journey.id,
            destination: state.destination, endsAtEpoch: Int(journey.endsAt.timeIntervalSince1970), origin: journey.plan.legs.first?.from.name),
            content: ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: Double(state.staleAtEpoch))), pushType: .token)
    }
    static func update(_ id: String, state: JourneyActivityAttributes.ContentState) async {
        guard let activity = Activity<JourneyActivityAttributes>.activities.first(where: { $0.attributes.sessionID == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: Double(state.staleAtEpoch))))
    }
    static func end(_ id: String) async {
        guard let activity = Activity<JourneyActivityAttributes>.activities.first(where: { $0.attributes.sessionID == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
    static func token(_ id: String) -> Data? { Activity<JourneyActivityAttributes>.activities.first { $0.attributes.sessionID == id }?.pushToken }
    static func tokens(_ id: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                guard let activity = Activity<JourneyActivityAttributes>.activities.first(where: { $0.attributes.sessionID == id }) else { continuation.finish(); return }
                for await token in activity.pushTokenUpdates { continuation.yield(token) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
