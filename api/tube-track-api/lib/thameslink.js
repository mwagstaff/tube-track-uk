import { readFileSync } from 'node:fs';
import { Router } from 'express';
import { ThameslinkTrainEstimator } from './thameslink-trains.js';

export const THAMESLINK_LINE_ID = 'thameslink';
const MAXIMUM_STOPS = 6;
const DEPARTED_GRACE_MS = 60_000;
const { directions: DIRECTIONS, stopIds: TFL_STOP_IDS, coordinates: COORDINATES } = JSON.parse(
    readFileSync(new URL('../data/thameslink-directions.json', import.meta.url))
);
const catalogue = JSON.parse(readFileSync(new URL('../data/journey-stations.json', import.meta.url)));
// Thameslink platforms are their own 910G stops inside the app's interchanges:
// the mapped stations' stops that TfL lists for the line.
const tflStopIds = new Set(TFL_STOP_IDS);
export const THAMESLINK_STOP_IDS = new Set(catalogue.stations
    .filter((station) => station.lineIds.includes(THAMESLINK_LINE_ID))
    .flatMap((station) => station.stopIds.filter((id) => tflStopIds.has(id))));

const STATUSES = new Map([
    ['ontime', 'onTime'], ['early', 'onTime'], ['delayed', 'delayed'], ['late', 'delayed'],
    ['cancelled', 'cancelled']
]);

const text = (value) => typeof value === 'string' && value.trim() ? value.trim() : null;

export function stationDisplayName(value) {
    const name = text(value);
    return name?.replace(/ (Rail|Underground) Station$/i, '')
        .replace(/ Station$/i, '')
        .replace(/ \((London|Kent|Surrey|Beds|Herts)\)$/i, '') ?? null;
}

// Blackfriars is a terminus for services arriving from either side of London.
// Its destination-only label cannot distinguish those two directions.
function departureDirection(stopId, destinationStopId) {
    if (destinationStopId === '910GBLFR') {
        const origin = COORDINATES[stopId];
        const destination = COORDINATES[destinationStopId];
        if (!origin || !destination || origin[0] === destination[0]) return null;
        return origin[0] < destination[0] ? 'Northbound' : 'Southbound';
    }
    return DIRECTIONS[destinationStopId] ?? null;
}

/**
 * National Rail boards from TfL's ArrivalDepartures feed. Rows are scheduled
 * calls with a status, not vehicle predictions: there is no vehicle or trip
 * identifier, and a cancelled train is a row that must stay visible.
 */
export function normaliseThameslinkDepartures(raw, stopId, now = Date.now()) {
    if (!Array.isArray(raw)) return [];
    const seen = new Set();
    return raw.flatMap((row) => {
        const scheduled = Date.parse(row?.scheduledTimeOfDeparture);
        if (!Number.isFinite(scheduled)) return [];
        const status = STATUSES.get(String(row.departureStatus ?? '').toLowerCase()) ?? 'unknown';
        const estimated = Date.parse(row.estimatedTimeOfDeparture);
        const expected = status === 'cancelled' || !Number.isFinite(estimated) ? scheduled : estimated;
        if (expected < now - DEPARTED_GRACE_MS) return [];
        const destinationStopId = text(row.destinationNaptanId);
        // A train that terminates here is an arrival, never a departure.
        if (destinationStopId === stopId) return [];
        const id = `${stopId}:${new Date(scheduled).toISOString()}:${destinationStopId ?? ''}`;
        if (seen.has(id)) return [];
        seen.add(id);
        return [{
            id,
            stopId,
            stationName: stationDisplayName(row.stationName),
            lineId: THAMESLINK_LINE_ID,
            lineName: 'Thameslink',
            platformName: text(row.platformName),
            direction: departureDirection(stopId, destinationStopId),
            destinationStopId,
            destinationName: stationDisplayName(row.destinationName) ?? 'Check front of train',
            scheduledDeparture: new Date(scheduled).toISOString(),
            expectedDeparture: new Date(expected).toISOString(),
            timeToStation: Math.max(0, Math.round((expected - now) / 1_000)),
            status,
            cause: text(row.cause)
        }];
    }).sort((a, b) => a.expectedDeparture.localeCompare(b.expectedDeparture)
        || a.id.localeCompare(b.id));
}

// Shared by the departures endpoint and tracked Live Activity boards, so N
// people watching one station cost one TfL request per 30 seconds.
export function createThameslinkDataSource({ client, resourceCache, clock = Date.now }) {
    const stop = (stopId) => resourceCache.get(`arrival-departures:${stopId}:${THAMESLINK_LINE_ID}`, {
        freshForMs: 30_000,
        load: () => client.fetchJSON(`/StopPoint/${encodeURIComponent(stopId)}/ArrivalDepartures`, {
            query: { lineIds: THAMESLINK_LINE_ID },
            metricLabel: 'thameslink:arrival-departures'
        })
    });
    return {
        stop,
        async departures(stopIds) {
            const results = await Promise.allSettled(stopIds.map(stop));
            const available = results.flatMap((result, index) =>
                result.status === 'fulfilled' ? [{ stopId: stopIds[index], result: result.value }] : []);
            if (!available.length) {
                throw results.find((result) => result.status === 'rejected')?.reason
                    ?? new Error('No Thameslink stops requested');
            }
            const now = clock();
            const data = available.flatMap(({ stopId, result }) =>
                normaliseThameslinkDepartures(result.data, stopId, now))
                .sort((a, b) => a.expectedDeparture.localeCompare(b.expectedDeparture) || a.id.localeCompare(b.id));
            const unavailableStopIds = stopIds.filter((_, index) => results[index].status === 'rejected');
            return {
                data,
                meta: {
                    updatedAt: available.map(({ result }) => result.meta.updatedAt).sort()[0],
                    cached: available.every(({ result }) => result.meta.cached),
                    stale: available.some(({ result }) => result.meta.stale) || unavailableStopIds.length > 0,
                    count: data.length,
                    ...(unavailableStopIds.length ? { unavailableStopIds } : {})
                }
            };
        }
    };
}

/**
 * Estimated train positions from every mapped station's board. One estimator
 * per process learns run times from the boards it sees; it runs at most once
 * per 45 seconds however many people are watching.
 */
export function createThameslinkTrainSource({ client, resourceCache, clock = Date.now,
    estimator = new ThameslinkTrainEstimator() }) {
    const source = createThameslinkDataSource({ client, resourceCache, clock });
    const stopIds = [...THAMESLINK_STOP_IDS].sort();
    return () => resourceCache.get('thameslink:trains', {
        freshForMs: 45_000,
        load: async () => {
            const results = await Promise.allSettled(stopIds.map((id) => source.stop(id)));
            const boards = new Map();
            results.forEach((result, index) => {
                if (result.status === 'fulfilled' && !result.value.meta.stale) boards.set(stopIds[index], result.value.data);
            });
            // Too many missing boards would leave trains unmatched and drawn
            // one station behind; better to report the fleet as unavailable.
            if (boards.size < stopIds.length * 0.8) throw new Error('Too few Thameslink boards available');
            return estimator.estimate(boards, clock());
        }
    });
}

export function createThameslinkRoutes({ client, resourceCache }) {
    const router = Router();
    const source = createThameslinkDataSource({ client, resourceCache });
    const trains = createThameslinkTrainSource({ client, resourceCache });
    router.get('/trains', async (req, res, next) => {
        try {
            const result = await trains();
            res.set('Cache-Control', 'public, max-age=15, stale-if-error=60');
            res.json({ ...result, meta: { ...result.meta, count: result.data.length } });
        } catch (error) { next(error); }
    });
    router.get('/departures', async (req, res, next) => {
        const stopIds = typeof req.query.stopIds === 'string'
            ? [...new Set(req.query.stopIds.split(',').map((id) => id.trim().toUpperCase()).filter(Boolean))]
            : [];
        if (!stopIds.length || stopIds.length > MAXIMUM_STOPS
            || stopIds.some((id) => !THAMESLINK_STOP_IDS.has(id))) {
            res.status(400).json({
                error: { code: 'INVALID_STOP_IDS', message: `stopIds must list 1-${MAXIMUM_STOPS} Thameslink stations` }
            });
            return;
        }
        try {
            const result = await source.departures(stopIds);
            res.set('Cache-Control', 'public, max-age=15, stale-if-error=120');
            res.json(result);
        } catch (error) { next(error); }
    });
    return router;
}
