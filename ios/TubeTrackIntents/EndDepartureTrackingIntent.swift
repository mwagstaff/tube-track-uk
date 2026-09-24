import ActivityKit
import AppIntents
import TubeTrackCore

/// Stops a tracked departure board from the activity itself.
///
/// A `LiveActivityIntent` runs in the app's process, so it can reach
/// ActivityKit directly — no launching the app, no round trip to the server.
struct EndDepartureTrackingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Tracking Departures"
    static let description = IntentDescription("Ends a tracked departure board.")
    static let isDiscoverable = false

    @Parameter(title: "Activity")
    var activityID: String

    init() {
        activityID = ""
    }

    init(activityID: String) {
        self.activityID = activityID
    }

    func perform() async throws -> some IntentResult {
        for activity in Activity<DepartureActivityAttributes>.activities
        where activity.attributes.activityID == activityID || activityID.isEmpty {
            let final = activity.content.state
            await activity.end(
                ActivityContent(state: final, staleDate: nil),
                dismissalPolicy: .after(.now.addingTimeInterval(120))
            )
        }
        return .result()
    }
}
