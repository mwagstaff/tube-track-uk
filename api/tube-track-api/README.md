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

The PDF is fetched at most every 12 hours using ETag/Last-Modified validators.
The parser rejects unexpectedly small schedules or a horizon shorter than 120
days and keeps the last successfully parsed copy on transient failure. See
[the v2 OpenAPI contract](docs/planned-works-v2.openapi.yaml).

Deploy the API before releasing the app version that requests v2. That app
falls back to v1 if v2 is unavailable; older installed apps continue to call
v1 and are unaffected.

## Development

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
