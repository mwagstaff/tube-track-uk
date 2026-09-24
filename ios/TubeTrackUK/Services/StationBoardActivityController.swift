import ActivityKit
import Foundation
import OSLog
import TubeTrackCore

/// Starts, feeds and ends the "Track departures" Live Activity.
///
/// One activity at a time: a second tracked board replaces the first, because
/// two competing countdowns on a Lock Screen help nobody.
///
/// While the app is in front this keeps the activity fed from the polling the
/// app already does, which costs nothing and needs no server. Once push is
/// wired up the server takes over between foregrounds, and this becomes the
/// fast path rather than the only one.
@MainActor
@Observable
final class StationBoardActivityController {
    private(set) var trackedActivityID: String?
    private(set) var isFrequentPushesEnabled: Bool

    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var lastUpdatedAt: Date?
    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var enablementTask: Task<Void, Never>?
    @ObservationIgnored private var registeredTokens: Set<String> = []
    @ObservationIgnored private let registrar: any LiveActivityPushRegistering

    private static let logger = Logger(subsystem: "dev.skynolimit.TubeTrackUK", category: "LiveActivity")
    private static let dismissAfter: TimeInterval = 120

    init(registrar: any LiveActivityPushRegistering = NoopLiveActivityPushRegistrar()) {
        self.registrar = registrar
        isFrequentPushesEnabled = DepartureActivityBridge.frequentPushesEnabled
        adoptExistingActivity()
        observeFrequentPushEnablement()
    }

    var areActivitiesEnabled: Bool {
        DepartureActivityBridge.areActivitiesEnabled
    }

    func isTracking(hubID: String, lineID: TubeLineID, direction: String) -> Bool {
        guard let trackedActivityID,
              let attributes = DepartureActivityBridge.attributes(for: trackedActivityID) else {
            return false
        }
        return attributes.stationHubID == hubID
            && attributes.lineIDRaw == lineID.rawValue
            && attributes.direction == direction
    }

    // MARK: - Lifecycle

    func start(
        hubID: String,
        stationName: String,
        lineID: TubeLineID,
        direction: DepartureDirectionFilter,
        directionLabel: String,
        arrivals: [TfLArrivalPrediction],
        statuses: [TfLLineStatus],
        updatedAt: Date
    ) async {
        guard areActivitiesEnabled else {
            Self.logger.notice("Live Activities are disabled for this app")
            return
        }
        await endEverything(reason: .userEnded)

        let now = Date.now
        let attributes = DepartureActivityAttributes(
            activityID: UUID().uuidString,
            stationHubID: hubID,
            stationName: stationName,
            lineID: lineID,
            direction: directionLabel,
            directionFilter: direction,
            startedAt: now,
            hardEndsAt: now.addingTimeInterval(DepartureActivityPolicy.maximumDuration)
        )
        sequence = 1
        let state = DepartureActivityBoard.contentState(
            from: arrivals, lineID: lineID, direction: direction,
            condition: Self.condition(for: lineID, in: statuses),
            updatedAt: updatedAt, sequence: sequence
        )

        do {
            let isPushBacked = try DepartureActivityBridge.request(
                attributes: attributes,
                content: content(for: state, hardEndsAt: attributes.hardEndsAt)
            )
            trackedActivityID = attributes.activityID
            lastUpdatedAt = updatedAt
            AppGroup.recordTrackedActivity(id: attributes.activityID)
            Self.logger.notice("Started tracking \(hubID, privacy: .public) \(lineID.rawValue, privacy: .public) \(directionLabel, privacy: .public), push-backed: \(isPushBacked, privacy: .public)")
            if isPushBacked {
                observePushToken(activityID: attributes.activityID, attributes: attributes)
            }
        } catch {
            Self.logger.error("Could not start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Feeds the activity from an in-app refresh. Cheap and unbudgeted — this
    /// is why the tracked station's board stays exact while the app is open.
    func update(
        hubID: String,
        arrivals: [TfLArrivalPrediction],
        statuses: [TfLLineStatus],
        updatedAt: Date
    ) async {
        guard let trackedActivityID,
              let attributes = DepartureActivityBridge.attributes(for: trackedActivityID),
              let lineID = attributes.lineID,
              // The app may have moved on to another station; feeding its
              // arrivals to this activity would silently show the wrong trains.
              attributes.stationHubID == hubID else {
            return
        }
        sequence += 1
        let state = DepartureActivityBoard.contentState(
            from: arrivals, lineID: lineID, direction: attributes.directionFilter,
            condition: Self.condition(for: lineID, in: statuses),
            updatedAt: updatedAt, sequence: sequence
        )
        lastUpdatedAt = updatedAt

        if let reason = DepartureActivityPolicy.endReason(
            state: state,
            hardEndsAt: attributes.hardEndsAt,
            lastUpdatedAt: updatedAt,
            now: .now
        ) {
            await end(reason: reason)
            return
        }

        await DepartureActivityBridge.update(
            activityID: trackedActivityID,
            content: content(for: state, hardEndsAt: attributes.hardEndsAt),
            timestamp: updatedAt
        )
    }

    func end(reason: DepartureActivityPolicy.EndReason) async {
        await endEverything(reason: reason)
    }

    /// Ends the activity if it has outlived its cap or its data, without
    /// needing a refresh to have happened.
    func endIfExpired(now: Date = .now) async {
        guard let trackedActivityID,
              let attributes = DepartureActivityBridge.attributes(for: trackedActivityID),
              let state = DepartureActivityBridge.state(for: trackedActivityID) else {
            return
        }
        if let reason = DepartureActivityPolicy.endReason(
            state: state,
            hardEndsAt: attributes.hardEndsAt,
            lastUpdatedAt: lastUpdatedAt ?? state.updatedAt,
            now: now
        ) {
            await end(reason: reason)
        }
    }

    // MARK: - Internals

    /// The caller hands over whatever statuses it has; which line matters is
    /// the activity's business, not the caller's.
    private static func condition(
        for lineID: TubeLineID,
        in statuses: [TfLLineStatus]
    ) -> LineServiceCondition? {
        guard let status = statuses.first(where: { $0.id == lineID }) else { return nil }
        return LineServiceCondition.condition(for: status)
    }

    private func content(
        for state: DepartureActivityAttributes.ContentState,
        hardEndsAt: Date
    ) -> ActivityContent<DepartureActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: DepartureActivityPolicy.staleDate(
                updatedAt: state.updatedAt,
                frequentPushesEnabled: isFrequentPushesEnabled,
                hardEndsAt: hardEndsAt
            ),
            relevanceScore: DepartureActivityPolicy.relevanceScore(state: state, now: .now)
        )
    }

    private func endEverything(reason: DepartureActivityPolicy.EndReason) async {
        let ids = DepartureActivityBridge.trackedActivityIDs()
        guard !ids.isEmpty else {
            resetLocalState()
            return
        }
        tokenTask?.cancel()
        tokenTask = nil
        await DepartureActivityBridge.endAll(dismissAfter: Self.dismissAfter)
        Self.logger.notice("Ended tracking: \(reason.rawValue, privacy: .public)")
        for id in ids {
            await registrar.unregister(activityID: id)
        }
        resetLocalState()
    }

    private func resetLocalState() {
        trackedActivityID = nil
        lastUpdatedAt = nil
        registeredTokens.removeAll()
        AppGroup.recordTrackedActivity(id: nil)
    }

    /// Reattaches to an activity that outlived the app process.
    private func adoptExistingActivity() {
        guard let id = DepartureActivityBridge.trackedActivityIDs().first,
              let attributes = DepartureActivityBridge.attributes(for: id) else {
            return
        }
        trackedActivityID = id
        lastUpdatedAt = DepartureActivityBridge.state(for: id)?.updatedAt
        sequence = DepartureActivityBridge.state(for: id)?.sequence ?? 0
        AppGroup.recordTrackedActivity(id: id)
        observePushToken(activityID: id, attributes: attributes)
    }

    private func observePushToken(activityID: String, attributes: DepartureActivityAttributes) {
        tokenTask?.cancel()
        tokenTask = Task { [weak self] in
            for await token in DepartureActivityBridge.pushTokens(for: activityID) {
                await self?.register(token: token, attributes: attributes)
            }
        }
    }

    private func register(token: String, attributes: DepartureActivityAttributes) async {
        // Tokens are minted more than once and arrive from several places at
        // once; registering the same one twice is a wasted round trip.
        guard registeredTokens.insert(token).inserted else { return }
        do {
            try await registrar.register(
                token: token,
                attributes: attributes,
                frequentPushesEnabled: isFrequentPushesEnabled
            )
        } catch {
            Self.logger.warning("Could not register activity push token: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeFrequentPushEnablement() {
        enablementTask = Task { [weak self] in
            for await enabled in DepartureActivityBridge.frequentPushEnablementUpdates() {
                self?.isFrequentPushesEnabled = enabled
            }
        }
    }
}

/// Where an activity's push token goes. The real implementation posts to the
/// Tube Track API; until that exists the app still behaves correctly, just
/// without server updates.
protocol LiveActivityPushRegistering: Sendable {
    func register(token: String, attributes: DepartureActivityAttributes, frequentPushesEnabled: Bool) async throws
    func unregister(activityID: String) async
}

struct NoopLiveActivityPushRegistrar: LiveActivityPushRegistering {
    func register(token: String, attributes: DepartureActivityAttributes, frequentPushesEnabled: Bool) async throws {}
    func unregister(activityID: String) async {}
}
