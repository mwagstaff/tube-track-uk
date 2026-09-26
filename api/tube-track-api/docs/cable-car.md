# London Cable Car

## Verified API behaviour (25 September 2026)

- Mode `cable-car`, line `london-cable-car`, current public name London Cable Car.
- Terminals: `940GZZALGWP` (Greenwich Peninsula, 51.499573 / 0.008340) and
  `940GZZALRDK` (Royal Docks, 51.507732 / 0.017648).
- Route sequence `stations` lists nearby rail interchanges; use the actual
  terminal StopPoints, not `HUBNGW`/`HUBRVC`, for cable-car markers.
- Inbound/outbound `lineStrings` provide the direct cableway geometry.
- Current status returned severity 10 / Good Service overnight. It does not
  establish whether passenger service is open.
- The date-range status query succeeds; the sampled range contained only Good
  Service without validity periods. This is not a guarantee of future coverage.
- `/Disruption` and `/Arrivals` returned empty arrays. Detailed line status is
  the operational source; do not infer service availability from empty arrays.
- The timetable has first/last journeys matching the current public hours:
  Mon–Thu 08:00–21:00, Fri 09:00–22:00, Sat 09:00–23:00, Sun 09:00–21:00.
  Intermediate 5/10-minute journey entries are synthetic and are not cabin
  countdowns. StopPoint seasonal hours and some ticketing pages are older and
  conflict with the current main TfL page.
- The timetable labels Good Friday with Saturday. The public page groups bank
  holidays with Sunday. Holiday exceptions must be reviewed explicitly.
- Initial Python requests returned 403; curl with the application user-agent
  succeeded without credentials. Production still uses the existing keyed
  TfLClient. No credentials or special push configuration are added.

Recorded, unmodified discovery responses are in `test/fixtures/cable-car/`.
Synthetic disruption scenarios in tests are explicitly constructed; no real
active suspension or maintenance event was observed during discovery.

## Endpoints

All use the existing `{ data, meta: { updatedAt, cached, stale } } envelope.
They are independent of rail polling and preserve the existing rail contracts.

| Endpoint | Contents | Server cache |
| --- | --- | --- |
| `/api/v1/cable-car/network` | Two terminals and geographic route | 24 hours |
| `/api/v1/cable-car/status` | TfL severity, description, reason, validity periods | 60 seconds |
| `/api/v1/cable-car/hours` | Reviewed timetable hours and dated exceptions | 6 hours |
| `/api/v1/cable-car/planned-works?from=YYYY-MM-DD&to=YYYY-MM-DD` | Dated service changes and undated-report count | 10 minutes |

Future ranges are bounded to 62 days. Clients retain the requested range, source
age and undated-report warning separately from the rail six-month PDF coverage.
Unknown severities survive normalization. Undated future notices cannot close
the map. Invalid upstream responses return 503 or stale cached data with its
original timestamp, never fabricated Good Service.

## Maintaining hours

Canonical source: https://tfl.gov.uk/modes/london-cable-car/opening-hours-frequency

`data/cable-car-hours.json` is the central review policy. `/hours` reads the
structured TfL timetable and checks its first/last journeys against that policy.
An unexpected change sets `isVerified: false`, invalidating older cached hours
until review. A transient upstream failure may reuse unexpired reviewed hours.
The current review is valid
**25 September through 24 October 2026 inclusive**. Re-fetching it never extends
that expiry. There are no England/Wales bank holidays in this review interval.

Before extending the validity:

1. Check the main TfL operating-hours page, timetable and exceptional closures.
2. Update weekly minute values (Foundation weekdays: Sunday 1 to Saturday 7),
   England/Wales `bankHolidays`, and date-keyed `exceptions` for the full interval.
   Holiday dates use Sunday hours unless overridden. A closed-day exception is
   `{ "opens": null, "closes": null }`; special hours use minutes after midnight.
3. Update `reviewedOn`, `validFrom` and `validThrough`. Avoid claiming seasonal or
   Christmas dates before their arrangements are known.
4. Copy the policy into `ios/TubeTrackUK/Resources/CableCarHours.json` for the next
   app release. The API test catches bundle drift. Existing apps receive revised
   policies from the server without needing an app update.
5. Redeploy the API and rerun its tests. Review any discovered changes before
   silently adopting a new timetable.

After expiry, the app stops asserting scheduled open/closed state, retains
available live notices, and says opening hours are unavailable. All calendar
calculations use Europe/London, independent of the device time zone.

## App behaviour

The layer defaults to visible, with a remembered switch in Profile → Preferences. Route/terminal selection, search and
terminal favourites work on both maps; searching reveals a hidden layer.
Terminal IDs remain separate from station hubs and River Bus piers. Selecting a
terminal shows a dashed walking *connection*, not turn-by-turn geometry. The
details sheet opens actual walking directions in Apple Maps.

The route stays visible when closed, with a neutral colour and text badge.
Routine scheduled closure is excluded from issue counts. Operational closure
comes only from verified cable-car severity codes or a current dated closure.
Partial closures/access restrictions remain warnings. No weather inference,
departure countdown, moving cabin, journey-planning or widget changes are added.

Current status is refreshed every minute while the active map needs the layer.
Requests cancel on inactivity/offline/hiding the layer. A lightweight local clock
re-evaluates boundaries; observable presentation only changes when its resolved
value changes, so it does not redraw static artwork every second. Live data is
unconfirmed after 120 seconds, and future reports after 30 minutes. Offline
hours remain usable within their review interval; old live reports are labelled.

Future date/time selection shares the map's AM/PM/Overnight controls. Only
closures covering every selected window produce a full Closed badge; partial
windows say Closure in selected times and retain exact intervals in details.
Stale planned information is disclosed rather than presented as confirmed.

## Release checks

- Deploy `/api/v1/cable-car/*` before releasing the client.
- Verify an actual dated disruption when TfL publishes one; fixtures alone cannot
  establish how far ahead the live feed will cover maintenance.
- Recheck the hours policy before 25 October 2026.
- Review both maps with River Bus on, large text, Dark Mode and VoiceOver.
- On device, profile pan/zoom with Instruments: the cable layer uses the existing
  retained canvas. Invalidations should be limited to camera buffer refresh,
  selection, appearance/size changes and actual status changes.

Data provided by Transport for London. TubeTrack UK is an independent app.
