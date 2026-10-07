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
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
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
        activityTask = Task { [weak self] in
            for await id in DepartureActivityBridge.activityIDs() {
                await self?.adoptRemoteActivity(id)
            }
        }
    }

    var areActivitiesEnabled: Bool {
        DepartureActivityBridge.areActivitiesEnabled
    }

    func isTracking(hubID: String, lineID: TubeLineID, direction: String) -> Bool {
        isTracking(hubID: hubID, lineIDRaw: lineID.rawValue, direction: direction)
    }

    func isTracking(hubID: String, lineIDRaw: String, direction: String) -> Bool {
        guard let trackedActivityID,
              let attributes = DepartureActivityBridge.attributes(for: trackedActivityID) else { return false }
        return attributes.stationHubID == hubID && attributes.lineIDRaw == lineIDRaw
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
        let state = DepartureActivityBoard.contentState(
            from: arrivals, lineID: lineID, direction: direction,
            condition: Self.condition(for: lineID, in: statuses),
            updatedAt: updatedAt, sequence: 1
        )

        await begin(attributes: attributes, state: state)
    }

    func start(pier: RiverPier, lineID: String, board: RiverBoardSnapshot,
               statuses: [RiverLineStatus]) async {
        let now = Date.now
        let state = RiverDepartureBoard.contentState(board: board, pierID: pier.id, lineID: lineID,
                                                     statuses: statuses, sequence: 1, now: now)
        guard !state.departures.isEmpty, !board.stale else { return }
        let attributes = DepartureActivityAttributes(
            activityID: UUID().uuidString, stationHubID: pier.id, stationName: pier.name,
            lineIDRaw: lineID, direction: "All departures", directionFilter: .any,
            startedAt: now, hardEndsAt: now.addingTimeInterval(DepartureActivityPolicy.maximumDuration)
        )
        await begin(attributes: attributes, state: state)
    }

    private func begin(attributes: DepartureActivityAttributes,
                       state: DepartureActivityAttributes.ContentState) async {
        guard areActivitiesEnabled, !Task.isCancelled else { return }
        await endEverything(reason: .userEnded)
        guard !Task.isCancelled else { return }
        sequence = state.sequence
        do {
            let isPushBacked = try DepartureActivityBridge.request(
                attributes: attributes,
                content: content(for: state, attributes: attributes)
            )
            trackedActivityID = attributes.activityID
            lastUpdatedAt = state.updatedAt
            AppGroup.recordTrackedActivity(id: attributes.activityID)
            if isPushBacked {
                observePushToken(activityID: attributes.activityID, attributes: attributes)
            }
        } catch {
            Self.logger.error("Could not start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start(hubID: String, stationName: String, group: NationalRailDepartureGroup,
               updatedAt: Date) async {
        let now = Date.now
        guard now.timeIntervalSince(updatedAt) <= 90,
              !NationalRailStations.codes(for: [hubID]).isEmpty else { return }
        let state = DepartureActivityBoard.nationalRailContentState(
            from: group.arrivals, operatorID: group.operatorID, updatedAt: updatedAt, sequence: 1,
            direction: group.direction)
        guard !state.departures.isEmpty else { return }
        let attributes = DepartureActivityAttributes(
            activityID: UUID().uuidString, stationHubID: hubID, stationName: stationName,
            lineIDRaw: group.operatorID, direction: group.direction.displayName, directionFilter: group.direction,
            startedAt: now, hardEndsAt: now.addingTimeInterval(DepartureActivityPolicy.maximumDuration),
            operatorName: group.name)
        await begin(attributes: attributes, state: state)
    }

    /// Feeds the activity from an in-app refresh. Cheap and unbudgeted — this
    /// is why the tracked station's board stays exact while the app is open.
    func update(
        hubID: String,
        arrivals: [TfLArrivalPrediction],
        statuses: [TfLLineStatus],
        updatedAt: Date,
        nationalRailIsFresh: Bool = true,
        nationalRailUpdatedAt: Date? = nil
    ) async {
        guard let trackedActivityID,
              let attributes = DepartureActivityBridge.attributes(for: trackedActivityID),
              // The app may have moved on to another station; feeding its
              // arrivals to this activity would silently show the wrong trains.
              attributes.stationHubID == hubID else {
            return
        }
        sequence += 1
        if attributes.isNationalRailOperator {
            let railUpdatedAt = nationalRailUpdatedAt ?? updatedAt
            guard nationalRailIsFresh, Date.now.timeIntervalSince(railUpdatedAt) <= 90 else { return }
            let state = DepartureActivityBoard.nationalRailContentState(
                from: arrivals, operatorID: attributes.lineIDRaw, updatedAt: railUpdatedAt, sequence: sequence,
                direction: attributes.directionFilter)
            if state.departures.isEmpty, attributes.directionFilter != .any,
               arrivals.contains(where: { $0.lineId == attributes.lineIDRaw && $0.direction == nil }) { return }
            await publish(state, attributes: attributes)
            return
        }
        guard let lineID = attributes.lineID else { return }
        let state = DepartureActivityBoard.contentState(
            from: arrivals, lineID: lineID, direction: attributes.directionFilter,
            condition: Self.condition(for: lineID, in: statuses),
            updatedAt: updatedAt, sequence: sequence
        )
        await publish(state, attributes: attributes)
    }

    func update(pierID: String, board: RiverBoardSnapshot, statuses: [RiverLineStatus]) async {
        guard let trackedActivityID,
              let attributes = DepartureActivityBridge.attributes(for: trackedActivityID),
              attributes.isRiver, attributes.stationHubID == pierID, !board.stale,
              Date.now.timeIntervalSince(board.updatedAt) <= 90 else { return }
        sequence += 1
        let state = RiverDepartureBoard.contentState(board: board, pierID: pierID,
            lineID: attributes.lineIDRaw, statuses: statuses, sequence: sequence)
        await publish(state, attributes: attributes)
    }

    private func publish(_ state: DepartureActivityAttributes.ContentState,
                         attributes: DepartureActivityAttributes) async {
        let updatedAt = state.updatedAt
        guard attributes.activityID == trackedActivityID,
              updatedAt >= (lastUpdatedAt ?? .distantPast), !Task.isCancelled else { return }
        lastUpdatedAt = updatedAt

        if attributes.scheduleID != nil {
            if Date.now >= attributes.hardEndsAt { await end(reason: .cap); return }
        } else if let reason = DepartureActivityPolicy.endReason(
            state: state,
            hardEndsAt: attributes.hardEndsAt,
            lastUpdatedAt: updatedAt,
            now: .now
        ) {
            await end(reason: reason)
            return
        }

        await DepartureActivityBridge.update(
            activityID: attributes.activityID,
            content: content(for: state, attributes: attributes),
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
        if attributes.scheduleID != nil {
            if now >= attributes.hardEndsAt { await end(reason: .cap) }
        } else if let reason = DepartureActivityPolicy.endReason(
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
        attributes: DepartureActivityAttributes
    ) -> ActivityContent<DepartureActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: attributes.isRiver || attributes.isNationalRailOperator
                ? min(state.updatedAt.addingTimeInterval(90), attributes.hardEndsAt)
                : DepartureActivityPolicy.staleDate(
                updatedAt: state.updatedAt,
                frequentPushesEnabled: isFrequentPushesEnabled,
                hardEndsAt: attributes.hardEndsAt
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
        stateTask?.cancel()
        stateTask = nil
        trackedActivityID = nil
        lastUpdatedAt = nil
        registeredTokens.removeAll()
        AppGroup.recordTrackedActivity(id: nil)
    }

    /// Reattaches to an activity that outlived the app process.
    private func adoptExistingActivity() {
        let ids = DepartureActivityBridge.trackedActivityIDs()
        let preferred = ids.first { DepartureActivityBridge.attributes(for: $0)?.scheduleID == nil } ?? ids.first
        guard let id = preferred,
              let attributes = DepartureActivityBridge.attributes(for: id) else {
            return
        }
        trackedActivityID = id
        lastUpdatedAt = DepartureActivityBridge.state(for: id)?.updatedAt
        sequence = DepartureActivityBridge.state(for: id)?.sequence ?? 0
        AppGroup.recordTrackedActivity(id: id)
        observePushToken(activityID: id, attributes: attributes)
        for other in ids where other != id {
            Task { [weak self] in await self?.adoptRemoteActivity(other) }
        }
    }

    private func adoptRemoteActivity(_ id: String) async {
        guard id != trackedActivityID, let attributes = DepartureActivityBridge.attributes(for: id),
              attributes.scheduleID != nil else { return }
        let manual = DepartureActivityBridge.trackedActivityIDs().contains {
            guard let other = DepartureActivityBridge.attributes(for: $0) else { return false }
            return other.scheduleID == nil && other.hardEndsAt > .now
        }
        if manual || attributes.hardEndsAt <= .now {
            await DepartureActivityBridge.end(activityID: id, dismissAfter: 0)
            await registrar.unregister(activityID: id)
            return
        }
        for other in DepartureActivityBridge.trackedActivityIDs() where other != id {
            guard let previous = DepartureActivityBridge.attributes(for: other),
                  previous.scheduleID != nil || previous.hardEndsAt <= .now else { continue }
            await DepartureActivityBridge.end(activityID: other, dismissAfter: 0)
            await registrar.unregister(activityID: other)
        }
        tokenTask?.cancel()
        registeredTokens.removeAll()
        trackedActivityID = id
        lastUpdatedAt = DepartureActivityBridge.state(for: id)?.updatedAt
        sequence = DepartureActivityBridge.state(for: id)?.sequence ?? 1
        AppGroup.recordTrackedActivity(id: id)
        observePushToken(activityID: id, attributes: attributes)
    }

    private func observePushToken(activityID: String, attributes: DepartureActivityAttributes) {
        tokenTask?.cancel()
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await _ in DepartureActivityBridge.ended(for: activityID) {
                guard let self else { return }
                await self.registrar.unregister(activityID: activityID)
                if self.trackedActivityID == activityID {
                    self.tokenTask?.cancel()
                    self.resetLocalState()
                }
            }
        }
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
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                try await registrar.register(
                    token: token,
                    attributes: attributes,
                    frequentPushesEnabled: isFrequentPushesEnabled
                )
                if !DepartureActivityBridge.trackedActivityIDs().contains(attributes.activityID) {
                    await registrar.unregister(activityID: attributes.activityID)
                }
                return
            } catch {
                if Task.isCancelled { break }
                Self.logger.warning("Could not register activity push token: \(error.localizedDescription, privacy: .public)")
                if attempt < 2 { try? await Task.sleep(for: .seconds(2 * (attempt + 1))) }
            }
        }
        registeredTokens.remove(token)
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
