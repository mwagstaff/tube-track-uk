import compression from 'compression';
import express from 'express';
import { JourneyError, JourneyPlanner } from './journey-planner.js';
import { LINE_COLOURS } from './line-colours.js';

const STATUS_MODES = 'tube,dlr,elizabeth-line,overground,tram';
const LINE_IDS = LINE_COLOURS.map((line) => line.id).join(',');

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

function sendLiveResponse(req, res, state, arrivals) {
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
        meta: { ...liveMetadata(state), count: arrivals.length }
    });
}

function liveMetadata(state) {
    return {
        generation: state.snapshot.generation,
        updatedAt: state.snapshot.updatedAt,
        ageSeconds: state.ageSeconds,
        stale: state.stale,
        count: state.snapshot.arrivals.length,
        modeCounts: state.snapshot.modeCounts
    };
}

export function createApp({ cache, poller, metrics, logger, client, resourceCache, journeyPlanner = new JourneyPlanner({ client }) }) {
    const app = express();
    app.disable('x-powered-by');
    app.disable('etag');
    app.use((req, res, next) => {
        res.set('X-Content-Type-Options', 'nosniff');
        next();
    });
    app.use(metrics.middleware());
    app.use(compression({ threshold: 1_024 }));

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
            status: 'ok',
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
        sendLiveResponse(req, res, state, arrivals);
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
        sendLiveResponse(req, res, state, arrivals);
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
        sendLiveResponse(req, res, state, arrivals);
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
        const upstreamFailure = error?.name === 'TfLRequestError';
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
