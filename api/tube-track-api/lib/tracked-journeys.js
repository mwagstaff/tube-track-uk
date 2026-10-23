import express from 'express';
import { railClockDate } from './push/national-rail-departures.js';
import { randomUUID, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { ScheduledJourneyStore, londonTime } from './scheduled-journeys.js';
import { createRateLimiter } from './push-routes.js';

const stops = JSON.parse(readFileSync(new URL('../data/departure-stops.json', import.meta.url)));
const station = id => stops.find(s => s.id === id || s.stopIDs.includes(id) || s.railCodes.includes(id));
const transit = leg => !['walking', 'transfer'].includes(leg.mode);
const indices = plan => plan.legs.flatMap((leg, i) => transit(leg) ? [i] : []);
export function scheduleDue(schedule, now) {
    if (schedule.date) return Date.parse(schedule.date);
    const local = londonTime(now);
    if (!schedule.days.includes(local.day)) return null;
    const nominal = Date.parse(`${local.date}T00:00:00Z`) + schedule.minute * 60000;
    return [nominal - 3600000, nominal].find(time => {
        const value = londonTime(time); return value.date === local.date && value.minute === schedule.minute;
    }) ?? null;
}
const epoch = date => Math.floor(Date.parse(date) / 1000);
const fail = (message, status = 400) => { throw Object.assign(new Error(message), { status }); };
const hash = text => createHash('sha256').update(text).digest('hex');
const tokenOK = value => typeof value === 'string' && /^[a-f0-9]{64,200}$/i.test(value);
const signature = plan => plan.legs.filter(transit).map(l => `${station(l.from.id)?.id}:${station(l.to.id)?.id}:${l.lines.map(l => l.operatorCode ?? l.id).sort().join(',')}`).join('|');

export function routeBoard(leg) {
    const from = station(leg.from.id), to = station(leg.to.id);
    if (!from || !to || leg.mode === 'replacement-bus') return null;
    return { originID: from.id, destinationIDs: [to.id], lineIDs: leg.lines.map(l =>
        l.operatorCode && !['LO', 'XR', 'TL'].includes(l.operatorCode) ? `national-rail:${l.operatorCode}` : l.id) };
}

export function journeyProjection(session, boards, now = Date.now()) {
    const plan = session.plan, list = indices(plan), current = plan.legs[session.legIndex];
    const nextIndex = list.find(i => i > session.legIndex);
    const boardIndex = session.phase === 'onboard' ? nextIndex : session.legIndex;
    let ready = now, nextArrival = null, finalArrival = null, uncertain = false;
    const messages = [];
    for (const index of list.filter(i => i >= session.legIndex)) {
        const leg = plan.legs[index], board = boards[index];
        const fresh = board && !board.stale && !board.unavailableSources && now - Date.parse(board.updatedAt) < 90000;
        const rows = fresh ? board.arrivals.filter(r => r.status !== 'cancelled' && r.expectedArrival) : [];
        let arrival;
        if (index === session.legIndex && session.phase === 'onboard') {
            // Boarding confirmation anchors this service, never swap to another train after departure.
            const exact = rows.find(r => r.id === session.boardedID);
            const departure = exact ? Date.parse(exact.expectedArrival) : session.boardedAt;
            arrival = session.liveArrival?.checkedAt > now - 90000 ? session.liveArrival.time : departure + leg.durationMinutes * 60000;
            if (session.liveArrival?.checkedAt <= now - 90000 || !session.liveArrival) uncertain = true;
            if (session.liveArrival?.reason) messages.push(session.liveArrival.reason);
            if (arrival != null && arrival < now) { arrival = null; messages.push('Arrival needs confirming · update your current leg'); }
        } else {
            if (index > session.legIndex) {
                const previousIndex = list[list.indexOf(index) - 1];
                // Include walking/transfer duration, not the original wait for a specific train.
                ready += Math.max(2, plan.legs.slice(previousIndex + 1, index)
                    .reduce((n, l) => n + l.durationMinutes, 0)) * 60000;
            }
            const departure = rows.find(r => Date.parse(r.expectedArrival) >= ready);
            if (departure) {
                arrival = Date.parse(departure.expectedArrival) + leg.durationMinutes * 60000;
                if (Date.parse(departure.expectedArrival) > Date.parse(leg.departureTime) + 60000) messages.push('Connection changed · showing the next suitable service');
            } else {
                // Do not invent a catchable departure once the original timetable has passed.
                const scheduled = Date.parse(leg.departureTime);
                arrival = scheduled >= ready ? Date.parse(leg.arrivalTime) : null;
                uncertain = true;
                if (!arrival) messages.push('Connection needs checking · no confirmed onward departure');
            }
        }
        if (index === session.legIndex) nextArrival = arrival;
        if (arrival == null) { finalArrival = null; break; }
        ready = arrival; finalArrival = arrival;
    }
    if (finalArrival != null) finalArrival += plan.legs.slice(list.at(-1) + 1).reduce((n, l) => n + l.durationMinutes, 0) * 60000;
    const visible = boards[boardIndex];
    const updated = visible ? epoch(visible.updatedAt) : Math.floor(now / 1000);
    const departures = (visible?.arrivals ?? []).filter(r => !r.expectedArrival || Date.parse(r.expectedArrival) >= now).slice(0, 3).map(r => ({ id: r.id,
        destination: String(r.destinationName ?? 'Check front of train').slice(0, 50),
        platform: r.platformName ?? r.platform ?? null,
        expectedAtEpoch: r.expectedArrival ? epoch(r.expectedArrival) : null,
        status: r.status ?? null }));
    return { phase: session.phase, legIndex: session.legIndex,
        headline: session.phase === 'complete' ? 'Journey complete' : session.phase === 'onboard' ? `Towards ${current.to.name}` : `Board at ${current.from.name}`,
        nextStop: current.to.name, destination: plan.legs.at(-1).to.name,
        nextArrivalEpoch: nextArrival ? Math.floor(nextArrival / 1000) : null,
        finalArrivalEpoch: finalArrival ? Math.floor(finalArrival / 1000) : null,
        boardTitle: boardIndex == null ? null : `${plan.legs[boardIndex].from.name} → ${plan.legs[boardIndex].to.name}`,
        departures, updatedAtEpoch: updated, staleAtEpoch: updated + 90,
        message: [...new Set([...messages, ...(visible?.conditionHeadline ? [visible.conditionHeadline] : []),
            ...(session.notificationMessage ? [session.notificationMessage] : []), ...(uncertain ? ['Arrival times are estimates; confirm your progress if location is unavailable.'] : [])])].join(' ').slice(0, 240),
        sequence: session.revision };
}

export class TrackedJourneys {
    constructor({ store, planner, boards, apns, topic, logger, clock = Date.now, fetch: fetcher = globalThis.fetch }) {
        Object.assign(this, { store, planner, boards, apns, topic, logger, clock });
        this.fetch = fetcher; this.busy = false; this.pending = new Set(); this.stopping = false;
    }
    start() { this.timer = setInterval(() => void this.tick().catch(() => this.logger?.warn('tracked_journey_tick_failed')), 30000); this.timer.unref(); }
    async stop() { this.stopping = true; clearInterval(this.timer); await this.running; await Promise.allSettled([...this.pending]); }
    view(row) { return { active: row?.active ? { ...row.active, token: undefined } : null, schedules: row?.schedules ?? [], revision: row?.revision ?? 0 }; }
    selected(searchID, journeyID) {
        const result = this.planner.jobs.get(searchID)?.result;
        const plan = result?.data.journeys.find(j => j.id === journeyID);
        if (!plan) fail('Search again to select a route.', 409);
        return structuredClone(plan);
    }
    session(plan, scheduleID = null) {
        if (!indices(plan).length || indices(plan).some(i => !routeBoard(plan.legs[i]))) fail('This route includes a service that cannot yet be tracked.');
        return { id: randomUUID(), plan, scheduleID, legIndex: indices(plan)[0], phase: 'waiting', revision: 0,
            startedAt: new Date(this.clock()).toISOString(), endsAt: new Date(Math.min(this.clock() + 7 * 3600000,
                Math.max(this.clock() + 3600000, Date.parse(plan.arrivalTime) + 3600000))).toISOString() };
    }
    async snapshot(session) {
        const boards = {};
        for (const index of indices(session.plan).filter(i => i >= session.legIndex)) {
            try { boards[index] = await this.boards.board(routeBoard(session.plan.legs[index])); }
            catch { /* Projection explicitly labels unavailable predictions. */ }
        }
        let liveArrival = null;
        if (session.phase === 'onboard') {
            try { liveArrival = await this.arrival(session); } catch { /* Keep estimates explicitly labelled. */ }
        }
        const refreshed = { ...session, liveArrival };
        return { ...refreshed, state: journeyProjection(refreshed, boards, this.clock()), boards };
    }
    async arrival(session) {
        const leg = session.plan.legs[session.legIndex], target = station(leg.to.id);
        if (session.boardedVehicleID && session.boardedVehicleID !== '000') {
            const board = await this.boards.board({ originID: target.id, destinationIDs: [], lineIDs: routeBoard(leg).lineIDs });
            if (board.stale || board.unavailableSources || this.clock() - Date.parse(board.updatedAt) > 90000) return null;
            const matches = board.arrivals.filter(r => r.vehicleId === session.boardedVehicleID && r.expectedArrival && r.status !== 'cancelled');
            if (matches.length === 1) return { time: Date.parse(matches[0].expectedArrival), checkedAt: Date.parse(board.updatedAt) };
        }
        const reference = /^national-rail:([A-Z]{3}):(.+)$/.exec(session.boardedID ?? '');
        if (!reference) return null;
        const response = await this.fetch(`https://api.skynolimit.dev/train-track/api/v2/service_details/${encodeURIComponent(reference[2])}?fromCRS=${reference[1]}`,
            { redirect: 'error', signal: AbortSignal.timeout(8000), headers: { Accept: 'application/json' } });
        if (!response.ok) return null;
        const body = await response.json();
        const details = (body.data ?? body)?.[0]?.[reference[2]];
        if (!details || details.crs !== reference[1]) return null;
        if (details.isCancelled) return { time: null, checkedAt: this.clock(), reason: 'This service is cancelled. Check an alternative route.' };
        const calls = (details.subsequentCallingPoints ?? []).filter(g => !g.serviceChangeRequired && !g.assocIsCancelled)
            .flatMap(g => g.callingPoint ?? []).filter(c => target.railCodes.includes(c.crs));
        if (calls.length !== 1) return null;
        const call = calls[0], estimate = call.at || call.et;
        if (call.isCancelled || String(estimate).toLowerCase() === 'cancelled') return { time: null, checkedAt: this.clock(), reason: 'The call at your next stop is cancelled. Check an alternative route.' };
        const value = ['on time', 'ontime'].includes(String(estimate).toLowerCase()) ? call.st : estimate;
        const time = railClockDate(value, Date.parse(leg.arrivalTime));
        return time == null ? null : { time, checkedAt: this.clock() };
    }
    async push(session, device, event = 'update') {
        const token = event === 'start' ? device?.token : session.token;
        if (!this.apns || !token) return;
        const now = Math.floor(this.clock() / 1000);
        const aps = { timestamp: now, event, 'content-state': session.state,
            'stale-date': session.state.staleAtEpoch };
        if (event === 'start') Object.assign(aps, { 'attributes-type': 'JourneyActivityAttributes',
            attributes: { sessionID: session.id, destination: session.state.destination, endsAtEpoch: epoch(session.endsAt) },
            'input-push-token': 1, alert: { title: 'Your journey is ready', body: session.state.headline } });
        if (event === 'end') aps['dismissal-date'] = now;
        const result = await this.apns.send({ token, topic: this.topic, pushType: 'liveactivity', activityId: session.id,
            environment: session.environment ?? device?.environment, priority: event === 'update' ? 5 : 10,
            expiration: event === 'start' ? now + 60 : event === 'end' ? now + 3600 : epoch(session.endsAt), payload: { aps } });
        if (result.dead) return event === 'end';
        return result.ok;
    }
    async finish(row, session) {
        row.endings ??= [];
        if (!row.endings.some(s => s.id === session.id)) row.endings.push(session);
        try {
            if (await this.push(session, row.device, 'end') === true || !session.token) {
                row.endings = row.endings.filter(s => s.id !== session.id);
            }
        } catch { /* End delivery retries independently of live departure feeds. */ }
    }
    async tick() {
        if (this.busy) return;
        this.busy = true;
        this.running = this.run();
        try { await this.running; } finally { this.busy = false; }
    }
    async run() {
        const now = this.clock();
        for (const [id, row] of Object.entries(this.store.rows)) {
            if (this.stopping) return;
            if (row.endings?.length) await this.store.transaction(async rows => {
                const current = rows[id];
                for (const session of [...current.endings]) {
                    if (now > Date.parse(session.endsAt) + 86400000) current.endings = current.endings.filter(s => s.id !== session.id);
                    else await this.finish(current, session);
                }
            });
            if (row.active) {
                const original = row.active;
                const session = await this.snapshot(original);
                if (now >= Date.parse(session.endsAt)) session.phase = 'complete';
                session.state.phase = session.phase;
                // Recheck revision under the transaction before pushing, so a late poll cannot undo a correction.
                await this.store.transaction(async rows => {
                    const current = rows[id]?.active;
                    if (!current || current.id !== session.id || current.revision !== session.revision) return;
                    session.token = current.token; session.environment = current.environment;
                    session.revision++; session.state.sequence = session.revision;
                    rows[id].active = session; rows[id].revision++;
                    try {
                        if (session.phase === 'complete') await this.finish(rows[id], session);
                        else await this.push(session, rows[id].device, 'update');
                    }
                    catch { this.logger?.warn('tracked_journey_push_failed', { activityId: session.id }); }
                    if (session.phase === 'complete') rows[id].active = null;
                });
            }
            for (const schedule of row.schedules ?? []) {
                if (!schedule.enabled || !row.device?.token || row.device.activitiesEnabled === false || this.pending.size >= 2) continue;
                const local = londonTime(now);
                const due = scheduleDue(schedule, now);
                if (due == null || now < due || now - due > 180000) continue;
                const key = `${schedule.id}:${local.date}`;
                if (row.claims?.[key]) continue;
                const claim = await this.store.transaction(rows => {
                    const current = rows[id];
                    if (current.claims?.[key] || !current.schedules.some(s => s.id === schedule.id && s.enabled)) return false;
                    current.claims = Object.fromEntries(Object.entries(current.claims ?? {}).filter(([, t]) => now - t < 8 * 86400000));
                    current.claims[key] = now;
                    const saved = current.schedules.find(s => s.id === schedule.id);
                    if (current.active && saved) {
                        saved.message = 'This occurrence was skipped because another journey was active.';
                        if (saved.date) saved.enabled = false;
                        current.revision++;
                    }
                    return !current.active;
                });
                if (!claim) continue;
                const work = this.startScheduled(id, schedule, due);
                this.pending.add(work);
                void work.finally(() => this.pending.delete(work)).catch(() => this.logger?.warn('tracked_journey_schedule_failed'));

            }
        }
    }
    async startScheduled(id, schedule, due) {
        try {
            const plan = await this.resolve(schedule, id);
            const session = await this.snapshot(this.session(plan, schedule.id));
            // Persist the session before APNs: a crash after delivery must still allow
            // the awakened app to register its update token and resume this route.
            const prepared = await this.store.transaction(rows => {
                const current = rows[id];
                const saved = current.schedules.find(s => s.id === schedule.id && s.enabled);
                if (current.active || current.device?.activitiesEnabled === false || !saved) return false;
                if (this.clock() - due > 180000) throw new Error('Scheduled start expired');
                current.active = session; current.revision++;
                if (saved.date) { saved.enabled = false; saved.message = 'This one-off journey has started.'; }
                else delete saved.message;
                return true;
            });
            if (!prepared) return;
            await this.store.transaction(async rows => {
                const current = rows[id];
                if (current.active?.id !== session.id || current.device?.activitiesEnabled === false
                    || this.clock() - due > 180000) return;
                try {
                    const sent = await this.push(current.active, current.device, 'start');
                    if (sent === false) current.active.notificationMessage = 'Live Activity could not start. Follow this journey in the app.';
                } catch {
                    current.active.notificationMessage = 'Live Activity delivery is unconfirmed. Follow this journey in the app.';
                    this.logger?.warn('tracked_journey_start_unknown', { activityId: session.id });
                }
            });
        } catch {
            await this.store.transaction(rows => {
                const saved = rows[id].schedules.find(s => s.id === schedule.id);
                if (saved) {
                    if (saved.date) saved.enabled = false;
                    saved.message = 'Could not refresh this route for the scheduled start. Open Journeys to search again.';
                    rows[id].revision++;
                }
            });
        }
    }
    async resolve(schedule, client) {
        const legs = schedule.plan.legs.filter(transit);
        const via = [...new Set(legs.slice(0, -1).map(l => l.to.id))];
        if (via.length > 4) fail('This route has too many changes to schedule.');
        const query = { from: legs[0].from.id, to: legs.at(-1).to.id, timeMode: 'now',
            accessibility: schedule.accessibility ?? 'none', ...(via.length ? { via: via.join(',') } : {}) };
        let job = await this.planner.start(query, client);
        const id = job.id;
        try {
            const deadline = this.clock() + 170000;
            while (job.status !== 'completed') {
                if (this.stopping || job.status === 'failed' || this.clock() > deadline) fail('Scheduled search failed.');
                await new Promise(resolve => setTimeout(resolve, 1000));
                job = await this.planner.poll(id);
            }
            const plan = job.result.data.journeys.find(j => signature(j) === signature(schedule.plan));
            if (!plan) fail('The selected route is unavailable; choose an alternative.');
            return plan;
        } finally { await this.planner.cancel(id); }
    }
}

export function trackedJourneyRoutes(service) {
    const router = express.Router(), allow = createRateLimiter({ maxRequests: 90 });
    router.use(express.json({ limit: '8kb' }));
    router.use((req, res, next) => {
        res.set('Cache-Control', 'no-store');
        const id = req.get('X-TubeTrack-Install'), secret = req.get('X-TubeTrack-Schedule-Key');
        if (!/^[A-Za-z0-9-]{8,64}$/.test(id ?? '') || !service.store.authorised(id, secret)) return res.sendStatus(403);
        if (!allow(id)) return res.sendStatus(429);
        req.installID = id; req.secret = secret; next();
    });
    const mutate = (req, action) => service.store.transaction(async rows => {
        if (!service.store.authorised(req.installID, req.secret)) fail('Credentials changed.', 403);
        if (!rows[req.installID] && Object.keys(rows).length >= 10000) fail('Journey tracking is at capacity.', 503);
        const row = rows[req.installID] ??= { secretHash: hash(req.secret), schedules: [], active: null, revision: 0 };
        await action(row); row.revision++;
        return service.view(row);
    });
    const handle = action => async (req, res, next) => { try { res.json({ data: await action(req) }); } catch (e) { next(e); } };
    router.get('/', handle(req => service.view(service.store.rows[req.installID])));
    router.post('/start', handle(async req => {
        const plan = service.selected(req.body.searchID, req.body.journeyID);
        if (Date.parse(plan.departureTime) < service.clock() - 60000 || Date.parse(plan.departureTime) > service.clock() + 2 * 3600000) fail('Refresh this route before starting.', 409);
        const session = await service.snapshot(service.session(plan));
        return mutate(req, async row => {
            if (row.active) {
                if (row.active.id !== req.body.replaceID || row.active.revision !== req.body.replaceRevision) fail('Your active journey changed. Review it before replacing it.', 409);
                await service.finish(row, row.active);
            }
            row.active = session;
        });
    }));
    router.put('/device', handle(req => mutate(req, row => {
        if (!tokenOK(req.body.token) || !['sandbox', 'production'].includes(req.body.environment)) fail('Invalid push registration.');
        row.device = { token: req.body.token, environment: req.body.environment, activitiesEnabled: req.body.activitiesEnabled !== false };
    })));
    router.put('/progress', handle(req => mutate(req, async row => {
        const s = row.active;
        if (!s || s.id !== req.body.id || s.revision !== req.body.revision) fail('Journey progress changed. Refresh and retry.', 409);
        if (!indices(s.plan).includes(req.body.legIndex) || !['waiting', 'onboard', 'complete'].includes(req.body.phase)) fail('Invalid journey progress.');
        s.legIndex = req.body.legIndex; s.phase = req.body.phase; s.revision++;
        const board = s.boards?.[s.legIndex];
        const selected = board && !board.stale && !board.unavailableSources && service.clock() - Date.parse(board.updatedAt) < 90000
            ? board.arrivals.find(r => r.id === req.body.boardedID && r.status !== 'cancelled') : null;
        if (req.body.boardedID && !selected) fail('This departure is no longer available. Refresh the board.');
        s.boardedID = selected?.id ?? null;
        s.boardedVehicleID = selected?.vehicleId ?? null;
        s.boardedService = selected ?? null;
        s.liveArrival = null;
        s.boardedAt = selected?.expectedArrival ? Date.parse(selected.expectedArrival) : service.clock();
        s.state = journeyProjection(s, s.boards ?? {}, service.clock());
        if (s.phase === 'complete') {
            await service.finish(row, s);
            row.active = null;
        }
    })));
    router.put('/token', handle(req => mutate(req, row => {
        if (!row.active || row.active.id !== req.body.id) fail('Journey ended.', 409);
        if (!tokenOK(req.body.token) || !['sandbox', 'production'].includes(req.body.environment)) fail('Invalid update address.');
        row.active.token = req.body.token; row.active.environment = req.body.environment;
    })));
    router.post('/schedules', handle(req => {
        const plan = service.selected(req.body.searchID, req.body.journeyID);
        service.session(plan); // Validate all board identities before accepting a recurring route.
        if (plan.legs.filter(transit).length > 5) fail('Schedule routes with up to four changes.');
        const date = req.body.date, days = req.body.days ?? [], minute = req.body.minute;
        if (!Array.isArray(days) || days.length > 7 || days.some(d => !Number.isInteger(d) || d < 1 || d > 7)) fail('Choose valid repeat days.');
        if (date ? !Number.isFinite(Date.parse(date)) || Date.parse(date) <= service.clock() || Date.parse(date) > service.clock() + 60 * 86400000
            : !Array.isArray(days) || !days.length || days.some(d => !Number.isInteger(d) || d < 1 || d > 7)
                || !Number.isInteger(minute) || minute < 0 || minute > 1439) fail('Choose a future date or valid repeat days and London time.');
        return mutate(req, row => {
            if (!service.apns || !row.device || row.device.activitiesEnabled === false) fail('Enable Live Activities before scheduling a route.');
            if (row.schedules.length >= 3) fail('You can save up to three complete routes.');
            row.schedules.push({ id: randomUUID(), plan, date: date ?? null, days, minute: minute ?? 0,
                accessibility: service.planner.jobs.get(req.body.searchID)?.request.accessibility ?? 'none', enabled: true });
        });
    }));
    router.delete('/schedules/:id', handle(req => mutate(req, async row => {
        row.schedules = row.schedules.filter(s => s.id !== req.params.id);
        if (row.active?.scheduleID === req.params.id) {
            await service.finish(row, row.active);
            row.active = null;
        }
    })));
    return router;
}

export { ScheduledJourneyStore as TrackedJourneyStore };
