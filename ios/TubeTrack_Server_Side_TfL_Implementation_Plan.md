# TubeTrack UK — Server-Side TfL Data Implementation Plan

## 1. Objective and delivery order

Move TfL Unified API access from the iOS app into a standalone Node.js
service named `tube-track-api`.

The delivery order is deliberately server-first:

1. Build and deploy a working proof of concept (POC) on the Hetzner `sky`
   host.
2. Verify upstream polling, cache correctness, public routing, reliability,
   observability and memory usage in that environment.
3. Only after the POC is accepted, update the iOS app to use the new API.

No iOS networking changes are part of the initial POC.

Goals:

- Centralise TfL API usage and credentials.
- Keep the TfL key out of the app and out of source control.
- Stay comfortably within TfL's 500 requests/minute registered-user limit.
- Cache live arrivals and supporting data in memory.
- Return compact, normalised responses to reduce device bandwidth.
- Support all current TubeTrack UK modes and features, including:
  - London Underground;
  - DLR;
  - London Overground services;
  - London Trams;
  - the Elizabeth line;
  - station departure boards;
  - live train markers;
  - current status and disruptions; and
  - future engineering works.
- Make the iOS app dependent only on TubeTrack backend APIs after migration.

## 2. Service architecture

`tube-track-api` will be a standalone, single-process Node.js service in:

```text
/Users/mwagstaff/dev/tube-track-uk/api/tube-track-api
```

It will follow the existing `train-track-api` deployment conventions:

- an `index.js` entry point and `npm start` script;
- `PORT` supplied through the environment;
- `GET /healthcheck` for deployment and readiness checks;
- `GET /metrics` for Prometheus metrics;
- versioned application routes below `/api/v1`;
- one systemd user service managed by `node_project.zsh`;
- structured stdout/stderr logs managed by the deployment tooling; and
- Caddy path-prefix routing beneath `https://api.skynolimit.dev`.

The proposed dedicated port is `3018`. It is currently unused in the
server-tooling project registry and on `sky`.

Run one cache-owning process for the POC. Multiple Node workers would each
hold a complete copy of the caches and are unnecessary at the expected load.

## 3. TfL authentication

The TfL Unified API key will be available only through this environment
variable:

```text
TUBETRACK_UK_TFL_UNIFIED_API_KEY
```

The value is stored in Bitwarden. Its Bitwarden item must include
`tube-track-api` in the configured `Apps` field so that
`deploy/node_project.zsh` selects it for this project. A full deployment must
use `--bw` (or `--force-bitwarden-sync` when a vault refresh is required).
The deployment helper will write the matching secret to its protected remote
environment file and source it from the generated service wrapper.

The service must:

- fail startup/readiness clearly if the variable is absent;
- send the key to TfL as the server-side API credential;
- never return or log the key; and
- never copy the secret into a project `.env` file or committed configuration.

## 4. TfL data sources

### Live arrivals

Poll all five modes every 30 seconds:

```text
GET /Mode/tube/Arrivals?count=-1
GET /Mode/dlr/Arrivals?count=-1
GET /Mode/overground/Arrivals?count=-1
GET /Mode/tram/Arrivals?count=-1
GET /Mode/elizabeth-line/Arrivals?count=-1
```

Stagger the five requests over each refresh cycle and prevent overlapping
cycles.

Use the following fields for departure boards and train modelling:

- `id`
- `vehicleId`
- `naptanId`
- `stationName`
- `lineId`
- `platformName`
- `direction`
- `destinationNaptanId`
- `destinationName`
- `timeToStation`
- `expectedArrival`
- `currentLocation`
- `towards`
- `timestamp`

### Route topology

Fetch both directions for every supported line:

```text
GET /Line/{lineId}/Route/Sequence/{direction}
```

Refresh at startup and daily. Stagger the startup requests rather than
issuing the roughly 40 route calls simultaneously. Keep the last successful
topology if a refresh is incomplete.

Use topology to resolve previous/next stations and interpolate train
positions on the schematic map.

### Current status

Poll every 30–60 seconds, explicitly including the Elizabeth line mode:

```text
GET /Line/Mode/tube,dlr,elizabeth-line,overground,tram/Status?detail=true
```

Use this data for current line status and disruption information.

### Future engineering works

Query all supported line IDs:

```text
GET /Line/{lineIds}/Status/{startDate}/to/{endDate}?detail=true
```

Maintain a rolling 60-day cache, refreshed every 30–60 minutes. Preserve the
last successful cache if TfL is unavailable.

## 5. In-memory cache design

Maintain four independently replaceable caches:

- `LiveCache`
  - normalised arrival records;
  - `arrivalsByStop`; and
  - `trainsByVehicleId`.
- `NetworkCache`
  - route sequences;
  - stations; and
  - line metadata.
- `StatusCache`
  - `statusByLine`; and
  - current disruptions.
- `PlannedWorksCache`
  - upcoming engineering works.

Indexes must reference the same normalised records rather than clone them.
Build each new cache generation off to the side, validate it, then replace
the active reference atomically. Discard raw TfL response strings, parsed raw
objects and the previous generation immediately after a successful swap.

Do not retain historical live-arrival generations in memory. Redis is not
required for the POC.

## 6. Train position model

For each resolved train, expose:

- `vehicleId`
- `lineId`
- `direction`
- `destination`
- `previousStop`
- `nextStop`
- `timeToNextStop`
- interpolation progress; and
- `lastUpdated`

Infer marker positions between adjacent stations using route topology and
successive prediction updates. Preserve the existing special handling needed
for DLR predictions without stable vehicle IDs and for branched Tram routes.
The client will continue to animate smoothly between backend snapshots after
the later iOS migration.

## 7. API contract and public routing

The service will expose versioned routes internally:

```text
GET /api/v1/live
GET /api/v1/stations/{stopId}/departures
GET /api/v1/trains
GET /api/v1/status
GET /api/v1/planned-works
```

It will also expose:

```text
GET /healthcheck
GET /metrics
```

Caddy will strip the `/tube-track` prefix before proxying to the service.
The corresponding public URLs will therefore be:

```text
https://api.skynolimit.dev/tube-track/api/v1/live
https://api.skynolimit.dev/tube-track/api/v1/stations/{stopId}/departures
https://api.skynolimit.dev/tube-track/api/v1/trains
https://api.skynolimit.dev/tube-track/api/v1/status
https://api.skynolimit.dev/tube-track/api/v1/planned-works
https://api.skynolimit.dev/tube-track/healthcheck
```

Return compact, normalised objects rather than raw TfL responses. Include
cache timestamps/ages and an explicit stale indicator where relevant so the
client can distinguish fresh, stale and unavailable data.

## 8. Polling and expected upstream load

| Data | Frequency | Approximate requests/minute |
|---|---:|---:|
| Live arrivals, five modes | 30 seconds | 10 |
| Current status | 30–60 seconds | 1–2 |
| Planned works | 30–60 minutes | negligible average |
| Route topology | daily | negligible average; stagger at startup |

Expected sustained upstream load is approximately 11–12 TfL requests per
minute. Retries must use exponential backoff with jitter and must not create
overlapping poll cycles.

## 9. Deployment-tooling changes

### Project registry

Add a `tube-track-api` entry to:

```text
/Users/mwagstaff/dev/server-tooling/deploy/config/node_projects.json
```

Planned values:

```json
{
  "name": "tube-track-api",
  "path": "/Users/mwagstaff/dev/tube-track-uk/api/tube-track-api",
  "start_command": "npm start",
  "startup_port": 3018,
  "metrics_port": 3018,
  "healthcheck_path": "/healthcheck",
  "static_env": {
    "PORT": "3018",
    "NODE_OPTIONS": "--max-old-space-size=192"
  }
}
```

With the existing defaults this will deploy to `~/dev/tube-track-api`, create
the `com.tube-track-api.api` systemd user service, verify `/healthcheck`, and
configure a Prometheus scrape target for `/metrics`. No functional change to
`deploy/node_project.zsh` is required for the POC.

The initial full deployment command will be run from the server-tooling
repository:

```text
./deploy/node_project.zsh tube-track-api sky --bw
```

Quick deployments must only be used after the first full deployment and after
the remote secret file exists. Use a full `--bw` deployment whenever the TfL
credential changes.

### Caddy routing

Update:

```text
/Users/mwagstaff/dev/server-tooling/caddy/setup-caddy-cloudflare-tunnel.zsh
```

Add this path handler next to the existing TrainTrack routes and before the
fallback handler:

```caddyfile
handle_path /tube-track* {
  reverse_proxy http://127.0.0.1:3018 {
    header_up Host 127.0.0.1
    header_up X-Forwarded-Host {host}
    header_up X-Forwarded-Proto https
  }
}
```

`handle_path` removes `/tube-track`, so a public request for
`/tube-track/api/v1/live` reaches the service as `/api/v1/live`.

No Cloudflare hostname or tunnel-ingress change is required. The existing
`api.skynolimit.dev` ingress already sends the complete hostname to Caddy on
port 4080. Apply the updated Caddy configuration with:

```text
./caddy/setup-caddy-cloudflare-tunnel.zsh sky
```

Validate the generated Caddy configuration before or as part of restarting
Caddy, then verify that the existing TrainTrack and other path routes still
work as well as the new TubeTrack route.

## 10. Reliability and observability

- Apply upstream request timeouts.
- Retry transient failures with exponential backoff and jitter.
- Prevent overlapping polling jobs.
- Keep serving the last successful cache during TfL failures.
- Expose cache readiness, age and stale state from `/healthcheck` without
  exposing credentials or raw payloads.
- Emit structured logs for refresh success/failure, duration, response size,
  record count and cache age.
- Export Prometheus metrics for:
  - TfL request count, duration and status by endpoint/mode;
  - cache item count, age, refresh duration and refresh failures;
  - stale-cache serving;
  - inbound request count, duration and status; and
  - default Node.js process/runtime metrics.
- Handle shutdown signals by stopping new polls, cancelling in-flight work
  where safe, and closing the HTTP server cleanly.

## 11. Memory budget

Measurements taken on 2 September 2026 found approximately 9,000 live
predictions across the five modes and about 5.1 MiB of uncompressed live JSON.
On the same Node 20 runtime used by `sky`, the live-cache benchmark used about
15 MiB of heap in steady state and about 22 MiB during atomic replacement;
the whole benchmark process peaked at approximately 103 MiB RSS.

Plan for one production process as follows:

- expected steady RSS: 110–160 MiB;
- expected refresh/traffic peak: below 200 MiB;
- capacity allowance: 256 MiB; and
- initial V8 old-space limit: 192 MiB via `NODE_OPTIONS`.

Alert if the service sustains more than 200 MiB RSS or the host has less than
768 MiB available memory. Revisit a systemd-level `MemoryHigh`/`MemoryMax`
configuration after the POC soak test; adding configurable cgroup limits to
`node_project.zsh` is optional follow-up tooling work, not a prerequisite for
the first deployment.

## 12. Server-first implementation and verification sequence

### Phase A: initial deployed POC

Keep the first deployment deliberately narrow while proving the entire path
from TfL to the public TubeTrack endpoint:

1. Scaffold `api/tube-track-api` with its package scripts, HTTP server,
   configuration validation, healthcheck, metrics and tests.
2. Implement the TfL client using
   `TUBETRACK_UK_TFL_UNIFIED_API_KEY`, request timeouts and safe logging.
3. Implement all five live-mode pollers and atomic `LiveCache` replacement.
4. Implement `GET /api/v1/live` with a compact, documented response schema.
5. Add the `node_projects.json` entry and Caddy route described above.
6. Run the service test suite locally without using production credentials in
   committed files.
7. Perform a full `--bw` deployment to `sky` and verify the systemd service,
   direct healthcheck and Prometheus target.
8. Apply Caddy configuration and verify
   `https://api.skynolimit.dev/tube-track/api/v1/live` over HTTPS.
9. Run an initial soak period while the iOS app continues using TfL directly.

Initial POC acceptance criteria:

- The service survives restart and repopulates `LiveCache` automatically.
- The five live feeds include Elizabeth line data.
- `/healthcheck` is healthy only when configuration is valid and clearly
  reports whether `LiveCache` is ready or stale.
- The public `/tube-track/api/v1/live` route returns the intended normalised
  schema over HTTPS.
- Existing `api.skynolimit.dev` routes remain unaffected.
- The TfL key is absent from logs, responses, deployed source and repository
  history.
- Live polling remains near 10 requests/minute outside retries.
- Steady RSS remains within 160 MiB and observed peak RSS remains below
  256 MiB during refreshes and representative requests.
- Prometheus successfully scrapes the service and makes refresh/cache failures
  visible.

### Phase B: server feature parity

Keep the iOS app unchanged while completing and verifying the remaining
server capabilities:

1. Add route topology and the train-position model.
2. Add station departures and train endpoints.
3. Add current status/disruptions, including the Elizabeth line.
4. Add the rolling 60-day planned-works cache and endpoint.
5. Test all API contracts, stale-data behaviour and retry paths.
6. Redeploy and complete a production-like soak period for all caches and
   endpoints.

Phase B is complete when all public `/tube-track/api/v1/...` routes in section
7 meet their intended schemas, sustained upstream traffic remains near 11–12
requests/minute outside retries, and the service continues to meet the memory
and observability criteria above.

## 13. Post-POC iOS migration

After Phase B reaches server feature parity and passes its soak period:

1. Add the TubeTrack backend client to the iOS app.
2. Migrate live arrivals and departure boards.
3. Migrate live train markers.
4. Migrate current status and disruptions.
5. Migrate future engineering works.
6. Verify failure, stale-data and app-backgrounding behaviour.
7. Remove all direct TfL Unified API calls and client-side TfL key handling.

**End goal:** TubeTrack UK clients make zero direct TfL Unified API calls.
