import compression from 'compression';
import express from 'express';
import { JourneyError, JourneyPlanner } from './journey-planner.js';
import { LINE_COLOURS } from './line-colours.js';
import { plannedWorksV2Response, PlannedWorksSourceError } from './planned-works.js';
import { createPushRoutes } from './push-routes.js';
import { createRiverRoutes } from './river.js';
import { createCableCarRoutes } from './cable-car.js';
import { clientMetadata, USAGE_FEATURES } from './usage.js';

const STATUS_MODES = 'tube,dlr,elizabeth-line,overground,tram';
const LINE_IDS = LINE_COLOURS.map((line) => line.id).join(',');
const MODE_BY_LINE_ID = new Map(LINE_COLOURS.map((line) => [line.id, line.mode]));

function commaSeparated(value, { maximum = 25 } = {}) {
    if (typeof value !== 'string') return [];
    return [...new Set(value.split(',').map((part) => part.trim()).filter(Boolean))]
        .slice(0, maximum);
}

function isIdentifier(value) {
    return typeof value === 'string' && /^[A-Za-z0-9-]+$/.test(value);
}

function isDate(value) {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
        return false;
    }
    const parsed = new Date(`${value}T00:00:00Z`);
    return !Number.isNaN(parsed.getTime()) && parsed.toISOString().startsWith(value);
}

function sendLiveResponse(req, res, state, arrivals, relevantModes = new Set(
    arrivals.map((arrival) => MODE_BY_LINE_ID.get(arrival.lineId)).filter(Boolean)
)) {
    res.set({
        'Cache-Control': 'public, max-age=5, stale-while-revalidate=20, stale-if-error=120',
        ETag: state.snapshot.etag
    });
    if (req.get('if-none-match') === state.snapshot.etag) {
        res.status(304).end();
        return;
    }
    res.json({
        data: arrivals,
        meta: { ...liveMetadata(state, relevantModes), count: arrivals.length }
    });
}

function liveMetadata(state, relevantModes = null) {
    const modeTimes = relevantModes?.size
        ? [...relevantModes].map((mode) => state.snapshot.modeUpdatedAt?.[mode]).filter(Boolean)
        : [];
    const updatedAtMs = modeTimes.length > 0
        ? Math.min(...modeTimes.map((timestamp) => Date.parse(timestamp)))
        : state.snapshot.updatedAtMs;
    const stale = relevantModes?.size
        ? state.staleModes.some((mode) => relevantModes.has(mode))
        : state.stale;
    return {
        generation: state.snapshot.generation,
        updatedAt: new Date(updatedAtMs).toISOString(),
        ageSeconds: relevantModes?.size
            ? Math.max(...[...relevantModes].map((mode) => state.modeAgeSeconds?.[mode] ?? 0))
            : state.ageSeconds,
        stale,
        count: state.snapshot.arrivals.length,
        modeCounts: state.snapshot.modeCounts,
        modeUpdatedAt: state.snapshot.modeUpdatedAt,
        staleModes: state.staleModes
    };
}

function modesForStops(stopIds, arrivals, journeyPlanner) {
    const modes = new Set(arrivals.map((arrival) => MODE_BY_LINE_ID.get(arrival.lineId)).filter(Boolean));
    for (const stopId of stopIds) {
        const station = journeyPlanner.byId.get(stopId.toUpperCase());
        for (const lineId of station?.lineIds ?? []) {
            const mode = MODE_BY_LINE_ID.get(lineId);
            if (mode) modes.add(mode);
        }
    }
    return modes;
}

export function createApp({
    cache,
    poller,
    metrics,
    logger,
    client,
    resourceCache,
    plannedTrackClosuresSource,
    pushTokenStore = null,
    usageStore = null,
    journeyPlanner = new JourneyPlanner({ client })
}) {
    const app = express();
    app.disable('x-powered-by');
    app.disable('etag');
    app.use((req, res, next) => {
        res.set('X-Content-Type-Options', 'nosniff');
        next();
    });
    app.use(metrics.middleware());
    app.use(compression({ threshold: 1_024 }));
    const usageBody = express.json({ limit: '512b', strict: true });
    app.post('/api/v1/usage', (req, res, next) => {
        usageBody(req, res, (error) => {
            if (!error) return next();
            res.status(error.status === 413 ? 413 : 400)
                .json({ error: { code: 'INVALID_USAGE_EVENT' } });
        });
    }, (req, res) => {
        res.set('Cache-Control', 'no-store');
        const client = clientMetadata(req);
        const event = req.body?.event;
        const feature = req.body?.feature;
        if (!usageStore || !client.installId || client.surface !== 'ios_app'
            || !['app_open', 'feature_open'].includes(event)
            || !USAGE_FEATURES.includes(feature)) {
            res.status(400).json({ error: { code: 'INVALID_USAGE_EVENT' } });
            return;
        }
        if (event === 'app_open') usageStore.record(client.installId, 'ios_app');
        metrics.recordUsageEvent({ event, feature });
        res.status(204).end();
    });
    app.use('/api/v1/river', createRiverRoutes({ client, resourceCache }));
    app.use('/api/v1/cable-car', createCableCarRoutes({ client, resourceCache }));

    app.get('/api/v1/line-colours', (req, res) => {
        res.set('Cache-Control', 'public, max-age=86400');
        res.json({ data: LINE_COLOURS, meta: { source: 'tubetrack', count: LINE_COLOURS.length } });
    });

    app.get('/api/v1/stations', (req, res, next) => {
        try {
            const stations = journeyPlanner.search(req.query.query);
            res.set('Cache-Control', 'public, max-age=86400');
            res.json({ data: stations, meta: { source: 'tfl', count: stations.length } });
        } catch (error) { next(error); }
    });

    app.get('/api/v1/journeys', async (req, res, next) => {
        // Explicit server expiry, never a proxy's stale-if-error policy.
        res.set('Cache-Control', 'no-store');
        try {
            res.json(await journeyPlanner.plan(req.query));
        } catch (error) { next(error); }
    });

    app.get('/healthcheck', (req, res) => {
        const state = cache.read();
        const polling = poller.status();
        if (!state) {
            res.status(503).json({
                status: 'starting',
                ready: false,
                liveCache: null,
                polling
            });
            return;
        }

        res.json({
            status: state.stale ? 'degraded' : 'ok',
            ready: true,
            liveCache: liveMetadata(state),
            polling
        });
    });

    app.get('/metrics', async (req, res, next) => {
        try {
            res.type(metrics.contentType);
            res.send(await metrics.render());
        } catch (error) {
            next(error);
        }
    });

    app.get('/api/v1/live', (req, res) => {
        const state = cache.read();
        if (!state) {
            res.set('Retry-After', '5');
            res.status(503).json({
                error: {
                    code: 'LIVE_CACHE_NOT_READY',
                    message: 'Live TfL data is not ready yet'
                }
            });
            return;
        }

        const lineIDs = new Set(commaSeparated(req.query.lineIds));
        const arrivals = lineIDs.size === 0
            ? state.snapshot.arrivals
            : state.snapshot.arrivals.filter((arrival) => lineIDs.has(arrival.lineId));
        const relevantModes = lineIDs.size === 0
            ? new Set()
            : new Set([...lineIDs].map((lineId) => MODE_BY_LINE_ID.get(lineId)).filter(Boolean));
        sendLiveResponse(req, res, state, arrivals, relevantModes);
    });

    app.get('/api/v1/arrivals', (req, res) => {
        const state = cache.read();
        if (!state) {
            res.set('Retry-After', '5');
            res.status(503).json({
                error: { code: 'LIVE_CACHE_NOT_READY', message: 'Live TfL data is not ready yet' }
            });
            return;
        }
        const stopIDs = commaSeparated(req.query.stopIds);
        if (stopIDs.length === 0 || stopIDs.some((value) => !isIdentifier(value))) {
            res.status(400).json({
                error: { code: 'INVALID_STOP_IDS', message: 'stopIds must contain station identifiers' }
            });
            return;
        }
        const arrivals = stopIDs.flatMap((stopID) =>
            state.snapshot.arrivalsByStop.get(stopID.toUpperCase()) ?? []
        );
        sendLiveResponse(req, res, state, arrivals, modesForStops(stopIDs, arrivals, journeyPlanner));
    });

    app.get('/api/v1/arrivals/:stopId', (req, res) => {
        const state = cache.read();
        if (!state) {
            res.set('Retry-After', '5');
            res.status(503).json({
                error: { code: 'LIVE_CACHE_NOT_READY', message: 'Live TfL data is not ready yet' }
            });
            return;
        }
        if (!isIdentifier(req.params.stopId)) {
            res.status(400).json({
                error: { code: 'INVALID_STOP_ID', message: 'A station identifier is required' }
            });
            return;
        }
        const arrivals = state.snapshot.arrivalsByStop.get(
            req.params.stopId.toUpperCase()
        ) ?? [];
        sendLiveResponse(req, res, state, arrivals, modesForStops([req.params.stopId], arrivals, journeyPlanner));
    });

    app.get('/api/v1/status', async (req, res, next) => {
        try {
            const result = await resourceCache.get('status', {
                freshForMs: 60_000,
                load: () => client.fetchJSON(`/Line/Mode/${STATUS_MODES}/Status`, {
                    query: { detail: 'true' },
                    metricLabel: 'status'
                })
            });
            res.set('Cache-Control', 'public, max-age=30, stale-if-error=300');
            res.json(result);
        } catch (error) {
            next(error);
        }
    });

    // Mounted only when push is configured, so an API without APNs credentials
    // answers 404 rather than pretending to accept registrations it will never
    // act on.
    if (pushTokenStore) {
        app.use('/api/v1/push', createPushRoutes({
            store: pushTokenStore,
            isKnownStop: (id) => journeyPlanner.byId.has(id),
            logger,
            metrics
        }));
    }

    app.get('/api/v1/planned-works', async (req, res, next) => {
        const { from, to } = req.query;
        if (!isDate(from) || !isDate(to) || from > to) {
            res.status(400).json({
                error: { code: 'INVALID_DATE_RANGE', message: 'from and to must be a valid date range' }
            });
            return;
        }
        try {
            const key = `planned-works:${from}:${to}`;
            const result = await resourceCache.get(key, {
                freshForMs: 6 * 60 * 60 * 1_000,
                load: () => client.fetchJSON(`/Line/${LINE_IDS}/Status/${from}/to/${to}`, {
                    query: { detail: 'true' },
                    metricLabel: 'planned-works'
                })
            });
            res.set('Cache-Control', 'public, max-age=3600, stale-if-error=86400');
            res.json(result);
        } catch (error) {
            next(error);
        }
    });

    // V2 adds TfL's six-month PDF schedule and normalized coverage metadata.
    // V1 deliberately remains unchanged for already-released app versions.
    app.get('/api/v2/planned-works', async (req, res, next) => {
        const { from, to } = req.query;
        if (!isDate(from) || !isDate(to) || from > to) {
            res.status(400).json({
                error: { code: 'INVALID_DATE_RANGE', message: 'from and to must be a valid date range' }
            });
            return;
        }
        if (!plannedTrackClosuresSource) {
            res.status(503).json({
                error: { code: 'PLANNED_WORKS_V2_UNAVAILABLE', message: 'Long-range planned works are unavailable' }
            });
            return;
        }
        try {
            const pdfSnapshotPromise = plannedTrackClosuresSource.get();
            const apiResultPromise = resourceCache.get(`planned-works:${from}:${to}`, {
                freshForMs: 6 * 60 * 60 * 1_000,
                load: () => client.fetchJSON(`/Line/${LINE_IDS}/Status/${from}/to/${to}`, {
                    query: { detail: 'true' },
                    metricLabel: 'planned-works'
                })
            }).catch((error) => {
                logger?.warn('planned_works_unified_api_unavailable', { error });
                return {
                    data: [],
                    meta: {
                        updatedAt: new Date().toISOString(),
                        cached: false,
                        stale: true,
                        unavailable: true
                    }
                };
            });
            const [pdfSnapshot, apiResult] = await Promise.all([
                pdfSnapshotPromise,
                apiResultPromise
            ]);
            const response = plannedWorksV2Response({ from, to, pdfSnapshot, apiResult });
            res.set('Cache-Control', 'public, max-age=3600, stale-if-error=86400');
            res.json(response);
        } catch (error) {
            next(error);
        }
    });

    app.get('/api/v1/arrival-departures/:stopId', async (req, res, next) => {
        const lineID = req.query.lineId;
        if (!isIdentifier(req.params.stopId) || !isIdentifier(lineID)) {
            res.status(400).json({
                error: { code: 'INVALID_IDENTIFIER', message: 'A station and line identifier are required' }
            });
            return;
        }
        try {
            const stopID = req.params.stopId.toUpperCase();
            const key = `arrival-departures:${stopID}:${lineID}`;
            const result = await resourceCache.get(key, {
                freshForMs: 30_000,
                load: () => client.fetchJSON(`/StopPoint/${encodeURIComponent(stopID)}/ArrivalDepartures`, {
                    query: { lineIds: lineID },
                    metricLabel: 'arrival-departures'
                })
            });
            res.set('Cache-Control', 'public, max-age=15, stale-if-error=300');
            res.json(result);
        } catch (error) {
            next(error);
        }
    });

    app.get('/api/v1/timetables/:lineId/:stopId', async (req, res, next) => {
        if (!isIdentifier(req.params.lineId) || !isIdentifier(req.params.stopId)) {
            res.status(400).json({
                error: { code: 'INVALID_IDENTIFIER', message: 'A line and station identifier are required' }
            });
            return;
        }
        try {
            const lineID = req.params.lineId;
            const stopID = req.params.stopId.toUpperCase();
            const key = `timetable:${lineID}:${stopID}`;
            const result = await resourceCache.get(key, {
                freshForMs: 24 * 60 * 60 * 1_000,
                load: () => client.fetchJSON(
                    `/Line/${encodeURIComponent(lineID)}/Timetable/${encodeURIComponent(stopID)}`,
                    { metricLabel: 'timetable' }
                )
            });
            res.set('Cache-Control', 'public, max-age=3600, stale-if-error=86400');
            res.json(result);
        } catch (error) {
            next(error);
        }
    });

    app.use((req, res) => {
        res.status(404).json({
            error: {
                code: 'NOT_FOUND',
                message: 'Route not found'
            }
        });
    });

    app.use((error, req, res, next) => {
        if (error instanceof JourneyError) {
            if (error.status >= 500) logger?.error('journey_request_failed', { code: error.code, message: error.message });
            if (error.status === 429) res.set('Retry-After', '30');
            res.status(error.status).json({ error: { code: error.code, message: error.message } });
            return;
        }
        logger?.error('http_request_failed', {
            method: req.method,
            path: req.path,
            error
        });
        if (res.headersSent) {
            next(error);
            return;
        }
        const upstreamFailure = error?.name === 'TfLRequestError'
            || error instanceof PlannedWorksSourceError;
        res.status(upstreamFailure ? 503 : 500).json({
            error: {
                code: upstreamFailure ? 'UPSTREAM_UNAVAILABLE' : 'INTERNAL_ERROR',
                message: upstreamFailure
                    ? 'Live transport data is temporarily unavailable'
                    : 'Internal server error'
            }
        });
    });

    return app;
}
