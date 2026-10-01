# Scheduled journeys

Each installation can save up to three journeys. A journey contains ISO weekdays
(Monday = 1), an enabled flag, and one or both morning/afternoon windows. Each
window stores station, line, direction and start/end minutes after midnight.
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
using the existing TfL cache (or the Thameslink board source), persists an
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
