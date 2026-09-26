# TubeTrack API

Server-side transport-data API for TubeTrack UK. It owns the TfL credential,
polls the network-wide live feed, and caches lower-frequency upstream data.

## Required configuration

- `TUBETRACK_UK_TFL_UNIFIED_API_KEY`: TfL Unified API key.
- `PORT`: HTTP port; defaults to `3018`.

Optional polling settings:

- `TUBETRACK_UK_LIVE_POLL_INTERVAL_MS` (default `30000`)
- `TUBETRACK_UK_REQUEST_STAGGER_MS` (default `1000`)
- `TUBETRACK_UK_TFL_TIMEOUT_MS` (default `10000`)
- `TUBETRACK_UK_TFL_MAX_CONCURRENT_REQUESTS` (default `8`)
- `TUBETRACK_UK_LIVE_STALE_AFTER_MS` (default `90000`)
- `TUBETRACK_UK_LIVE_REFRESH_TIMEOUT_MS` (default `120000`; must exceed the
  TfL request timeout)

### Live cache staleness

Each transport mode keeps its last successful arrivals. A failed or timed-out
mode retains its previous data while successful modes publish a new snapshot.
`meta.modeUpdatedAt` gives each mode's last update time and `meta.staleModes`
lists modes older than `TUBETRACK_UK_LIVE_STALE_AFTER_MS` (including modes
that have never loaded). On a line or stop request, `meta.stale` and
`meta.updatedAt` describe the modes in that response; unfiltered requests and
`/healthcheck` describe the whole cache. Clients should degrade stale boards
rather than trust `expectedArrival` values that are already in the past.
Live Activity pushes pause for modes that failed the current refresh or are
stale, while healthy modes continue updating. Each poll attempt is bounded by
`TUBETRACK_UK_LIVE_REFRESH_TIMEOUT_MS`
and each TfL request by `TUBETRACK_UK_TFL_TIMEOUT_MS`; both deadlines settle
the call themselves rather than relying on `fetch` honouring its abort signal
(a stalled response body was observed ignoring abort for hours on
2026-09-21). A timed-out or failed attempt never stops the next one. When all
modes fail, the existing snapshot remains unchanged.

A watchdog independent of the polling loop logs `live_cache_stale` (warn) every
poll interval while the cache is stale, with the age, the current attempt and
the last error, and `live_cache_recovered` (info) when it refreshes again.
`/healthcheck` reports `status: "degraded"` (still HTTP 200 and `ready: true`)
while stale, and `/metrics` exposes `tube_track_live_cache_stale` (0/1) and
`app_check_ok{check="live_cache_fresh"}` alongside
`tube_track_live_cache_age_seconds` for alerting.

Completed refreshes explicitly detach cancellation listeners. Keep this cleanup:
on the production Node 20 runtime, combining every attempt with the long-lived
shutdown signal retained old arrival generations and exhausted the 192 MiB heap.
The regression test runs as part of `npm test`. To inspect its memory samples:

```sh
node --expose-gc --max-old-space-size=192 scripts/check-live-memory.js
```

Run it with the deployed Node version too; newer runtimes can mask the leak.
See [the memory investigation](docs/memory-investigation-2026-09-25.md) for
before/after measurements and rollout checks.

Alert rules live in `observability/prometheus/rules.yml` and are installed on
the monitoring host by a full deployment (`rules/tube-track-api.yml`, reloaded
into Prometheus and delivered by Alertmanager via email). The generic rules
from `server-tooling/monitoring/install-alerting.zsh` (`TargetDown`,
`AppCheckFailing` on `app_check_ok`) apply as well.

## Routes

- `GET /api/v1/live?lineIds=victoria,central`
- `GET /api/v1/arrivals/:stopId`
- `GET /api/v1/arrivals?stopIds=:stopId,:stopId`
- `GET /api/v1/status`
- `GET /api/v1/line-colours`
- `GET /api/v1/planned-works?from=YYYY-MM-DD&to=YYYY-MM-DD`
- `GET /api/v2/planned-works?from=YYYY-MM-DD&to=YYYY-MM-DD`
- `GET /api/v1/arrival-departures/:stopId?lineId=:lineId`
- `GET /api/v1/timetables/:lineId/:stopId`
- `GET /api/v1/stations?query=Waterloo`
- `GET /api/v1/journeys?from=940GZZLUWLO&to=940GZZLUKSX&timeMode=now&accessibility=none`
- `GET /healthcheck`
- `GET /metrics`

The production Caddy route strips the public `/tube-track` prefix before
proxying requests to this service.

## Long-range planned works (v2)

`/api/v1/planned-works` is intentionally unchanged for released clients. It
continues to proxy TfL's dated Unified API response.

`/api/v2/planned-works` adds TfL's six-month planned-track-closures PDF and
returns normalized events plus the PDF's actual published horizon. PDF-only
events are date-precision and provisional. When TfL later publishes an
overlapping Unified API record, the exact API times and structured route data
take precedence while both source records remain identified.

Known PDF-only sections may also be enriched with an ordered NaPTAN route
sequence. This is additive v2 data that lets already-released clients highlight
the affected section instead of falling back to the whole line.

The PDF is fetched at most every 12 hours using ETag/Last-Modified validators.
The parser rejects unexpectedly small schedules or a horizon shorter than 120
days and keeps the last successfully parsed copy on transient failure. See
[the v2 OpenAPI contract](docs/planned-works-v2.openapi.yaml).

Deploy the API before releasing the app version that requests v2. That app
falls back to v1 if v2 is unavailable; older installed apps continue to call
v1 and are unaffected.

## Development

### Live Activity refreshes

Each successful live-data poll considers active departure boards for a push.
Routine snapshots target 30 seconds, or 60 seconds if the user disables frequent
updates, even when the predictions are unchanged. A two-second scheduling
allowance avoids missing a poll because its upstream requests finished slightly
earlier. Keep `TUBETRACK_UK_LIVE_POLL_INTERVAL_MS` at its 30-second default to
support this cadence. Failed TfL polls do not re-label old data as fresh.

Routine snapshots use APNs priority 5; urgent board changes use priority 10.
Apple controls delivery timing, so the send cadence is a target, not a guarantee
that the Lock Screen refreshes within that time.

Development and distributed apps use different APNs environments. The notifier
starts with the configured environment and, only on `BadDeviceToken`, tries the
other Apple endpoint once before retiring the token. Successful routing is saved
per subscription, allowing both builds to coexist. Ended tokens (`Unregistered`)
are removed immediately. Activities whose tokens were already removed must be
stopped and started again after deploying the fix.

See [Apple's Live Activity push guidance](https://sosumi.ai/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

### Running locally

```sh
npm install
npm test
TUBETRACK_UK_TFL_UNIFIED_API_KEY=... npm start
```

Never commit the TfL key or a local `.env` file.

## Line colours for connection pills

`GET /api/v1/line-colours` returns all 20 supported lines: the 11 Tube lines,
DLR, Elizabeth line, London Trams and the six named Overground lines. It uses
TubeTrack UK's display palette, rounded to 8-bit sRGB, and makes no upstream
requests. It is available before the live cache is ready and is cacheable for
one day (`Cache-Control: public, max-age=86400`).

The public URL after deployment is
`https://api.skynolimit.dev/tube-track/api/v1/line-colours`.
See [the OpenAPI contract](docs/line-colours.openapi.yaml) for the full schema.
The response has this shape (the example shows one entry):

```json
{
  "data": [
    {
      "id": "victoria",
      "name": "Victoria",
      "mode": "tube",
      "colour": "#00A1E0",
      "textColour": "#000000"
    }
  ],
  "meta": { "source": "tubetrack", "count": 20 }
}
```

TrainTrack UK should index `data` by `id` and join against station `lineIds`,
arrival `lineId` or journey leg `lines[].id`. IDs use the existing API values,
including `hammersmith-city`, `waterloo-city` and `elizabeth`; `elizabeth-line`
is the mode. Use `colour` for the pill background and `textColour` for its
label. Both are opaque `#RRGGBB` sRGB values; text colours provide at least
4.5:1 contrast against their backgrounds. For an unknown ID, show the line
name using the client's neutral pill style. Re-fetch after the cache expires.

When updating the app's line palette, also update `lib/line-colours.js`.
The deployed API needs only this directory, with no iOS source dependency.

## Journey planning for TubeTrack UK and TrainTrack UK

Requires Node.js 20.3 or later for [combined cancellation signals](https://nodejs.org/api/globals.html#static-method-abortsignalanysignals).

The existing public base URL is `https://api.skynolimit.dev/tube-track`.
The new routes become available after deploying this service. Clients never
receive or supply the TfL credential. This is an integration for our own apps,
with the same access model as the existing read-only endpoints; there is no
developer signup, third-party key issuance or public service guarantee.

See [the OpenAPI contract](docs/journeys.openapi.yaml) for request/response
schemas, error codes and examples. Both routes return `{data, meta}`.

1. Search `/api/v1/stations?query=Paddington` (omit `query` for the catalogue).
2. Submit the returned `id` to `/api/v1/journeys` as `from` or `to`.
   The member NaPTAN IDs in `stopIds` are also accepted. Hub IDs are resolved
   on the server into TfL journey-planner ICS codes; clients must not send hub
   IDs directly to TfL. CRS codes are not accepted by this London-only API.
3. Set `timeMode=now`, or `departAt`/`arriveBy` with an ISO 8601 `time`
   including a UTC offset (URL-encode `+`). Times can be up to 60 days ahead.
4. Optionally set `accessibility=platform` or `train`. Default is `none`.

Scope is Tube, DLR, Elizabeth line, all six Overground lines and trams, with
walking transfers. Bus, rail-replacement bus and National Rail itineraries are
excluded. A valid search can return an empty `journeys` array. That differs
from a 503 provider failure, a 422 unresolved station, or a 429 busy response.
There is no guarantee that TfL supplies three distinct routes or an alternative
avoiding disruption. No in-house routing or artificial delay penalties are used.

Departing searches prioritize estimated arrival including waiting; arrive-by
searches prioritize later departures meeting the deadline. Where available,
one less-disrupted route is retained among up to three distinct choices. The
comparison uses the severity of TfL's attached warnings and independently
checked live/planned line status, not a reliability probability. Alternatives
with incomplete disruption coverage cannot receive the `lessDisrupted` label. Broad station accessibility notices are preserved separately and
are not counted as timing delays. Step-free preferences are sent to TfL, not
inferred from the map; lift/platform notices must remain visible to passengers.
`timing=adjusted` means TfL supplied a time different from its scheduled value;
`estimated` does not assert a live prediction. Returned timestamps are UTC;
display them in Europe/London. Upstream timezone-free timestamps are interpreted
in London, anchored to the request/preceding leg at the autumn clock change.

Every journey and leg now has a `disruption` object (an additive response
change; existing `warnings` remain compatible):

```json
{
  "status": "noIssues",
  "hasDisruption": false,
  "summary": "No disruption reported.",
  "coverage": "complete",
  "issues": [],
  "sources": [
    { "source": "realtime", "status": "available", "checkedAt": "2026-09-17T12:00:00Z" },
    { "source": "plannedWorks", "status": "available", "checkedAt": "2026-09-17T12:00:00Z" }
  ]
}
```

- `majorIssues`: severe delays, closures, suspensions or services not running.
- `minorDelays`: minor delays, reduced service or changed frequency.
- `information`: other travel/accessibility notices, without an assumed delay.
- `noIssues`: no notices reported and all applicable checks succeeded.
- `unknown`: no fresh notice is known, but disruption checks are incomplete;
  `hasDisruption` is `null`, never `false`.

Each issue includes `severity` (`major`, `minor`, `information`), `kind`,
`lineId`, description, source(s), original TfL status code/description, validity
periods, scope and a stale flag. `hasDisruption=true` includes informational
notices; use `status`/`severity` to decide prominence. Repeated descriptions for
the same line are merged across feeds and legs. Original warning severities
remain `severe`/`minor`/`information` for released clients.

Live status is checked for legs departing within 15 minutes, cached for 30
seconds; future legs mark that source `notApplicable` instead of projecting
current incidents into the future. The dated line-status feed covers all London
calendar dates traversed by the journey (including midnight/DST), is cached for
30 seconds for near-term journeys or five minutes for future journeys, and
filters notices by overlap with each leg's actual times.
A `PlannedWork` category or planned-closure status identifies planned works;
the dated feed may also contain timed realtime notices. Undated non-good dated
statuses and unknown severity codes make coverage incomplete. TfL's severity
codes are categories, not an increasing or decreasing severity scale.

Both feed checks run concurrently with a 2.5-second limit within the overall
search deadline. Their failure preserves valid routes and adds an availability
notice. Stale notices may be included with `stale=true`, but never establish an
all-clear or influence the comparison score. `coverage` and per-source status /
`checkedAt` expose these limitations independently of the route's `meta.stale`.
Route cache expiry is capped by disruption-source expiry; failed checks are
retried on a fresh search after at most five seconds.

A notice with `scope=line` reports a problem on a used line; it does not confirm
that this exact section is affected. Station/section matches use TfL stop IDs
and interchange aliases where available. No delay minutes are fabricated and
TfL's journey times are retained. No reported issues is a statement about the
available feeds, not a guarantee about travel conditions. Feed definitions and
status categories come from the [TfL API schema](https://api.tfl.gov.uk/swagger/docs/v1)
and [severity catalogue](https://api.tfl.gov.uk/Line/Meta/Severity).

Journey responses use `Cache-Control: no-store`; apps must respect `expiresAt`,
show stale/expired results explicitly and offer a fresh search. The service
coalesces identical calls and uses a bounded in-memory cache (20 seconds for
now, up to 60 seconds for future searches, capped by TfL's recommendation).
It never serves expired cache entries on failure or already-departed journeys
as new results. The whole search is bounded to 18 seconds (the app timeout is
20 seconds). Cold station lookups have a 2-second limit and fall back to valid
NaPTAN members if resolution is unavailable. The primary planner call has a
12-second limit and may retry a transient timeout/network/502/503/504 failure
once within the same overall deadline. Optional alternatives have a separate
2.5-second limit; failure retains the successful primary result with a notice.
Searches consume at most three planner calls, two station lookups and two disruption-feed calls on a cold cache. At most two distinct searches run concurrently and
journey-related upstream calls are limited to 180/minute per service process.
Scale-out deployments must share or divide this budget. Retry 429 responses
after `Retry-After`. The existing live-feed polling schedule is unchanged; requests share the TfL concurrency gate.

Journey upstream metrics distinguish `journeys:station`, `journeys:primary`,
`journeys:retry`, `journeys:alternative`, `journeys:realtime-status` and
`journeys:planned-works`. Locations are omitted from these metrics. Avoid recording full
journey query strings in reverse-proxy/access logs as well. TfL attribution is
included in responses and must be displayed in consuming apps. TfL's source
licence: https://tfl.gov.uk/corporate/terms-and-conditions/transport-data-service

The station catalogue is generated from the app's reviewed rail graph. After
updating that graph, run `node scripts/build-journey-stations.js` from this API
directory and commit `data/journey-stations.json` with the change. The deployed
service needs only this directory, not the iOS source tree.

## Observability

Prometheus metrics are served from `/metrics`. A Grafana dashboard is stored at
`observability/grafana/dashboards/tfl-upstream-api-calls-dashboard.json` and is
automatically imported into **Dashboards → tube-track-api → TfL Upstream API
calls** by a full deployment with
`/Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh`. Quick deployments
intentionally skip Prometheus and Grafana configuration.

The **App audience and usage** dashboard is provisioned from
`observability/grafana/dashboards/app-audience-usage-dashboard.json` by the same
full deployment. Its headline is distinct iOS app installations that reported
an `app_open` event during the current Europe/London calendar day. The 7- and
30-day values count distinct installations over those calendar-day windows; they
must not be calculated by adding daily values. Widget and watch installations
are counted separately when they make a successful API request. An installation
is not a person, and an offline app open cannot be counted until it is reported.

New clients send `X-TubeTrack-Install` (an app-generated UUID),
`X-TubeTrack-Surface` (`ios_app`, `widget`, or `watch`) and
`X-TubeTrack-App-Version` on first-party API requests. The iOS app sends a
small `POST /api/v1/usage` body (`app_open` or `feature_open`, with a fixed
feature name) on foreground entry or a tab/game visit. This event is best effort
and never blocks app use. Older app versions remain supported; their requests
appear as `unknown` and cannot contribute to distinct-install counts. The
installation ID is accepted only as an observation key, not authentication.

The API keeps only salted hashes of installation IDs, deduplicated by London
day and client surface. The store is written with mode 0600 under
`TUBETRACK_UK_DATA_DIR` or the same default durable directory as push tokens,
outside the deployed project tree. It retains 45 calendar days and supports a
single API instance; use a shared store before scaling the service horizontally.
Prometheus receives only aggregate counts and bounded route/surface/version
labels, never installation IDs. Review the privacy notice and App Store privacy
answers before releasing a build that sends usage events.

## London Cable Car

Independent `/api/v1/cable-car/network`, `/status`, `/hours` and `/planned-works`
resources reuse the TfL client and resource cache without changing rail or River
Bus contracts. See [Cable Car integration](docs/cable-car.md) for recorded API
findings, cache/freshness semantics and the reviewed opening-hours policy. Deploy
these routes before releasing the cable-car client. Renew the schedule review
before 25 October 2026; repeated fetches never extend its validity.

## Estimated River Bus positions

`GET /api/v1/river/boats` shares the existing 30-second river prediction cache and
returns estimated boat positions, learned from pier arrival times. In-process
history is shared across clients; first-load estimates use unambiguous preceding
legs and learned travel durations. Brief feed gaps retain positions only within
their original 90-second observation window and next-pier ETA. Deploy this endpoint
to enable immediate shared estimates in the updated iOS app; older APIs retain
the transition-only fallback. See [River Bus integration](docs/river-bus.md) for
the contract, assumptions, recorded replay and regression coverage.
