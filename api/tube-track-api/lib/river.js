import { Router } from 'express';
import { RiverBoatEstimator } from './river-boat-estimator.js';

// RB services are the passenger River Bus scope. TfL also puts Woolwich Ferry
// in river-bus; discovery must not silently opt that separate service in.
export const isRiverBusLine = (id) => typeof id === 'string' && /^rb\d+[a-z]?$/i.test(id);
const text = (value) => typeof value === 'string' && value.trim() ? value : null;

export function normaliseRiverNetwork(lines, stopPoints, sequences) {
    const services = lines.filter((line) => isRiverBusLine(line.id))
        .map((line) => ({ id: line.id, name: line.name || line.id.toUpperCase() }));
    const ids = new Set(services.map((line) => line.id));
    const piers = stopPoints.filter((stop) => stop.stopType === 'NaptanFerryPort'
        && Number.isFinite(stop.lat) && Number.isFinite(stop.lon)
        && stop.lines?.some((line) => ids.has(line.id)))
        .map((stop) => ({
            id: stop.id, name: stop.commonName, latitude: stop.lat, longitude: stop.lon,
            lineIds: [...new Set(stop.lines.map((line) => line.id).filter((id) => ids.has(id)))],
            // Do not aggregate nearby bus stops, access areas or entrances.
            arrivalStopIds: [stop.id, ...(stop.children || [])
                .filter((child) => child.stopType === 'NaptanFerryBerth').map((child) => child.id)]
        }));
    const pierIDs = new Set(piers.map((pier) => pier.id));
    const routes = sequences.flatMap((sequence) => (sequence.orderedLineRoutes || []).flatMap((route, index) => {
        const stopIds = route.naptanIds || [];
        if (!ids.has(sequence.lineId) || stopIds.length < 2 || !stopIds.every((id) => pierIDs.has(id))) return [];
        return [{ id: `${sequence.lineId}:${sequence.direction}:${index}`,
            lineId: sequence.lineId, direction: sequence.direction, stopIds }];
    }));
    // TfL lineStrings in the sampled feed are straight chords between piers,
    // not navigable river geometry. Never expose them as vessel tracks.
    return { lines: services, piers, routes };
}

export function normaliseRiverArrivals(raw, network, now = Date.now()) {
    const pierByStop = new Map(network.piers.flatMap((pier) => pier.arrivalStopIds.map((id) => [id, pier.id])));
    const lines = new Set(network.lines.map((line) => line.id));
    const seen = new Set();
    return raw.flatMap((prediction) => {
        if (!prediction || !lines.has(prediction.lineId)) return [];
        const pierId = pierByStop.get(prediction.naptanId);
        const expected = Date.parse(prediction.expectedArrival);
        const observed = Date.parse(prediction.timestamp);
        const expiry = Date.parse(prediction.timeToLive);
        if (!pierId || !Number.isFinite(expected) || expected < now
            || !Number.isFinite(observed) || observed < now - 90_000 || observed > now + 30_000
            || (Number.isFinite(expiry) && expiry < now)) return [];
        const vehicleId = text(prediction.vehicleId);
        const destinationId = pierByStop.get(prediction.destinationNaptanId) || text(prediction.destinationNaptanId);
        const key = JSON.stringify([prediction.lineId, vehicleId || prediction.id, pierId,
            destinationId, prediction.direction, expected]);
        if (seen.has(key)) return [];
        seen.add(key);
        return [{
            id: key, vehicleId, tripId: text(prediction.tripId), pierId,
            lineId: prediction.lineId, direction: text(prediction.direction),
            destinationId, destinationName: text(prediction.destinationName) || text(prediction.towards),
            expectedArrival: new Date(expected).toISOString(),
            observedAt: new Date(observed).toISOString(),
            expiresAt: Number.isFinite(expiry) ? new Date(expiry).toISOString() : null,
            // These are arrival predictions. A terminating boat is not a departure.
            terminatesHere: destinationId === pierId
        }];
    }).sort((a, b) => a.expectedArrival.localeCompare(b.expectedArrival));
}

// Shared cached source for map cards, push validation and tracked pier boards.
export function createRiverDataSource({ client, resourceCache, clock = Date.now }) {
    const fetch = (path) => client.fetchJSON(path, { metricLabel: 'river' });
    const network = () => resourceCache.get('river:network', {
        freshForMs: 24 * 60 * 60 * 1000,
        load: async () => {
            const lines = await fetch('/Line/Mode/river-bus');
            if (!Array.isArray(lines)) throw new Error('Invalid river line catalogue');
            const stops = [];
            for (let page = 1; page <= 20; page++) {
                const result = await fetch(`/StopPoint/Mode/river-bus?page=${page}`);
                if (!Array.isArray(result.stopPoints)) throw new Error('Invalid river piers');
                stops.push(...result.stopPoints);
                if (stops.length >= result.total || result.stopPoints.length === 0) break;
            }
            const sequences = [];
            for (const line of lines.filter((line) => isRiverBusLine(line.id))) {
                for (const direction of ['inbound', 'outbound']) {
                    sequences.push(await fetch(`/Line/${line.id}/Route/Sequence/${direction}`));
                }
            }
            const result = normaliseRiverNetwork(lines, stops, sequences);
            if (!result.piers.length) throw new Error('River pier catalogue is empty');
            return result;
        }
    });
    const status = () => resourceCache.get('river:status', {
        freshForMs: 60_000,
        load: async () => {
            const lines = await fetch('/Line/Mode/river-bus/Status');
            if (!Array.isArray(lines)) throw new Error('Invalid river status');
            return lines.filter((line) => isRiverBusLine(line.id)).map((line) => ({
                id: line.id, name: line.name,
                entries: (line.lineStatuses || []).map((entry) => ({
                    description: entry.statusSeverityDescription || 'Status unavailable',
                    reason: text(entry.reason), severity: entry.statusSeverity
                }))
            }));
        }
    });
    const arrivals = async (pierId) => {
        const catalogue = await network();
        const pier = catalogue.data.piers.find((item) => item.id === pierId);
        if (!pier) return null;
        const result = await resourceCache.get(`river:arrivals:${pier.id}`, {
            freshForMs: 30_000,
            load: async () => {
                const responses = await Promise.all(pier.arrivalStopIds.map((id) => fetch(`/StopPoint/${id}/Arrivals`)));
                if (!responses.every(Array.isArray)) throw new Error('Invalid pier predictions');
                return responses.flat();
            }
        });
        return { ...result, data: normaliseRiverArrivals(result.data, catalogue.data, clock())
            .filter((prediction) => prediction.pierId === pier.id) };
    };
    return { network, status, arrivals };
}

export function createRiverRoutes({ client, resourceCache, clock = Date.now }) {
    const router = Router();
    const boats = new RiverBoatEstimator();
    let fleetUpdatedAt = null;
    const { network, status, arrivals } = createRiverDataSource({ client, resourceCache, clock });
    const fetch = (path) => client.fetchJSON(path, { metricLabel: 'river' });
    const respond = (handler) => async (req, res, next) => {
        try { await handler(req, res); } catch (error) {
            // Independent from the rail polling cycle and legacy response schema.
            res.status(503).json({ error: { code: 'RIVER_UNAVAILABLE', message: 'River Bus data is temporarily unavailable' } });
        }
    };
    router.get('/network', respond(async (req, res) => {
        res.set('Cache-Control', 'public, max-age=3600');
        res.json(await network());
    }));
    router.get('/status', respond(async (req, res) => {
        const result = await status();
        res.set('Cache-Control', 'public, max-age=30');
        res.json(result);
    }));
    const live = async () => {
        const catalogue = await network();
        const result = await resourceCache.get('river:live', {
            freshForMs: 30_000,
            load: () => fetch('/Mode/river-bus/Arrivals?count=-1')
        });
        if (!Array.isArray(result.data)) throw new Error('Invalid river predictions');
        const predictions = normaliseRiverArrivals(result.data, catalogue.data, clock());
        // Learning is shared by legacy /live callers and new /boats callers.
        // Failed/stale reads never advance the history or freshness of a vessel.
        if (!result.meta.stale) {
            boats.update(predictions, catalogue.data, clock());
            if (predictions.length) fleetUpdatedAt = result.meta.updatedAt;
        }
        return { ...result, data: predictions };
    };
    router.get('/live', respond(async (req, res) => {
        res.set('Cache-Control', 'no-store');
        res.json(await live());
    }));
    router.get('/boats', respond(async (req, res) => {
        res.set('Cache-Control', 'no-store');
        let result;
        try { result = await live(); } catch (error) {
            const held = boats.current(clock());
            if (!held.length) throw error;
            res.json({ data: held, meta: { updatedAt: fleetUpdatedAt, cached: true, stale: true } });
            return;
        }
        res.json({ data: boats.current(clock()), meta: {
            ...result.meta,
            updatedAt: fleetUpdatedAt || result.meta.updatedAt,
            stale: result.meta.stale || result.data.length === 0
        } });
    }));
    router.get('/arrivals/:pierId', respond(async (req, res) => {
        const result = await arrivals(req.params.pierId);
        if (!result) { res.status(404).json({ error: { code: 'UNKNOWN_PIER', message: 'Pier not found' } }); return; }
        res.set('Cache-Control', 'no-store');
        res.json(result);
    }));
    return router;
}
