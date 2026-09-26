import { Router } from 'express';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

// Verified against /Line/Mode/cable-car on 25 September 2026.
export const CABLE_CAR_ID = 'london-cable-car';
const linePath = `/Line/${CABLE_CAR_ID}`;
const dateOnly = value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
    && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;

export function cableCarStatus(raw) {
    const line = Array.isArray(raw) && raw.find(item => item?.id === CABLE_CAR_ID);
    if (!line || !Array.isArray(line.lineStatuses)) throw new Error('Invalid cable car status');
    return { id: line.id, name: line.name || 'London Cable Car', entries: line.lineStatuses.map((entry, index) => ({
        id: Number.isInteger(entry.id) ? entry.id : index,
        statusSeverity: Number.isInteger(entry.statusSeverity) ? entry.statusSeverity : -1,
        statusSeverityDescription: entry.statusSeverityDescription || 'Status unavailable',
        reason: entry.reason || entry.disruption?.description || null,
        validityPeriods: (entry.validityPeriods || []).map(period => ({
            fromDate: Number.isFinite(Date.parse(period.fromDate)) ? new Date(period.fromDate).toISOString() : null,
            toDate: Number.isFinite(Date.parse(period.toDate)) ? new Date(period.toDate).toISOString() : null,
            isNow: typeof period.isNow === 'boolean' ? period.isNow : null
        }))
    })) };
}

export function cableCarNetwork(stops, sequence) {
    if (!Array.isArray(stops) || sequence?.lineId !== CABLE_CAR_ID) throw new Error('Invalid cable car network');
    const terminals = stops.filter(stop => stop.modes?.includes('cable-car') && Number.isFinite(stop.lat) && Number.isFinite(stop.lon))
        .map(stop => ({ id: stop.id, name: stop.commonName, latitude: stop.lat, longitude: stop.lon }));
    const coordinates = (sequence.lineStrings || []).flatMap(value => JSON.parse(value).flat())
        .map(point => ({ latitude: point[1], longitude: point[0] }));
    if (terminals.length !== 2 || coordinates.length < 2 || coordinates.some(p => !Number.isFinite(p.latitude) || !Number.isFinite(p.longitude))) {
        throw new Error('Incomplete cable car geometry');
    }
    return { id: CABLE_CAR_ID, name: 'London Cable Car', terminals, coordinates };
}

export function cableCarHours(timetable, reviewed) {
    // The API's first/last journeys match the public operating hours. Its
    // synthetic 5/10-minute journeys are NOT cabin departure predictions.
    const schedules = timetable?.timetable?.routes?.flatMap(route => route.schedules || []) || [];
    const groups = { 'Monday - Thursday': ['2', '3', '4', '5'], Friday: ['6'],
        'Saturday (also Good Friday)': ['7'], 'Sunday and other Public Holidays': ['1'] };
    const minutes = journey => Number(journey?.hour) * 60 + Number(journey?.minute);
    const weekly = {};
    for (const schedule of schedules) {
        for (const day of groups[schedule.name] || []) {
            const opens = minutes(schedule.firstJourney), closes = minutes(schedule.lastJourney);
            if (!Number.isInteger(opens) || !Number.isInteger(closes) || opens < 0 || closes > 1440 || closes <= opens) throw new Error('Invalid opening hours');
            weekly[day] = { opens, closes };
        }
    }
    // Changes and conflicting holiday rules require review, not silent adoption.
    if (Object.keys(weekly).length !== 7) throw new Error('Incomplete TfL timetable');
    const isVerified = Object.keys(weekly).every(day =>
        weekly[day].opens === reviewed.weekly[day]?.opens && weekly[day].closes === reviewed.weekly[day]?.closes);
    // A known conflict must invalidate an older cached schedule, whereas a
    // transient network failure can still use its unexpired reviewed policy.
    return { ...reviewed, weekly, isVerified };
}

export function cableCarWorks(raw, from, to) {
    const status = cableCarStatus(raw);
    let undatedCount = 0;
    const works = status.entries.filter(entry => entry.statusSeverity !== 10 && entry.statusSeverity !== 18).flatMap(entry => {
        const periods = entry.validityPeriods.filter(p => p.fromDate && p.toDate && p.fromDate < p.toDate);
        if (!periods.length) undatedCount++;
        return periods.map(period => ({
            id: createHash('sha256').update(JSON.stringify([entry.statusSeverity, entry.reason, period.fromDate, period.toDate])).digest('hex').slice(0, 20),
            title: entry.statusSeverityDescription, reason: entry.reason,
            severity: entry.statusSeverity, start: period.fromDate, end: period.toDate
        }));
    });
    return { from, to, undatedCount, works: [...new Map(works.map(work => [work.id, work])).values()] };
}

export function createCableCarRoutes({ client, resourceCache, hoursLoader = async () =>
    JSON.parse(await readFile(new URL('../data/cable-car-hours.json', import.meta.url))) }) {
    const router = Router();
    const fetch = path => client.fetchJSON(path, { metricLabel: 'cable-car' });
    const route = handler => async (req, res) => {
        try { await handler(req, res); }
        catch { res.status(503).json({ error: { code: 'CABLE_CAR_UNAVAILABLE', message: 'Cable car data is temporarily unavailable' } }); }
    };
    router.get('/network', route(async (_, res) => {
        const snapshot = await resourceCache.get('cable-car:network', { freshForMs: 86_400_000,
            load: async () => cableCarNetwork(...await Promise.all([fetch(`${linePath}/StopPoints`), fetch(`${linePath}/Route/Sequence/outbound`)])) });
        res.set('Cache-Control', 'public, max-age=3600').json(snapshot);
    }));
    router.get('/status', route(async (_, res) => {
        const snapshot = await resourceCache.get('cable-car:status', { freshForMs: 60_000,
            load: async () => cableCarStatus(await fetch(`${linePath}/Status?detail=true`)) });
        res.set('Cache-Control', 'public, max-age=30').json(snapshot);
    }));
    router.get('/hours', route(async (_, res) => {
        const snapshot = await resourceCache.get('cable-car:hours', { freshForMs: 21_600_000,
            load: async () => cableCarHours(await fetch(`${linePath}/Timetable/940GZZALGWP`), await hoursLoader()) });
        res.set('Cache-Control', 'public, max-age=3600').json(snapshot);
    }));
    router.get('/planned-works', route(async (req, res) => {
        const { from, to } = req.query;
        if (!dateOnly(from) || !dateOnly(to) || from > to || Date.parse(to) - Date.parse(from) > 62 * 86_400_000) {
            res.status(400).json({ error: { code: 'INVALID_DATE_RANGE', message: 'Use a valid range of at most 62 days' } }); return;
        }
        const snapshot = await resourceCache.get(`cable-car:works:${from}:${to}`, { freshForMs: 600_000,
            load: async () => cableCarWorks(await fetch(`${linePath}/Status/${from}/to/${to}?detail=true`), from, to) });
        res.set('Cache-Control', 'public, max-age=300').json(snapshot);
    }));
    return router;
}
