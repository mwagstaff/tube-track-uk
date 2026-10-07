import { readFileSync } from 'node:fs';
import { MAXIMUM_DEPARTURES, destinationLabel, compactPlatformLabel } from './departure-projection.js';
import { nationalRailDirection } from './national-rail-direction.js';

export const NATIONAL_RAIL_CODES_BY_STATION = JSON.parse(readFileSync(
    new URL('../../data/national-rail-stations.json', import.meta.url), 'utf8'));

export function isNationalRailOperator(lineId) {
    return typeof lineId === 'string' && /^national-rail:[^\x00-\x1f]{1,60}$/.test(lineId);
}

const londonClock = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', hour: '2-digit', minute: '2-digit', hourCycle: 'h23'
});
const text = (value) => typeof value === 'string' ? value.trim() : '';

/** Mirrors NationalRailDeparture.clockDate, including midnight and both DST folds. */
export function railClockDate(value, referenceMs) {
    if (!/^\d{2}:\d{2}$/.test(value ?? '') || !Number.isFinite(referenceMs)) return null;
    const [hour, minute] = value.split(':').map(Number);
    if (hour > 23 || minute > 59) return null;
    const utcDay = Math.floor(referenceMs / 86_400_000) * 86_400_000;
    const candidates = [];
    for (const day of [-1, 0, 1]) {
        for (const offset of [0, 60]) {
            const candidate = utcDay + day * 86_400_000 + (hour * 60 + minute - offset) * 60_000;
            if (Math.abs(candidate - referenceMs) <= 12 * 3_600_000
                && londonClock.format(candidate) === value) candidates.push(candidate);
        }
    }
    candidates.sort((a, b) => Math.abs(a - referenceMs) - Math.abs(b - referenceMs));
    return candidates[0] ?? null;
}

export function nationalRailPredictions(board, crs, nowMs, { includeThameslink = false } = {}) {
    if (!Array.isArray(board?.departures)) throw new Error('Invalid National Rail board');
    const referenceMs = Date.parse(board.lastSuccessfulUpdate);
    const seen = new Set();
    return board.departures.flatMap((row) => {
        const code = text(row.operatorCode).toUpperCase();
        const name = text(row.operator);
        const excludedCodes = includeThameslink ? ['LO', 'XR'] : ['TL', 'LO', 'XR'];
        const excludedNames = includeThameslink ? ['london overground', 'elizabeth line', 'tfl rail']
            : ['thameslink', 'london overground', 'elizabeth line', 'tfl rail'];
        if (!text(row.serviceID) || excludedCodes.includes(code) || excludedNames.includes(name.toLowerCase())
            || (row.serviceType && row.serviceType.toLowerCase() !== 'train')) return [];
        const scheduled = railClockDate(row.departure_time?.scheduled, referenceMs);
        if (scheduled === null) return [];
        const destinations = Array.isArray(row.destination) ? row.destination : row.destination ? [row.destination] : [];
        if (destinations.length === 1 && destinations[0].crs === crs) return [];
        const estimate = text(row.departure_time?.estimated);
        const cancelled = row.isCancelled === true || estimate.toLowerCase() === 'cancelled';
        const forecast = railClockDate(estimate, scheduled);
        const onTime = ['on time', 'ontime'].includes(estimate.toLowerCase());
        const expected = cancelled || onTime ? scheduled : forecast;
        const actual = railClockDate(row.departure_time?.actual, scheduled);
        if ((actual !== null && actual <= nowMs) || (expected ?? referenceMs) < nowMs - 60_000) return [];
        const status = cancelled ? 'cancelled'
            : estimate.toLowerCase() === 'delayed' || (forecast !== null && forecast - scheduled >= 60_000)
                ? 'delayed' : null;
        const id = `national-rail:${crs}:${row.serviceID}`;
        if (seen.has(id)) return [];
        seen.add(id);
        const platform = row.platformIsHidden ? '' : text(row.platform);
        return [{ id, lineId: `national-rail:${code || name.toLowerCase() || 'unknown'}`, stopId: crs,
            direction: nationalRailDirection({ station: crs, destinations: destinations.map((item) => text(item.crs)) }),
            destinationName: destinations.map((item) => text(item.locationName)).filter(Boolean).join(' & ') || 'Check station screens',
            platformName: platform ? `Platform ${platform}` : 'Platform to be confirmed',
            expectedArrival: expected === null ? null : new Date(expected).toISOString(),
            scheduledDeparture: new Date(scheduled).toISOString(), hasExpectedTime: expected !== null,
            ...(status ? { status } : {}) }];
    });
}

export function projectNationalRailBoard({ arrivals, lineId, direction = 'any' }) {
    const rows = arrivals.filter((row) => row.lineId === lineId
        && (direction === 'any' || row.direction === direction)).sort((a, b) =>
        Date.parse(a.expectedArrival ?? a.scheduledDeparture) - Date.parse(b.expectedArrival ?? b.scheduledDeparture)
            || a.id.localeCompare(b.id));
    const seen = new Set();
    return rows.filter((row) => !seen.has(row.id) && seen.add(row.id))
        .slice(0, MAXIMUM_DEPARTURES).map((row) => ({ id: row.id,
            destination: destinationLabel(row).slice(0, 28),
            platform: compactPlatformLabel(row)?.slice(0, 14) ?? null,
            expectedAtEpoch: Math.round(Date.parse(row.expectedArrival ?? row.scheduledDeparture) / 1000),
            hasExpectedTime: row.hasExpectedTime,
            ...(row.status ? { status: row.status } : {}) }));
}

export function nationalRailCondition(arrivals, lineId, direction = 'any') {
    const rows = arrivals.filter((row) => row.lineId === lineId && (direction === 'any' || row.direction === direction));
    if (rows.some((row) => row.status === 'cancelled')) return { rank: 1, headline: 'Cancellations' };
    if (rows.some((row) => row.status === 'delayed')) return { rank: 1, headline: 'Delays' };
    if (!rows.length || rows.some((row) => !row.hasExpectedTime)) return { rank: 3, headline: 'Updating' };
    return { rank: 4, headline: 'Departures on time' };
}

/** TrainTrack already maintains the live railway boards; share its cached feed. */
export function createNationalRailDepartureSource({ resourceCache, fetchImpl = fetch, clock = Date.now,
    baseUrl = 'https://api.skynolimit.dev/train-track/' }) {
    return {
        async departures(crs, { includeThameslink = false } = {}) {
            if (!/^[A-Z]{3}$/.test(crs)) throw new Error('Invalid railway station code');
            const result = await resourceCache.get(`national-rail-departures:${crs}`, {
                freshForMs: 30_000,
                load: async () => {
                    const response = await fetchImpl(new URL(`api/v2/departures/from/${crs}`, baseUrl), {
                        signal: AbortSignal.timeout(8_000), headers: { accept: 'application/json' }
                    });
                    if (!response.ok) throw new Error(`National Rail returned HTTP ${response.status}`);
                    const board = await response.json();
                    if (!Array.isArray(board?.departures)) throw new Error('Invalid National Rail board');
                    return board;
                }
            });
            const updatedAtMs = Date.parse(result.data.lastSuccessfulUpdate);
            const nowMs = clock();
            if (result.meta.stale || result.data.dataStatus !== 'live' || !Number.isFinite(updatedAtMs)
                || nowMs - updatedAtMs > 90_000) throw new Error('National Rail board is stale');
            return { data: nationalRailPredictions(result.data, crs, nowMs, { includeThameslink }),
                meta: { updatedAt: new Date(updatedAtMs).toISOString(), stale: false } };
        }
    };
}
