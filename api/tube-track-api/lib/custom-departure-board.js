import { readFileSync } from 'node:fs';
import { Router } from 'express';
import { createRiverDataSource } from './river.js';
import { createNationalRailDepartureSource } from './push/national-rail-departures.js';
import { createRailDepartureSource, correctRailBoard } from './push/rail-departures.js';
import { createThameslinkDataSource } from './thameslink.js';
import { LINE_COLOURS } from './line-colours.js';
import { isSelfReferential } from './push/departure-projection.js';
import { loadLineStatuses } from './line-status.js';
import { conditionsByLine } from './push/line-condition.js';
import { riverCondition } from './push/river-departure-projection.js';

export const DEPARTURE_STOPS = JSON.parse(readFileSync(new URL('../data/departure-stops.json', import.meta.url)));
const ALL_STOP_MODES = new Set(['tube', 'dlr', 'tram']);
const modes = new Map(LINE_COLOURS.map(line => [line.id, line.mode]));
const OVERGROUND = new Set(['liberty', 'lioness', 'mildmay', 'suffragette', 'weaver', 'windrush']);
const cleanName = value => String(value ?? '').toLowerCase()
    .replace(/ (underground|dlr|rail) station$| tram stop$| pier$/g, '').trim();

// Matches the direction headings used by the iOS board, including DLR feeds
// that provide only a platform number or inbound/outbound.
export function departureDirection(row, origin, stops) {
    const cardinal = ['northbound', 'southbound', 'eastbound', 'westbound'];
    const platform = String(row.platformName ?? '').trim();
    const reported = cardinal.find(value => platform.toLowerCase().includes(value)) || String(row.direction ?? '').toLowerCase();
    if (row.lineId === 'dlr' && !cardinal.includes(reported)) {
        const candidates = stops.filter(stop => [stop.id, ...stop.stopIDs, ...stop.railCodes].includes(row.destinationStopId)
            || (stop.lineIDs.includes('dlr') && cleanName(stop.name) === cleanName(row.destinationName)));
        if (candidates.length === 1) {
            const end = candidates[0], rad = Math.PI / 180;
            if (Number.isFinite(origin.latitude) && Number.isFinite(end.latitude)
                && (origin.latitude !== end.latitude || origin.longitude !== end.longitude)) {
                const east = Math.sin((end.longitude - origin.longitude) * rad) * Math.cos(end.latitude * rad);
                const north = Math.cos(origin.latitude * rad) * Math.sin(end.latitude * rad)
                    - Math.sin(origin.latitude * rad) * Math.cos(end.latitude * rad) * Math.cos((end.longitude - origin.longitude) * rad);
                const bearing = (Math.atan2(east, north) / rad + 360) % 360;
                return bearing >= 67.5 && bearing < 112.5 ? 'Eastbound'
                    : bearing >= 112.5 && bearing < 247.5 ? 'Southbound'
                    : bearing >= 247.5 && bearing < 292.5 ? 'Westbound' : 'Northbound';
            }
        }
    }
    if (row.lineId === 'elizabeth' && ['inbound', 'outbound'].includes(reported)) return reported === 'inbound' ? 'Eastbound' : 'Westbound';
    if (reported) return reported.charAt(0).toUpperCase() + reported.slice(1);
    return platform ? (/platform/i.test(platform) ? platform : `Platform ${platform}`) : 'Other departures';
}

// Returns true only if every compatible calling pattern visits a selected stop
// after boarding and before the published terminus. A graph path isn't evidence.
export function callsAtSelected(row, originIDs, destinationIDs, routes) {
    if (destinationIDs.includes(row.destinationStopId)) return true;
    const candidates = [];
    for (const route of routes) {
        if (route.lineId !== row.lineId) continue;
        if (row.direction && route.direction && ['inbound', 'outbound'].includes(row.direction)
            && row.direction !== route.direction) continue;
        const start = route.stopIds.findIndex(id => originIDs.includes(id));
        if (start < 0) continue;
        const end = route.stopIds.indexOf(row.destinationStopId, start + 1);
        if (end <= start) continue;
        candidates.push(route.stopIds.slice(start + 1, end + 1));
    }
    if (!candidates.length) return null;
    const matches = candidates.map(stops => stops.some(id => destinationIDs.includes(id)));
    if (matches.every(Boolean)) return true;
    return matches.some(Boolean) ? null : false;
}

export function orderedUniqueDepartures(rows, nowMs) {
    const seen = new Set();
    return rows.filter(row => {
        const date = Date.parse(row.expectedArrival ?? row.expectedDeparture ?? row.scheduledDeparture);
        if (!(date > nowMs - 15_000) && !(row.status === 'delayed' && !row.expectedArrival)) return false;
        if (isSelfReferential(row)) return false;
        const key = [row.lineId, row.vehicleId || row.id, row.destinationStopId || row.destinationName,
            row.expectedArrival ?? row.scheduledDeparture, row.platformName].join('|');
        if (seen.has(key)) return false;
        seen.add(key); return true;
    }).sort((a, b) => Date.parse(a.expectedArrival ?? a.scheduledDeparture)
        - Date.parse(b.expectedArrival ?? b.scheduledDeparture) || a.id.localeCompare(b.id));
}

export function createCustomDepartureSource({ client, resourceCache, cache, clock = Date.now,
    stops = DEPARTURE_STOPS, river = createRiverDataSource({ client, resourceCache }),
    nationalRail = createNationalRailDepartureSource({ resourceCache }),
    rail = createRailDepartureSource({ client, resourceCache }),
    thameslink = createThameslinkDataSource({ client, resourceCache }) }) {
    const byID = new Map(stops.flatMap(stop => [stop.id, ...stop.stopIDs].map(id => [id, stop])));

    async function resolve(id) {
        if (byID.has(id)) return byID.get(id);
        const network = await river.network();
        const pier = network.data.piers.find(p => p.id === id);
        return pier ? { ...pier, stopIDs: [pier.id], railCodes: [], lineIDs: pier.lineIds, mode: 'river' } : null;
    }

    async function validate(request) {
        if (!request || (request.direction != null && (typeof request.direction !== 'string' || !request.direction.length || request.direction.length > 80)) || typeof request.originID !== 'string' || request.originID.length > 64
            || !Array.isArray(request.destinationIDs) || request.destinationIDs.length > 8
            || !Array.isArray(request.lineIDs) || request.lineIDs.length > 16
            || [...request.destinationIDs, ...request.lineIDs].some(id => typeof id !== 'string' || id.length > 64)) {
            throw Object.assign(new Error('Invalid departure board'), { status: 400 });
        }
        const origin = await resolve(request.originID);
        const destinations = await Promise.all(request.destinationIDs.map(resolve));
        if (!origin || destinations.some(stop => !stop || stop.id === origin.id || stop.mode !== origin.mode)
            || request.lineIDs.some(id => !modes.has(id) && !/^national-rail:[A-Za-z0-9-]{1,30}$/.test(id)
                && !/^rb[0-9]+[a-z]?$/.test(id))) {
            throw Object.assign(new Error('Choose valid stations and services'), { status: 400 });
        }
        return { origin, destinations };
    }

    async function routesFor(lineId) {
        const result = await resourceCache.get(`departure-patterns:${lineId}`, {
            freshForMs: 60 * 60_000,
            load: async () => {
                const data = await client.fetchJSON(`/Line/${encodeURIComponent(lineId)}/Route/Sequence/all`,
                    { metricLabel: 'departure-patterns' });
                if (!Array.isArray(data.orderedLineRoutes)) throw new Error('Calling patterns unavailable');
                // stopPointSequences are branch fragments; orderedLineRoutes
                // supplies complete calling patterns, in either direction.
                return data.orderedLineRoutes.flatMap(route => {
                    if (!Array.isArray(route.naptanIds)) return [];
                    return [{ lineId, stopIds: route.naptanIds },
                        { lineId, stopIds: [...route.naptanIds].reverse() }];
                });
            }
        });
        if (result.meta.stale) throw new Error('Calling patterns out of date');
        return result.data;
    }

    async function board(request) {
        const { origin, destinations } = await validate(request);
        const now = clock();
        let updated = now, unavailableSources = 0, unverifiedCount = 0, successfulSources = 0;
        const rows = [];
        const wanted = row => !request.lineIDs.length || request.lineIDs.includes(row.lineId);
        const consume = result => {
            const time = Date.parse(result?.meta?.updatedAt);
            if (!Number.isFinite(time) || result.meta.stale || now - time > 90_000) throw new Error('Stale departures');
            updated = Math.min(updated, time); successfulSources++;
            return result.data;
        };
        const targetIDs = destinations.flatMap(stop => [...stop.stopIDs, ...stop.railCodes]);

        if (origin.mode === 'river') {
            const network = (await river.network()).data;
            const predictions = consume(await river.arrivals(origin.id));
            for (const prediction of predictions) {
                if (prediction.terminatesHere || (prediction.expiresAt && Date.parse(prediction.expiresAt) < now)) continue;
                const row = { ...prediction, stopId: origin.id, destinationStopId: prediction.destinationId,
                    operatorName: 'River Bus', stationName: origin.name };
                if (!wanted(row)) continue;
                const match = !destinations.length || callsAtSelected(row, [origin.id], targetIDs, network.routes);
                if (match === null) unverifiedCount++;
                if (match) rows.push(row);
            }
        } else {
            const state = cache.read();
            const railCovered = new Set();
            // A filtered National Rail feed verifies intermediate calls, including
            // express patterns, without fetching one service detail per train.
            if (origin.railCodes.length && (!request.lineIDs.length
                || request.lineIDs.some(id => !ALL_STOP_MODES.has(modes.get(id))))) {
                const targets = destinations.length ? [...new Set(destinations.flatMap(stop => stop.railCodes))] : [null];
                for (const crs of origin.railCodes) {
                    for (const destinationCRS of targets) {
                        try {
                            const result = await nationalRail.departures(crs, { includeAllOperators: true, destinationCRS });
                            const data = consume(result);
                            for (const arrival of data) {
                                const code = arrival.lineId.split(':')[1];
                                let mapped = code === 'XR' ? 'elizabeth' : code === 'TL' ? 'thameslink' : null;
                                if (code === 'LO') {
                                    // At interchanges, an operator code alone cannot
                                    // distinguish Mildmay from Windrush, for example.
                                    const endLines = stops.filter(stop => stop.railCodes.includes(arrival.destinationStopId))
                                        .flatMap(stop => stop.lineIDs);
                                    const candidates = origin.lineIDs.filter(id => OVERGROUND.has(id)
                                        && (!endLines.length || endLines.includes(id)));
                                    if (candidates.length === 1) mapped = candidates[0];
                                    else if (request.lineIDs.some(id => OVERGROUND.has(id))) unverifiedCount++;
                                }
                                const row = { ...arrival, lineId: mapped ?? arrival.lineId };
                                if (wanted(row)) rows.push(row);
                            }
                            // These railway lines are sourced from the same board,
                            // even when no departures exist. Don't add duplicates.
                            if (targets.length) for (const line of origin.lineIDs.filter(id => !ALL_STOP_MODES.has(modes.get(id)))) railCovered.add(line);
                        } catch (error) {
                            unavailableSources++;
                            console.warn(JSON.stringify({ timestamp: new Date(now).toISOString(), event: 'departure_source_unavailable', origin: origin.id,
                                source: 'national-rail', station: crs, reason: error.message }));
                        }
                    }
                }
            }
            for (const lineId of origin.lineIDs.filter(id => !railCovered.has(id))) {
                if (request.lineIDs.length && !request.lineIDs.includes(lineId)) continue;
                try {
                    let arrivals;
                    if (lineId === 'thameslink') {
                        arrivals = consume(await thameslink.departures(origin.stopIDs)).map(row => ({ ...row,
                            expectedArrival: row.expectedDeparture ?? row.expectedArrival }));
                    } else {
                        const mode = modes.get(lineId);
                        if (!state || state.staleModes.includes(mode)) throw new Error('Live predictions unavailable');
                        updated = Math.min(updated, Date.parse(state.snapshot.modeUpdatedAt[mode] ?? state.snapshot.updatedAt));
                        const corrected = await correctRailBoard({ arrivals: state.snapshot.arrivals,
                            stopIds: origin.stopIDs, lineId, source: rail, nowMs: now });
                        updated = Math.min(updated, corrected.updatedAtMs);
                        arrivals = corrected.arrivals.filter(row => row.lineId === lineId && corrected.stopIds.includes(row.stopId));
                        successfulSources++;
                    }
                    let routes = [];
                    if (destinations.length && ALL_STOP_MODES.has(modes.get(lineId))) {
                        try { routes = await routesFor(lineId); } catch { /* Terminal matches are still verifiable. */ }
                    }
                    for (const original of arrivals) {
                        const row = { ...original };
                        if (!row.destinationStopId && row.destinationName) {
                            const candidates = stops.filter(stop => stop.lineIDs.includes(lineId)
                                && cleanName(stop.name) === cleanName(row.destinationName));
                            if (candidates.length === 1) row.destinationStopId = candidates[0].stopIDs[0];
                        }
                        const match = !destinations.length || callsAtSelected(row, origin.stopIDs, targetIDs, routes);
                        if (match === null) unverifiedCount++;
                        if (match) rows.push(row);
                    }
                } catch (error) {
                    unavailableSources++;
                    console.warn(JSON.stringify({ timestamp: new Date(now).toISOString(), event: 'departure_source_unavailable',
                        origin: origin.id, source: lineId, reason: error.message }));
                }
            }
        }
        if (!successfulSources && unavailableSources) throw Object.assign(new Error('Live departures temporarily unavailable'), { status: 503 });
        let condition = rows.some(row => row.status === 'cancelled') ? { rank: 1, headline: 'Cancellations' }
            : rows.some(row => row.status === 'delayed') ? { rank: 1, headline: 'Delays' } : { rank: 4, headline: null };
        try {
            const relevant = new Set(request.lineIDs.length ? request.lineIDs : origin.lineIDs);
            const conditions = origin.mode === 'river'
                ? (await river.status()).data.filter(line => relevant.has(line.id)).map(line => ({ ...riverCondition(line), name: line.name }))
                : [...conditionsByLine((await loadLineStatuses({ client, resourceCache })).data)]
                    .filter(([id]) => relevant.has(id)).map(([id, value]) => ({ ...value, name: LINE_COLOURS.find(line => line.id === id)?.name }));
            for (const issue of conditions) {
                if (issue.rank < condition.rank && issue.headline) {
                    condition = { rank: issue.rank, headline: `${issue.name ?? 'Service'}: ${issue.headline}` };
                }
            }
        } catch { /* Status failure must not discard verified departure times. */ }
        const selectedRows = request.direction ? rows.filter(row => departureDirection(row, origin, stops) === request.direction) : rows;
        return { arrivals: orderedUniqueDepartures(selectedRows, now), updatedAt: new Date(updated).toISOString(),
            unavailableSources, unverifiedCount, stale: false, conditionRank: condition.rank, conditionHeadline: condition.headline };
    }
    return { board, validate };
}

export function createCustomDepartureRoutes(source) {
    const router = Router();
    router.get('/', async (req, res, next) => {
        try {
            const list = value => typeof value === 'string' && value ? value.split(',') : [];
            const result = await source.board({ originID: req.query.origin,
                destinationIDs: list(req.query.destinations), lineIDs: list(req.query.lines), direction: req.query.direction || undefined });
            res.set('Cache-Control', 'private, no-store');
            res.json({ data: result });
        } catch (error) {
            if ([400, 503].includes(error.status)) {
                res.status(error.status).json({ error: { code: error.status === 400 ? 'INVALID_BOARD' : 'DEPARTURES_UNAVAILABLE', message: error.message } });
            } else { next(error); }
        }
    });
    return router;
}
