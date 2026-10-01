import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import express from 'express';
import { defaultDataDirectory } from './push/token-store.js';
import { createRateLimiter } from './push-routes.js';
import { DIRECTION_FILTERS, projectBoard } from './push/departure-projection.js';
import { correctRailBoard } from './push/rail-departures.js';
import { LINE_COLOURS } from './line-colours.js';
import { THAMESLINK_STOP_IDS } from './thameslink.js';

export const MAX_SCHEDULED_JOURNEYS = 3;
const idPattern = /^[A-Za-z0-9-]{8,64}$/;
const tokenPattern = /^[a-f0-9]{64,200}$/i;
const london = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit',
    weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23'
});
const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const modeByLine = new Map(LINE_COLOURS.map((line) => [line.id, line.mode]));

export function londonTime(now) {
    const p = Object.fromEntries(london.formatToParts(now).map(({ type, value }) => [type, value]));
    return { day: weekdays.indexOf(p.weekday) + 1, date: `${p.year}-${p.month}-${p.day}`,
        minute: Number(p.hour) * 60 + Number(p.minute) };
}

// Resolve wall-clock times explicitly. A missing spring-forward time is skipped;
// an autumn repeated time uses its first occurrence. Never exceed two real hours.
export function londonWindow(date, startMinute, endMinute) {
    const resolve = (minute) => {
        const nominal = Date.parse(`${date}T00:00:00Z`) + minute * 60000;
        return [nominal - 3600000, nominal].find((candidate) => {
            const local = londonTime(candidate);
            return local.date === date && local.minute === minute;
        });
    };
    const start = resolve(startMinute);
    const end = resolve(endMinute);
    if (start === undefined || end === undefined || end <= start) return null;
    return { start, end: Math.min(end, start + 120 * 60000) };
}

function fail(message, status = 400) { throw Object.assign(new Error(message), { status }); }
const hash = (secret) => crypto.createHash('sha256').update(secret).digest('hex');

export function validateJourneys(journeys, stationById) {
    if (!Array.isArray(journeys) || journeys.length > MAX_SCHEDULED_JOURNEYS) fail('You can save up to three journeys.');
    const ids = new Set();
    const result = journeys.map((j) => {
        if (!j || typeof j.id !== 'string' || !idPattern.test(j.id) || ids.has(j.id)) fail('Invalid journey identifier.');
        ids.add(j.id);
        if (typeof j.name !== 'string' || j.name.length > 60 || typeof j.enabled !== 'boolean') fail('Invalid journey details.');
        if (!Array.isArray(j.days) || !j.days.length || j.days.length > 7
            || j.days.some((d) => !Number.isInteger(d) || d < 1 || d > 7)) fail('Choose at least one day.');
        const windows = {};
        for (const period of ['morning', 'afternoon']) {
            const w = j[period];
            if (w == null) { windows[period] = null; continue; }
            if (!Number.isInteger(w.startMinute) || !Number.isInteger(w.endMinute)
                || w.startMinute < 0 || w.endMinute >= 1440 || w.endMinute <= w.startMinute
                || w.endMinute - w.startMinute > 120) fail('Each window must be on the same day and last no more than two hours.');
            const b = w.board;
            const station = stationById.get(b?.hubId);
            if (!station || !station.lineIds.includes(b.lineId) || !modeByLine.has(b.lineId)
                || !DIRECTION_FILTERS.includes(b.direction)) fail('Choose a valid station, line and direction.');
            const stopIds = station.stopIds.filter((id) => b.lineId !== 'thameslink' || THAMESLINK_STOP_IDS.has(id));
            if (!stopIds.length) fail('This station does not have a supported departure board.');
            windows[period] = { startMinute: w.startMinute, endMinute: w.endMinute, board: {
                hubId: station.id, stationName: station.name.slice(0, 40), lineId: b.lineId,
                direction: b.direction, stopIds
            } };
        }
        if (!windows.morning && !windows.afternoon) fail('Add a morning or afternoon window.');
        return { id: j.id, name: j.name.trim(), enabled: j.enabled, days: [...new Set(j.days)].sort(), ...windows };
    });
    const slots = result.filter((j) => j.enabled).flatMap((j) =>
        [j.morning, j.afternoon].filter(Boolean).map((w) => ({ ...w, days: j.days })));
    for (let i = 0; i < slots.length; i += 1) {
        for (let k = i + 1; k < slots.length; k += 1) {
            if (slots[i].days.some((d) => slots[k].days.includes(d))
                && slots[i].startMinute < slots[k].endMinute && slots[k].startMinute < slots[i].endMinute) {
                fail('Enabled journey windows cannot overlap on the same days.');
            }
        }
    }
    return result;
}

// A single-process durable store. Serial transactions prevent saves and scheduler
// claims from racing; acknowledge only after atomic replacement succeeds.
export class ScheduledJourneyStore {
    rows = {};
    queue = Promise.resolve();
    constructor({ dataDir = defaultDataDirectory(), filePath = path.join(dataDir, 'scheduled-journeys.json') } = {}) {
        this.filePath = filePath;
    }
    async load() {
        try {
            const data = JSON.parse(await fs.readFile(this.filePath, 'utf8'));
            if (data.version !== 1 || !data.rows || typeof data.rows !== 'object') throw new Error('Invalid schedule store');
            this.rows = data.rows;
        } catch (error) { if (error.code !== 'ENOENT') throw error; }
        return this;
    }
    transaction(action) {
        const operation = this.queue.then(async () => {
            const draft = structuredClone(this.rows);
            const result = await action(draft);
            await fs.mkdir(path.dirname(this.filePath), { recursive: true });
            const temporary = `${this.filePath}.tmp`;
            await fs.writeFile(temporary, JSON.stringify({ version: 1, rows: draft }), { mode: 0o600 });
            await fs.rename(temporary, this.filePath);
            this.rows = draft;
            return result;
        });
        this.queue = operation.catch(() => {});
        return operation;
    }
    authorised(installId, secret) {
        return typeof secret === 'string' && /^[a-f0-9]{64}$/i.test(secret)
            && (!this.rows[installId] || this.rows[installId].secretHash === hash(secret));
    }
    occurrence(installId, activityId) {
        return Object.values(this.rows[installId]?.occurrences ?? {}).find((o) => o.activityId === activityId);
    }
}

export function createScheduledJourneyRoutes({ store, stationById, clock = Date.now }) {
    const router = express.Router();
    const allow = createRateLimiter({ maxRequests: 30 });
    router.use(express.json({ limit: '16kb' }));
    router.use((req, res, next) => {
        res.set('Cache-Control', 'no-store');
        const id = req.get('X-TubeTrack-Install');
        const secret = req.get('X-TubeTrack-Schedule-Key');
        if (!idPattern.test(id ?? '') || !store.authorised(id, secret)) return res.sendStatus(403);
        if (!allow(id)) return res.sendStatus(429);
        req.installId = id;
        req.scheduleSecret = secret;
        next();
    });
    const response = (row) => ({ journeys: row?.journeys ?? [], revision: row?.revision ?? 0,
        maximumJourneys: MAX_SCHEDULED_JOURNEYS });
    const mutate = (req, action) => store.transaction((rows) => {
        // Repeat authentication after acquiring the transaction queue.
        const existing = rows[req.installId];
        if (existing && existing.secretHash !== hash(req.scheduleSecret)) fail('Installation credentials do not match.', 403);
        if (!existing && Object.keys(rows).length >= 10000) fail('Scheduling is temporarily at capacity.', 503);
        const row = existing ?? { secretHash: hash(req.scheduleSecret), journeys: [], revision: 0, occurrences: {} };
        action(row);
        row.updatedAtMs = clock();
        rows[req.installId] = row;
        return response(row);
    });
    router.get('/', (req, res) => res.json(response(store.rows[req.installId])));
    router.put('/', async (req, res) => {
        const journeys = validateJourneys(req.body?.journeys, stationById);
        const result = await mutate(req, (row) => {
            if (req.body.revision !== row.revision) fail('Your journeys changed. Reload and try again.', 409);
            // Cancel occurrences belonging to edited, paused or deleted journeys.
            for (const o of Object.values(row.occurrences)) {
                const old = row.journeys.find((j) => j.id === o.journeyId);
                const next = journeys.find((j) => j.id === o.journeyId);
                if (JSON.stringify(old) !== JSON.stringify(next)) o.cancelled = true;
            }
            row.journeys = journeys;
            row.revision += 1;
            row.savedAtMs = clock();
        });
        res.json(result);
    });
    router.put('/device', async (req, res) => {
        const { token, activitiesEnabled, frequentPushesEnabled, environment } = req.body ?? {};
        if (!tokenPattern.test(token ?? '') || typeof activitiesEnabled !== 'boolean'
            || typeof frequentPushesEnabled !== 'boolean' || !['production', 'sandbox'].includes(environment)) {
            fail('Live Activity setup is incomplete.');
        }
        await mutate(req, (row) => { row.device = { token, activitiesEnabled, frequentPushesEnabled, environment }; });
        res.sendStatus(204);
    });
    router.use((error, req, res, next) => {
        res.status(error.status ?? 503).json({ error: { message: error.status ? error.message : 'Could not save journeys. Please try again.' } });
    });
    return router;
}

export class JourneyScheduler {
    running = null;
    timer = null;
    constructor({ store, pushStore, apns, topic, cache, thameslink, railDepartures, logger, clock = Date.now }) {
        Object.assign(this, { store, pushStore, apns, topic, cache, thameslink, railDepartures, logger, clock });
    }
    start() {
        this.timer = setInterval(() => { void this.tick(); }, 15000);
        this.timer.unref?.();
        void this.tick();
    }
    async stop() { clearInterval(this.timer); await this.running; await this.store.queue; }
    tick() {
        if (this.running) return this.running;
        this.running = this.run().catch((error) => this.logger?.error('journey_scheduler_failed', { error: error.message }))
            .finally(() => { this.running = null; });
        return this.running;
    }
    async initialState(board, now) {
        let predictions;
        let updatedAtMs;
        if (board.lineId === 'thameslink') {
            const result = await this.thameslink.departures(board.stopIds);
            updatedAtMs = Date.parse(result.meta.updatedAt);
            if (result.meta.stale || !Number.isFinite(updatedAtMs) || now - updatedAtMs > 90000) return null;
            predictions = result.data.map((d) => ({ ...d, expectedArrival: d.expectedDeparture }));
        } else {
            const live = this.cache.read();
            const mode = modeByLine.get(board.lineId);
            if (!live || live.staleModes.includes(mode)) return null;
            updatedAtMs = Date.parse(live.snapshot.modeUpdatedAt[mode]);
            if (!Number.isFinite(updatedAtMs) || now - updatedAtMs > 90000) return null;
            predictions = live.snapshot.arrivals;
            const corrected = await correctRailBoard({ arrivals: predictions, ...board,
                source: this.railDepartures, nowMs: now });
            predictions = corrected.arrivals;
            board = { ...board, stopIds: corrected.stopIds };
            updatedAtMs = Math.min(updatedAtMs, corrected.updatedAtMs);
        }
        return { departures: projectBoard({ arrivals: predictions, ...board, limit: 4 }),
            updatedAtEpoch: Math.floor(updatedAtMs / 1000), conditionRank: 3, conditionHeadline: null, sequence: 1 };
    }
    async run() {
        const now = this.clock();
        // End independently of departure polling, including outages and edits.
        for (const row of this.pushStore.all({ type: 'liveActivity' })) {
            if (!row.scheduleId) continue;
            const occurrence = this.store.occurrence(row.installId, row.activityId);
            if (occurrence && !occurrence.cancelled && now < row.hardEndsAtMs) continue;
            const state = { departures: row.lastBoard ?? [], updatedAtEpoch: Math.floor(now / 1000),
                conditionRank: 3, conditionHeadline: 'Tracking finished', sequence: (row.sequence ?? 0) + 1 };
            try {
                const result = await this.apns.send({ token: row.token, topic: this.topic, pushType: 'liveactivity',
                    environment: row.apnsEnvironment, priority: 10, expiration: Math.floor(now / 1000) + 3600,
                    payload: { aps: { timestamp: Math.floor(now / 1000), event: 'end', 'content-state': state,
                        'dismissal-date': Math.floor(now / 1000) } } });
                if (result.ok || result.dead) this.pushStore.delete(row.id);
            } catch (error) { this.logger?.warn('scheduled_end_failed', { error: error.message }); }
        }
        const local = londonTime(now);
        for (const [installId, row] of Object.entries(this.store.rows)) {
            if (!row.device?.activitiesEnabled) continue;
            for (const journey of row.journeys) {
                if (!journey.enabled || !journey.days.includes(local.day)) continue;
                for (const period of ['morning', 'afternoon']) {
                    const w = journey[period];
                    if (!w || local.minute < w.startMinute || local.minute >= w.endMinute
                        || local.minute - w.startMinute > 2) continue;
                    const key = `${journey.id}:${local.date}:${period}`;
                    if (row.occurrences[key]) continue;
                    // A save inside a running window takes effect next time.
                    const dates = londonWindow(local.date, w.startMinute, w.endMinute);
                    if (!dates || now < dates.start || now >= dates.end || now - dates.start > 180000) continue;
                    const startMs = dates.start;
                    if ((row.savedAtMs ?? 0) > startMs) continue;
                    const manual = this.pushStore.all({ type: 'liveActivity' }).some((r) =>
                        r.installId === installId && !r.scheduleId && now < (r.hardEndsAtMs ?? r.startedAtMs + 5400000));
                    let state;
                    if (!manual) {
                        try { state = await this.initialState(w.board, now); } catch { continue; }
                        if (!state) continue;
                    }
                    const activityId = `scheduled-${crypto.randomUUID()}`;
                    const occurrence = { activityId, journeyId: journey.id, board: w.board, state,
                        startedAtMs: startMs, hardEndsAtMs: dates.end,
                        date: local.date, status: manual ? 'manual' : 'claimed' };
                    // Persist before contacting APNs. An ambiguous delivery is never
                    // retried, preventing duplicate activities after a process crash.
                    const claimed = await this.store.transaction((rows) => {
                        const current = rows[installId];
                        if (current.revision !== row.revision || current.occurrences[key]
                            || this.clock() >= dates.end || this.clock() - startMs > 180000) return false;
                        current.occurrences = Object.fromEntries(Object.entries(current.occurrences)
                            .filter(([, o]) => now - o.startedAtMs < 8 * 86400000));
                        current.occurrences[key] = occurrence;
                        return true;
                    });
                    if (!claimed || manual) continue;
                    await this.store.transaction(async (rows) => {
                        const current = rows[installId];
                        const o = current.occurrences[key];
                        const sendTime = this.clock();
                        if (o.cancelled || !current.device.activitiesEnabled || sendTime >= o.hardEndsAtMs
                            || sendTime - o.startedAtMs > 180000) return;
                        if (this.pushStore.all({ type: 'liveActivity' }).some((r) => r.installId === installId
                            && !r.scheduleId && this.clock() < (r.hardEndsAtMs ?? r.startedAtMs + 5400000))) {
                            o.status = 'manual';
                            return;
                        }
                        const b = o.board;
                        const attributes = { activityID: activityId, stationHubID: b.hubId, stationName: b.stationName,
                            lineIDRaw: b.lineId, direction: b.direction === 'any' ? 'Any direction'
                                : b.direction[0].toUpperCase() + b.direction.slice(1),
                            directionFilterRaw: b.direction, startedAtEpoch: Math.floor(o.startedAtMs / 1000),
                            hardEndsAtEpoch: Math.floor(o.hardEndsAtMs / 1000), scheduleID: journey.id };
                        try {
                            const result = await this.apns.send({ token: current.device.token, topic: this.topic,
                                pushType: 'liveactivity', priority: 10, environment: current.device.environment,
                                expiration: Math.min(Math.floor(sendTime / 1000) + 60, attributes.hardEndsAtEpoch),
                                payload: { aps: { timestamp: Math.floor(sendTime / 1000), event: 'start',
                                    'attributes-type': 'DepartureActivityAttributes', attributes,
                                    'content-state': state, 'input-push-token': 1,
                                    'stale-date': Math.min(state.updatedAtEpoch + 180, attributes.hardEndsAtEpoch),
                                    alert: { title: 'Your scheduled journey', body: `${b.stationName} departures are ready.` } } } });
                            o.status = result.ok ? 'sent' : 'rejected';
                            if (result.dead) current.device.activitiesEnabled = false;
                            this.logger?.info('scheduled_start_result', { status: o.status, reason: result.reason });
                        } catch (error) {
                            o.status = 'unknown';
                            this.logger?.warn('scheduled_start_unknown', { error: error.message });
                        }
                    });
                }
            }
        }
    }
}
