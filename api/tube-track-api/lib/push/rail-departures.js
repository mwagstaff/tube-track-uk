import { isSelfReferential } from './departure-projection.js';

// The same rail lines for which StationArrivalsService uses ArrivalDepartures.
const RAIL_LINES = new Set(['elizabeth', 'liberty', 'lioness', 'mildmay',
    'suffragette', 'weaver', 'windrush']);
const text = (value) => typeof value === 'string' && value.trim() ? value.trim() : null;

// TfL also publishes Elizabeth predictions under Abbey Wood's National Rail
// ID. Those duplicate rows have broken outbound times and a different station
// name, so they escape the usual self-referential destination check.
export function canonicalRailStopId(stopId, lineId) {
    const id = stopId?.toUpperCase();
    return lineId === 'elizabeth' && id === '910GABWD' ? '910GABWDXR' : id;
}

/** Shared by update pushes and scheduled starts; never mix corrected and alias rows. */
export async function correctRailBoard({ arrivals, stopIds, lineId, source, nowMs,
    previousUpdatedAtMs = 0, boards = new Map() }) {
    stopIds = [...new Set(stopIds.map((id) => canonicalRailStopId(id, lineId)))];
    arrivals = arrivals.map((row) => row.lineId === lineId
        ? { ...row, stopId: canonicalRailStopId(row.stopId, lineId),
            destinationStopId: canonicalRailStopId(row.destinationStopId, lineId) }
        : row);
    let updatedAtMs = nowMs;
    const stops = railStopsNeedingDepartures(arrivals, stopIds, lineId, nowMs);
    if (stops.length && source) {
        for (const stopId of stops) {
            const key = `${stopId}:${lineId}`;
            if (!boards.has(key)) {
                if (boards.size >= 40) throw new Error('Rail departure lookup capacity reached');
                boards.set(key, source.departures(stopId, lineId, arrivals));
            }
            const result = await boards.get(key);
            const fetchedAt = Date.parse(result?.meta?.updatedAt);
            if (!result || result.meta.stale || !Number.isFinite(fetchedAt)
                || nowMs - fetchedAt > 90_000 || fetchedAt < previousUpdatedAtMs) {
                throw new Error('Rail departure board is stale');
            }
            updatedAtMs = Math.min(updatedAtMs, fetchedAt);
            arrivals = arrivals.filter((row) => row.lineId !== lineId || row.stopId !== stopId)
                .concat(result.data);
        }
    }
    return { arrivals, stopIds, updatedAtMs };
}

export function railStopsNeedingDepartures(arrivals, stopIds, lineId, nowMs) {
    if (!RAIL_LINES.has(lineId)) return [];
    return [...new Set(stopIds.map((id) => id.toUpperCase()))].filter((stopId) => {
        const rows = arrivals.filter((row) => row.lineId === lineId
            && row.stopId?.toUpperCase() === stopId);
        return rows.some(isSelfReferential)
            || (rows.length > 0 && rows.every((row) => Date.parse(row.expectedArrival) <= nowMs));
    });
}

/** Correct rail terminus boards without changing the network vehicle feed. */
export function createRailDepartureSource({ client, resourceCache, clock = Date.now }) {
    return {
        async departures(stopId, lineId, predictions) {
            // Shared with the app's /arrival-departures endpoint.
            const result = await resourceCache.get(`arrival-departures:${stopId}:${lineId}`, {
                freshForMs: 30_000,
                load: async () => {
                    const data = await client.fetchJSON(`/StopPoint/${encodeURIComponent(stopId)}/ArrivalDepartures`, {
                        query: { lineIds: lineId }, metricLabel: 'arrival-departures'
                    });
                    if (!Array.isArray(data)) throw new Error('Invalid rail departure board');
                    return data;
                }
            });
            if (!Array.isArray(result.data)) throw new Error('Invalid rail departure board');
            const nowMs = clock();
            const outbound = predictions.filter((row) => row.lineId === lineId
                && row.stopId?.toUpperCase() === stopId && !isSelfReferential(row));
            const uniqueDirection = (rows) => {
                const directions = new Set(rows.map((row) => text(row.direction)?.toLowerCase()).filter(Boolean));
                return directions.size === 1 ? [...directions][0] : null;
            };
            const data = result.data.flatMap((row) => {
                if (!row || (text(row.naptanId) && row.naptanId.toUpperCase() !== stopId)) return [];
                const destinationStopId = text(row.destinationNaptanId)?.toUpperCase();
                const destinationName = text(row.destinationName);
                const status = String(row.departureStatus ?? '').toLowerCase();
                const estimated = Date.parse(row.estimatedTimeOfDeparture);
                const scheduled = Date.parse(row.scheduledTimeOfDeparture);
                const expected = status === 'cancelled' || !Number.isFinite(estimated) ? scheduled : estimated;
                if (!Number.isFinite(expected) || expected <= nowMs || !destinationStopId || !destinationName) return [];
                const platformName = text(row.platformName);
                const arrival = {
                    id: ['departure', lineId, stopId, destinationStopId,
                        Math.floor(expected / 1000), platformName ?? ''].join(':'),
                    vehicleId: null, lineId, stopId, stationName: text(row.stationName),
                    destinationStopId, destinationName, platformName,
                    direction: uniqueDirection(outbound.filter((item) => item.destinationStopId?.toUpperCase() === destinationStopId))
                        ?? uniqueDirection(outbound),
                    expectedArrival: new Date(expected).toISOString(),
                    ...(status === 'cancelled' || status === 'delayed' ? { status } : {})
                };
                return isSelfReferential(arrival) ? [] : [arrival];
            });
            return { data, meta: result.meta };
        }
    };
}
