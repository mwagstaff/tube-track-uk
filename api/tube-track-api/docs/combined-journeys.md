# Combined journey planning

New clients use `/api/v2/journey-searches`. Existing `/api/v1/journeys`, scheduled
journeys, departure boards and their contracts are unchanged. The new API calls
TrainTrack's `/api/v5/journey-planner/search-jobs`; it never calls itself through
TrainTrack's TfL adapter. V5 uses the non-recursive `/api/v2/journey-transfers`
endpoint; older planners continue to call TubeTrack v1 directly.

## Scope

The generated catalogue contains 676 mapped rail stations/hubs. Tube, DLR,
Overground, Elizabeth line, trams, National Rail, walking and official timetable
replacement buses are supported. Ordinary buses, boats and cable car are excluded.
New transport modes need explicit contract, routing and presentation support.

Endpoints and interchange stations are limited to the map. Trains can pass beyond
the map between those stations; off-map interchange alternatives are not searched.
Searches cover a six-hour departure/arrival window, journeys of at most six hours,
and up to five changes. Results disclose these bounds and any exhausted lookup
budget. They are best available options, not a guarantee of a globally optimal
journey across incomplete provider data.

CRS and TfL stop identities stay separate. The departure catalogue's aliases for
Bethnal Green Underground and Southwark are deliberately not treated as the BET
and WAE rail stations. Reviewed Waterloo East/Southwark walking access uses the
railway station allowance. Dynamic TfL links have no fabricated timetable fallback;
only genuine railway fixed links retain their source-backed transfer allowance.

Regenerate after map changes (from this API directory):

```sh
node scripts/build-combined-stations.js /path/to/train-track-uk
```

Commit the matching generated catalogues in both projects. The deployed services
are self-contained and do not read the adjacent repository.

## HTTP lifecycle

1. `POST /api/v2/journey-searches?from=nr:KTH&to=940GZZLUOXC&timeMode=now&accessibility=none`
2. Poll `GET /api/v2/journey-searches/{id}` at `pollAfterMs` (currently 1000).
3. `DELETE /api/v2/journey-searches/{id}` releases a cancelled search.

All responses are `{data: ...}` with `Cache-Control: no-store`. Submission and
polling return `{id,status,pollAfterMs,result?,error?}`. A completed `result` has the
existing `{data: JourneyPlan, meta}` envelope, with additional leg timing/service
metadata. `departAt` and `arriveBy` require an ISO timestamp with UTC offset.
Station IDs must come from the map catalogue; free-text and arbitrary CRS inputs
are not accepted. Shared station members resolve to their canonical hub.

Results preserve expected and scheduled times, source timestamps and explicit
expiry. Cancelled or chronologically impossible itineraries are excluded whole.
Official replacement buses use `mode=replacement-bus`. Allowance-only steps use
`mode=transfer`; they are not represented as invented train services. National Rail
legs have `timing=live` only when both live endpoints are confirmed, otherwise
`scheduled` with a warning. TfL keeps its existing `estimated`/`adjusted` distinction.

The adapter selects up to three distinct routes, prioritising arrival time (or
latest feasible departure for arrive-by), preserving useful less-disrupted and
fewer-change choices. TfL operator/line status and dated disruption checks add
notices; broad operator notices do not invent delays or prove a train cancelled.

The app polls a cancellable search, then refreshes while results are visible and
the app is active, no faster than every 30 seconds. Failures back off for 60 seconds.
Previous results remain visible during refresh and show their original expiry.
No background tracking, push notifications or journey monitoring is added.

## Failure and accessibility

Unavailable live rail information retains timetabled routes with warnings.
Outdated timetable datasets still fail the existing freshness gate. When the
combined service is unavailable, TfL-capable endpoints can fall back to the existing
TfL planner with a prominent message that National Rail alternatives were not
checked. No-route, expired search, rate limiting and provider failure remain distinct.

TfL receives the requested step-free preference. National Rail/replacement-bus
accessibility remains explicitly unverified; a TfL preference does not certify
an entire mixed journey. Mixed maps show verified rail/line geometry, omit ambiguous
branches and replacement-bus roads, and retain full textual directions.

## Release and rollback

1. Deploy TubeTrack's API first, including `/api/v2/journey-transfers`.
   `TRAINTRACK_PLANNER_URL` optionally overrides the v5 planner base URL for staging.
2. Deploy TrainTrack's planner worker/service with the transfer optimisations.
   The existing v5 gateway needs no change for this update. For an initial v5
   release, deploy the gateway and matching station catalogue too. V3/v4 keep
   their existing behaviour. `TUBETRACK_TRANSFER_URL` on the planner optionally
   overrides the TubeTrack base URL (ending `/api/v2`).
3. Verify all four endpoint combinations, arrive-by, failure fallback and cancellation.
4. Release the iOS build using the v2 search lifecycle.

No deployment is performed by adding these files. Existing clients continue on
their original namespaces. Roll back the app before removing its new endpoints;
the old APIs remain available throughout. V5 permits one running combined job and
four admitted jobs, with per-client/network limits, a 60-second execution budget
and 90-second queue budget, sharing the existing bounded worker pool. Existing
traffic retains its contracts, but shares physical capacity; monitor queue latency
before increasing rollout traffic. Provider lookups are capped at 24 per search
and 12 seconds of elapsed lookup time (overlapping requests count once), with a bounded
final in-flight request. Half the request capacity and 7.5 seconds are reserved
for verifying result transfers. Independent final checks run at concurrency two;
the graph search still follows dependencies sequentially.

Verification includes full-timetable local routing, deterministic cross-network
delay/cancellation tests, API lifecycle and old-client regressions, iOS selection,
expiry and refresh checks. Run `node --test test/*.test.js` here and the
`planner-combined`, `planner-tube`, `planner-live`, `planner-jobs` and existing
router tests in TrainTrack before release.


### Detecting a stale standalone planner

A healthy `/healthcheck` or v3 status does not prove v5 is running. After deployment,
submit an empty JSON object to the public v5 search-job endpoint. Expect HTTP 422
with `error.code=INVALID_STATION`; this validates the route without queueing work.
An HTML 404 (`Cannot POST /api/v5/journey-planner/search-jobs`) from the authenticated
standalone service means its running process does not expose v5, even if the
public gateway was updated. Check the synchronized files and the process actually
listening on port 3014 on Mini, then restart the managed standalone service through
the deployment tooling. The planner service smoke test now checks this route.
The gateway reports this case as `PLANNER_VERSION_UNAVAILABLE` instead of a generic
invalid-response error. Releasing an app build alone cannot repair it.

## Transfer performance verification

The transfer endpoint skips a secondary least-interchange query only when the
primary response contains a direct vehicle leg with complete, clear disruption
coverage. Other primary alternatives remain available. Disrupted/unknown routes
retain the secondary search. V1 behaviour and its cache remain separate.

V5 caches identical upstream minute queries (departures rounded up, arrival
limits down), including direction and accessibility, and coalesces in-flight
requests. Reuse lasts at most 30 seconds and respects earlier provider expiry.
No route is shifted to another departure time and no stale live result becomes
fresh. Static knowledge that two stations share a line cannot prove that a
particular connection is running or catchable.

The API-only harness is `scripts/combined-planner-bench.js` in TrainTrack's API.
See `docs/combined-planner-performance.md` in that repository for invocation,
assertions, fault injection, measured results and limitations. No app rebuild is
needed for this backend optimisation. Deploy TubeTrack before the planner.

### App-facing ranking regression harness

After creating a TrainTrack benchmark report with leg data, replay it through
TubeTrack's actual v2 HTTP adapter (from this API directory):

```sh
node scripts/check-combined-ranking.js /tmp/combined-performance.json
```

This uses the captured search time and supplied timetable results, so it needs
no app, credentials or fresh upstream calls. It asserts that the first labelled
choice has the earliest arrival (or latest departure for arrive-by) among all
eligible supplied journeys. It also prints departure, arrival and waiting time.
The replay isolates ranking; it does not revalidate live disruption feeds.

On 9 October this reproduced a sorting defect: duplicate removal preserved the
best train for each route but used insertion positions from later trains. It
promoted 13:29–15:18 above 12:10–13:44. Forward, first-occurrence deduplication
now preserves time ranking. The screenshot's 94-minute wait becomes 15 minutes
for that 11:55 search. Deploy the TubeTrack API for this correction; no planner,
gateway or iOS change is required specifically for the ranking fix.

## Operator branding and near-term suggestions

V5 rail legs include optional `operatorBranding` (name and colour) from TrainTrack's
shared `operator-branding.json` catalogue, already exposed publicly through its
`/api/v2/config` endpoint. TubeTrack forwards this as `operatorCode` and `colour`
on journey lines. Older responses and unknown operators remain valid with neutral
styling. The app uses contrasting text on coloured operator pills and formats
journey/leg durations in hours and minutes.

Departure searches keep candidates leaving within 30 minutes of the later of
request time and current time, when any such candidates exist. This applies to
fewer-change alternatives too. If none depart within 30 minutes, later candidates
remain eligible within the existing search bounds. Arrive-by selection is unchanged.
The ranking replay harness now checks every suggested route against this window.
Deploy the TrainTrack planner, TubeTrack API and rebuilt iOS app for this update;
the existing TrainTrack gateway/config endpoint needs no changes.
