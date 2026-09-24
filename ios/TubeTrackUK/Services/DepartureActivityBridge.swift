import ActivityKit
import Foundation
import TubeTrackCore

/// The only place that touches `ActivityKit.Activity`.
///
/// `Activity` is a non-Sendable class, so under strict concurrency it cannot be
/// stored in one isolation domain and awaited from another. Everything here is
/// `nonisolated` and resolves the activity from `Activity.activities` at the
/// point of use, so the object never crosses a boundary — and, usefully, we can
/// never act on a stale handle to an activity the system has already ended.
enum DepartureActivityBridge {
    typealias State = DepartureActivityAttributes.ContentState

    static var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    static var frequentPushesEnabled: Bool {
        ActivityAuthorizationInfo().frequentPushesEnabled
    }

    static func frequentPushEnablementUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                for await enabled in ActivityAuthorizationInfo().frequentPushEnablementUpdates {
                    continuation.yield(enabled)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every tracked board currently live, newest last.
    static func trackedActivityIDs() -> [String] {
        Activity<DepartureActivityAttributes>.activities.map(\.attributes.activityID)
    }

    static func attributes(for activityID: String) -> DepartureActivityAttributes? {
        activity(for: activityID)?.attributes
    }

    static func state(for activityID: String) -> State? {
        activity(for: activityID)?.content.state
    }

    /// Requests the activity, and reports whether it can be pushed to.
    ///
    /// A `.token` request is refused outright when the app has no APNs
    /// entitlement, which would leave the passenger with no activity at all
    /// over a capability they never asked for. A local-only activity still
    /// tracks the board correctly whenever the app is open, so fall back to one
    /// rather than fail.
    static func request(
        attributes: DepartureActivityAttributes,
        content: ActivityContent<State>
    ) throws -> Bool {
        do {
            _ = try Activity.request(attributes: attributes, content: content, pushType: .token)
            return true
        } catch {
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            return false
        }
    }

    static func update(
        activityID: String,
        content: ActivityContent<State>,
        timestamp: Date
    ) async {
        guard let activity = activity(for: activityID) else { return }
        await activity.update(content, timestamp: timestamp)
    }

    static func end(activityID: String, dismissAfter: TimeInterval) async {
        guard let activity = activity(for: activityID) else { return }
        var final = activity.content.state
        final.sequence += 1
        await activity.end(
            ActivityContent(state: final, staleDate: nil),
            dismissalPolicy: .after(.now.addingTimeInterval(dismissAfter))
        )
    }

    static func endAll(dismissAfter: TimeInterval) async {
        for id in trackedActivityIDs() {
            await end(activityID: id, dismissAfter: dismissAfter)
        }
    }

    /// Push tokens are minted asynchronously and can land before or after we
    /// start listening, so read once, poll briefly, and stream — missing the
    /// token means the server can never update this activity.
    static func pushTokens(for activityID: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                if let token = activity(for: activityID)?.pushToken {
                    continuation.yield(token.hexString)
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for _ in 0..<32 {
                            if Task.isCancelled { return }
                            try? await Task.sleep(for: .milliseconds(250))
                            if let token = activity(for: activityID)?.pushToken {
                                continuation.yield(token.hexString)
                                return
                            }
                        }
                    }
                    group.addTask {
                        guard let activity = activity(for: activityID) else { return }
                        for await token in activity.pushTokenUpdates {
                            if Task.isCancelled { return }
                            continuation.yield(token.hexString)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func activity(for activityID: String) -> Activity<DepartureActivityAttributes>? {
        Activity<DepartureActivityAttributes>.activities
            .first { $0.attributes.activityID == activityID }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
