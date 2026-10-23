# Complete-route journey tracking

The Journeys tab can start a selected itinerary or save a one-off/weekly complete
route. Existing `/api/v1/scheduled-journeys` board schedules and board Live
Activities are unchanged. Deploy this API before releasing the new iOS app.

## Search and route selection

`POST /api/v2/journey-searches` accepts `via`, a comma-separated list of up to four
ordered catalogue station IDs. Aliases resolve to hubs; repeated hubs and endpoints
are rejected. Searches run successive segments forward for depart-at and backward
for arrive-by. Each interchange includes five minutes, explicitly disclosed in the
result; existing provider walking/access allowances remain in the itinerary.

Each segment retains distinct suggested routes. For pairs of DLR stations, an
additional bounded TfL mode=dlr query uses their DLR stop identifiers rather than
an interchange's ICS identifier. This prevents the nominal Canary Wharf waypoint
from becoming a different station plus a walk. Up to three catchable combinations
are retained, including a fewer-change option. Search results remain bounded
suggestions, not exhaustive optimal routing. Source failure never fabricates a DLR
service. Via jobs share existing cancellation, admission, cache and lookup budgets.

## API

All `/api/v2/tracked-journeys` endpoints require `X-TubeTrack-Install` and the
installation's existing random `X-TubeTrack-Schedule-Key`. Responses are
`{data: {active, schedules, revision}}`, with no push tokens or device credentials.
The secret's SHA-256 hash is stored; mutations repeat ownership checks inside the
serial transaction. This is installation ownership, not account authentication.

- `GET /`: current session and saved complete-route schedules.
- `POST /start`: `{searchID, journeyID}` selects a server-held result. Optional
  `replaceID, replaceRevision` explicitly replace the reviewed active session in
  one transaction, after validating the new selection. A failed selection keeps
  the original journey. Starts are limited to departures within two hours.
- `PUT /progress`: `{id, revision, legIndex, phase, boardedID?}` changes progress.
  Phase is waiting/onboard/complete. Revisions prevent late corrections overwriting
  newer progress. An optional boardedID must belong to a fresh verified board.
- `PUT /token`: `{id, token, environment}` registers/rotates that session's update
  address. An in-flight board refresh preserves the latest registered address.
- `PUT /device`: `{token, environment, activitiesEnabled}` registers the separate
  `JourneyActivityAttributes` push-to-start address and permission state.
- `POST /schedules`: `{searchID, journeyID, date?, days, minute}` saves the whole
  selected route. `date` is a one-off ISO timestamp; otherwise ISO weekdays and
  minutes after midnight refer to Europe/London. Up to three route schedules are
  permitted, separately from legacy board schedules. Delete an old route to edit
  its schedule. Repeating routes preserve access preferences.
- `DELETE /schedules/:id`: removes a schedule and ends its active occurrence.

Only supported rail boards are accepted; replacement-bus legs are explicitly
rejected. Location coordinates are never accepted or stored by these endpoints.

## Predictions and progress

The app evaluates accurate, recent location fixes on-device, with sustained
movement away from the boarding station towards the next stop and a stationary
dwell at an interchange. A coarse fix, GPS jump or stale location cannot advance
progress. The user opts in per journey, can turn following off, and can correct the
leg or confirm boarding. A manual correction suppresses automatic transitions for
90 seconds. These heuristics do not prove which train the user is on.

National Rail boarding selection retains the exact departure-service reference.
A matching service-detail call supplies the onward station's expected arrival;
a cancelled call yields an unknown connection. TfL vehicle IDs, when present and
unique, match predictions at the alighting stop. Otherwise the arrival estimate
uses the confirmed boarding time plus the planned leg duration and is labelled as
an estimate. Overdue arrival estimates become unknown rather than auto-completing.

Final arrival chains only catchable, non-cancelled onward services, with walking
and interchange allowances. Fresh boards are required for live predictions;
unavailable/stale boards can retain a still-catchable timetable estimate, clearly
labelled. A missed timetable without a verified replacement yields an unknown
connection. Frequency services outside the prediction horizon cannot provide a
confirmed final ETA. Route changes require explicit user acceptance.

The full-screen view shows the current/next board, next-stop and final ETAs,
service details, route timeline and manual controls. The Live Activity uses the
same projection, with explicit stale dates, Lock Screen/Dynamic Island layouts
and a session-specific deep link. With the app suspended, APNs continues service
updates using the last reported leg. Location updates can move that leg when the
user has enabled a background location session. Remote Live Activity start alone
does not start location tracking; open the app to enable it.

## Persistence and lifecycle

`tracked-journeys.json` lives in the existing private application data directory,
outside deployed source, with atomic serialized replacement and mode 0600.
Back it up with the existing push/schedule files. An unreadable file disables only
complete-route tracking; it is preserved for recovery. Multiple API writers are
unsupported without a transactional shared datastore.

The scheduler ticks every 30 seconds. It re-resolves a due route with fresh services
and requires the same sequence of boarding/alighting stops and lines/operators.
Unavailable routes leave an explanatory message on the schedule. The scheduler
never silently changes route. At most two scheduled searches run concurrently;
these searches do not block updates for active journeys.

Occurrence claims are durable before APNs start; ambiguous starts are not retried.
An existing active route suppresses a scheduled occurrence. A route can start only
within three minutes of its scheduled time; long outages have no late catch-up.
One-off schedules become inactive after starting or failing. Missing spring-forward
wall times are skipped; repeated autumn times use the first occurrence. Claims
are pruned after eight days when the next occurrence is claimed.

Sessions have a bounded end time (arrival plus one hour, maximum seven hours).
End notifications retry independently of departure-source outages, for up to a
day. Ending/replacing a route removes active state after acknowledgement; the app
also ends its local activity. Old activities are never recreated just because a
user dismissed them. Legacy board and journey activities may coexist.

No raw GPS history is retained. Active itineraries and progress exist until
completion, with failed end-delivery data retained temporarily. Saved templates
remain until deleted. The iOS cache retains the last confirmed response for offline
viewing. Progress edits need connectivity; failures preserve confirmed progress.

## Operations and release checks

This runs in the existing tube-track API service; no new daemon, operational alert,
recovery permission or Prometheus rule is introduced. Existing service monitoring
still applies. APNs request logs contain activity IDs and delivery outcomes, never
push addresses or schedule credentials. A successful APNs submission is not proof
of device delivery. Do not rely on local simulator tests to establish delivery.

Verify before release on a signed iPhone and TestFlight:

1. Clock House → Lewisham → Canary Wharf → Stratford: select the National Rail +
   DLR + DLR option, start, confirm a train, and correct each leg. Check the Canary
   Wharf board is prominent while travelling from Lewisham.
2. Enable location in the foreground, lock the phone and travel. Verify progress,
   privacy indicator, battery impact and location stopping on completion. Test
   denied/reduced accuracy, tunnels, parallel tracks and reopening after termination.
3. Schedule a one-off and weekly route. Verify start/update/end while backgrounded,
   token rotation, permission changes, dismissal, a failed source and an unavailable
   route. Scheduled starts require opening the app for location following.
4. Check Lock Screen and all Dynamic Island presentations, stale state, deep links,
   simultaneous existing board tracking and end delivery after a transient outage.
5. Confirm light/dark appearance, large Dynamic Type and VoiceOver reading order.
   Use Instruments Energy Log and Time Profiler for background location and the
   main-thread projection/view invalidations. Network refreshes are bounded at
   30 seconds; location fixes do not force immediate full-screen redraws.

Automated tests cover ordered via routing, connection feasibility, cancellation,
DST, ownership, durable claims, revision conflicts, replacement failure, token
registration races, end retries, shared decoding and location evidence. Simulator
rendering covers light, dark and accessibility text sizes.
