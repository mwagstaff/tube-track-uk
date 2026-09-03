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
- `GET /api/v1/planned-works?from=YYYY-MM-DD&to=YYYY-MM-DD`
- `GET /api/v1/arrival-departures/:stopId?lineId=:lineId`
- `GET /api/v1/timetables/:lineId/:stopId`
- `GET /healthcheck`
- `GET /metrics`

The production Caddy route strips the public `/tube-track` prefix before
proxying requests to this service.

## Development

```sh
npm install
npm test
TUBETRACK_UK_TFL_UNIFIED_API_KEY=... npm start
```

Never commit the TfL key or a local `.env` file.

## Observability

Prometheus metrics are served from `/metrics`. A Grafana dashboard is stored at
`observability/grafana/dashboards/tfl-upstream-api-calls-dashboard.json` and is
automatically imported into **Dashboards → tube-track-api → TfL Upstream API
calls** by a full deployment with
`/Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh`. Quick deployments
intentionally skip Prometheus and Grafana configuration.
