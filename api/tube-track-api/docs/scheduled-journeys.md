# Scheduled journeys

Each installation can save up to three journeys. A journey contains ISO weekdays
(Monday = 1), an enabled flag, and one or both morning/afternoon windows. Each
window stores station, line or National Rail operator, direction and start/end
minutes after midnight. National Rail boards use `lineId: "national-rail:SE"` (for
example), an `operatorName`, a canonical station ID and server-resolved CRS codes.
Existing TfL boards retain their original wire format.
Times always refer to `Europe/London`; the phone and server timezones do not
change the commute. Enabled windows cannot overlap on any shared weekday.

## API and storage

The routes are available when APNs and schedule persistence are configured:

- `GET /api/v1/scheduled-journeys` returns `journeys`, `revision`, `maximumJourneys`.
- `PUT /api/v1/scheduled-journeys` replaces the installation's list using that
  revision. Stale revisions return 409; invalid schedules return 400.
- `PUT /api/v1/scheduled-journeys/device` registers a push-to-start token,
  APNs environment, Live Activity permission and frequent-update preference.

All requests require `X-TubeTrack-Install` and a random 64-character hexadecimal
`X-TubeTrack-Schedule-Key`. The first write claims that installation; later reads
and writes require the same key. Only its SHA-256 hash is retained on the server.
This is installation ownership, not account authentication or device attestation.
The iOS app keeps the key and confirmed schedules in installation-scoped defaults.
Neither is synced through an account. Saves/deletions require an online server
acknowledgement; a failed save does not change the confirmed local copy.

`scheduled-journeys.json` lives in `TUBETRACK_UK_DATA_DIR` or the existing default
application data directory, outside deployed source. Atomic writes and serialized
transactions protect schedules and occurrence claims. Back up this file alongside
`push-tokens.json`. The store is intended for the existing single API process;
multiple writers require a shared transactional datastore. Corrupt schedule files
are preserved for recovery and disable scheduling without disabling manual Track.

## Activity lifecycle

The scheduler checks every 15 seconds. At a due window it projects a fresh board
using the existing TfL cache, Thameslink source or National Rail operator feed,
persists an
occurrence claim and sends an ActivityKit `start` push. The existing activity
attributes/UI are reused with an optional `scheduleID` and the window's hard end.
An update token delivered to the awakened app is registered against the persisted
occurrence; the regular notifier then supplies departure updates.

The scheduler ends activities independently of departure polling, including after
deletion, pausing or editing. Token rotation preserves the original end time.
Scheduled boards support up to two hours; manual Track retains its 90-minute cap.
The app also ends affected activities locally after a confirmed edit/deletion.

Operational policies:

- An existing manual board suppresses that occurrence. The app also rejects a
  remotely started board if a manual board wins a concurrent start race.
- Each journey/date/period starts at most once. A dismissed board is not restarted.
- Changes take effect at the next window; saving during a window does not start it.
- Fresh data may be retried for the first three minutes of a window. There is no
  catch-up later in the window or after a long outage. Start pushes expire after
  at most 60 seconds; updates expire by the configured end.
- An ambiguous APNs result is not retried, because it may already have started an
  activity. Logs distinguish sent, rejected and unknown outcomes.
- Missing spring-forward times are skipped. Repeated autumn times use the first
  occurrence. A clock change never extends an activity beyond two elapsed hours.
- Apple delivery, device connectivity, Live Activity permissions, and update-token
  registration still govern whether an activity appears and remains current.

## Verification and rollout

Deploy the API before shipping the client. Existing APNs credentials and the
Live Activity topic are reused; no extra scheduled job service is required.
Debug iOS builds register sandbox tokens and Release builds register production
tokens. The maximum is centralized on the server and returned to the app.

Automated coverage includes validation, ownership, durable writes, revisions,
BST transitions, restart deduplication, manual precedence, stale feeds, late update
tokens, deletion and end pushes during feed outages. iOS tests cover matching wire
formats, confirmed-only persistence, save failures and deletion without push setup.

Before release, use a signed iPhone to schedule a window a few minutes ahead.
Verify start/update/end with the app backgrounded and terminated, token rotation,
manual Track priority, swipe dismissal, and disabled permissions. Repeat with
production APNs in TestFlight. Review the editor's light/dark/large-text previews
and VoiceOver labels on device. Simulator compilation alone does not verify APNs.


## National Rail schedules

National Rail station names and CRS codes are resolved from the bundled station
catalogue; client-provided station names and stop codes are never trusted. The
operator ID and display name are stored with the board. Directions are Any,
Northbound, Southbound, Eastbound or Westbound. Operator choices come from live
boards or a planned route; missing service information leaves an editable draft.
London Overground and Elizabeth line retain their dedicated TfL boards. Thameslink
uses its dedicated source at interchanges and the operator feed at rail-only stops.

The initial rail board uses the same projection and disruption headlines as manual
tracking, including cancelled trains, delays and platform visibility. Stale data
(older than 90 seconds), empty operator boards and unresolved selected directions
do not trigger a start; the scheduler retries within its existing start grace
period. Requests are shared by station within a scheduler pass, capped at 40 station
requests per pass, and use the shared resource cache. Once the app registers the
update token, the existing National Rail notifier supplies subsequent updates.
Scheduled ends and deletions still run during rail-feed outages.

Deploy this server support before releasing the client. A signed-device APNs check
must verify a National Rail start with operator branding, subsequent updates and
its scheduled end, including with the app terminated. Local automated tests verify
the payloads and state transitions but cannot confirm delivery to a physical device.


## Troubleshooting scheduled Live Activities

In the iOS app, open **Profile → Share diagnostics**, then share the prepared JSON
report. The app keeps the latest 2,000 events from the past seven days across
launches. Reports contain software versions, permissions, the installation ID,
activity IDs, lifecycle observations, content timestamps, and registration HTTP
results or error domain/code. Push addresses, schedule credentials, request bodies,
and raw error descriptions are not recorded. The history is stored locally outside
backups; sharing is user initiated. Events are written on a serial background queue.
No client can log while iOS has suspended it, so gaps must be interpreted alongside
server events. An observed update is not proof of the exact time a push arrived.

Server events use `activityId` and `installId` to correlate starts, registrations,
update outcomes and ends. `scheduled_update_registration_missing` warns after two
minutes without a registered update address, once per occurrence per process.
Registration evidence is persisted with the occurrence to prevent false alarms
after a successfully completed activity is removed. Warnings can recur after a
server restart for still-missing registrations, and expire a day after the window.
`push_registration_request_result` includes unsuccessful requests and structured
validation error codes. `push_update_outcome` logs outcome changes, including stale
sources, and `push_update_accepted` records successful APNs submissions. Acceptance
by APNs is not a delivery receipt. `scheduled_end_result` records accepted/rejected
end attempts. Start events include the source timestamp and scheduled end time.

After rollout, test on a signed phone with the app backgrounded and terminated:
verify the start, token registration, updates, and scheduled dismissal; then export
the report and match the activity ID to the server log. Server logging requires a
server deployment; client diagnostics require installing the updated app.


### Apple delivery lookup identifiers

Every APNs HTTP attempt now has a fresh UUID `requestId`, also supplied in the
`apns-id` header. `apns_request_result` records the returned `apnsId` and
`apnsUniqueId`, environment, activity ID, event, sequence, priority, expiry,
staleness deadline and elapsed time. Transport failures retain the known IDs in
`apns_request_failed`; a retry against another environment has its own request ID.
Credentials, device addresses and notification bodies are never included.

For a sandbox push, sign in to https://icloud.developer.apple.com/dashboard/notifications,
select the app's bundle ID, open Delivery Log, and use **apnsUniqueId** from the
server event. Apple makes development delivery logs available for seven days.
A normal `apnsId` is not a substitute for a missing `apns-unique-id`. A missing
unique ID remains null; old discarded IDs cannot be reconstructed from the app's
sequence counter. Production does not offer these per-notification delivery logs.
See https://sosumi.ai/documentation/usernotifications/testing-notifications-using-the-push-notification-console.

Priority 10 is reserved for material changes and starts/ends: trains appearing,
disappearing or changing order; platforms or destinations changing; cancellation,
delay, prediction availability, disruption or recovery; and prediction changes of
at least 60 seconds in any displayed row, earlier or later.
Routine refreshes use priority 5: Apple excludes those from the Live Activity
high-priority budget. Sending every 30-second heartbeat with priority 10 would
request roughly 120 budgeted deliveries per hour per board, potentially causing
throttling. Frequent Updates permission raises the allowance; it is not unlimited.
Neither priority guarantees delivery or bypasses connectivity loss. Review delivery
outcomes before changing expiry or escalating heartbeat priority.
