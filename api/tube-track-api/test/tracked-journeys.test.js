import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { TrackedJourneys, TrackedJourneyStore, trackedJourneyRoutes, journeyProjection, routeBoard, scheduleDue } from '../lib/tracked-journeys.js';
import { combineViaChoices, validateCombinedQuery, CombinedJourneys } from '../lib/combined-journeys.js';

const now = Date.parse('2026-10-23T11:00:00Z');
const at = minutes => new Date(now + minutes * 60000).toISOString();
const point = (id, name) => ({ id, name });
const endpoints = [point('nr:CLK', 'Clock House'), point('HUBLEW', 'Lewisham'), point('HUBCAW', 'Canary Wharf'), point('HUBSRA', 'Stratford')];
const leg = (i, departure, arrival) => ({ id: String(i), mode: i ? 'dlr' : 'national-rail', from: endpoints[i], to: endpoints[i + 1],
    departureTime: at(departure), arrivalTime: at(arrival), durationMinutes: arrival - departure, instruction: 'Travel', timing: 'estimated',
    lines: [{ id: i ? 'dlr' : 'southeastern', name: i ? 'DLR' : 'Southeastern', ...(i ? {} : { operatorCode: 'SE' }) }], stops: [], warnings: [] });
const plan = { id: 'route', departureTime: at(2), arrivalTime: at(50), durationMinutes: 48, changes: 2,
    walkingMinutes: 0, waitingMinutes: 0, warnings: [], labels: [], legs: [leg(0, 2, 12), leg(1, 17, 32), leg(2, 37, 50)] };
const row = (id, minute, extra = {}) => ({ id, destinationName: 'Stratford', expectedArrival: at(minute), ...extra });
const board = arrivals => ({ arrivals, updatedAt: at(0), stale: false, unavailableSources: 0 });
const session = { id: 'trip', plan, legIndex: 1, phase: 'onboard', boardedAt: now, boardedID: 'my-train', revision: 3 };

test('route boards preserve the operator and required intermediate calling stop', () => {
    assert.deepEqual(routeBoard(plan.legs[0]), { originID: 'nr:CLK', destinationIDs: ['HUBLEW'], lineIDs: ['national-rail:SE'] });
    assert.deepEqual(routeBoard(plan.legs[1]), { originID: 'HUBLEW', destinationIDs: ['HUBCAW'], lineIDs: ['dlr'] });
});

test('Lewisham to Canary Wharf prioritises Canary Wharf onward departures and both ETAs', () => {
    const state = journeyProjection(session, { 2: board([row('missed', 16), row('catchable', 20)]) }, now);
    assert.equal(state.boardTitle, 'Canary Wharf → Stratford');
    assert.equal(state.nextArrivalEpoch, now / 1000 + 15 * 60);
    assert.equal(state.finalArrivalEpoch, now / 1000 + 33 * 60);
});

test('delayed inbound train skips an uncatchable connection; cancellation cannot supply an ETA', () => {
    const state = journeyProjection({ ...session, liveArrival: { time: now + 24 * 60000, checkedAt: now } },
        { 2: board([row('missed', 25), row('cancelled', 27, { status: 'cancelled' }), row('catchable', 30)]) }, now);
    assert.equal(state.nextArrivalEpoch, now / 1000 + 24 * 60);
    assert.equal(state.finalArrivalEpoch, now / 1000 + 43 * 60);
});

test('stale board never supplies a live ETA and a missed timetable yields unknown arrival', () => {
    const state = journeyProjection({ ...session, boardedAt: now + 30 * 60000 },
        { 2: { ...board([row('stale', 55)]), stale: true } }, now);
    assert.equal(state.finalArrivalEpoch, null);
    assert.match(state.message, /no confirmed onward departure/);
});

test('unknown train and overdue arrival never advance the journey or show a past ETA', () => {
    const state = journeyProjection({ ...session, boardedAt: now - 60 * 60000 }, {}, now);
    assert.equal(state.phase, 'onboard'); assert.equal(state.nextArrivalEpoch, null);
    assert.equal(state.finalArrivalEpoch, null);
});

test('via validation canonicalises aliases and rejects duplicate hubs and endpoints', () => {
    const query = { from: 'nr:CLK', to: 'HUBSRA', via: '940GZZDLLEW,940GZZDLCAN' };
    const value = validateCombinedQuery(query, now);
    assert.deepEqual(value.via.map(s => s.id), ['HUBLEW', 'HUBCAW']);
    assert.throws(() => validateCombinedQuery({ ...query, via: 'HUBLEW,940GZZDLLEW' }, now), { code: 'INVALID_VIA' });
    assert.throws(() => validateCombinedQuery({ ...query, via: 'HUBSRA' }, now), { code: 'INVALID_VIA' });
});

test('via choices retain DLR alternatives and never stitch impossible connections', () => {
    const part = l => ({ ...plan, departureTime: l.departureTime, arrivalTime: l.arrivalTime, legs: [l], changes: 0 });
    const dlr = part(leg(2, 37, 50));
    const jubilee = { ...dlr, legs: [{ ...dlr.legs[0], lines: [{ id: 'jubilee' }] }] };
    const choices = combineViaChoices([[part(leg(0, 2, 12))], [part(leg(1, 17, 32))], [dlr, jubilee, part(leg(2, 33, 46))]]);
    assert.equal(choices.length, 2);
    assert.equal(choices[0].legs.filter(l => l.mode === 'transfer').length, 2);
    assert.deepEqual(choices.map(c => c.legs.at(-1).lines[0].id), ['dlr', 'jubilee']);
});

test('London recurrence skips missing spring times, chooses first autumn fold and supports 23:59', () => {
    const spring = Date.parse('2026-03-29T00:00:00Z');
    assert.equal(scheduleDue({ days: [7], minute: 90 }, spring), null);
    const autumn = Date.parse('2026-10-25T00:00:00Z');
    assert.equal(scheduleDue({ days: [7], minute: 90 }, autumn), Date.parse('2026-10-25T00:30:00Z'));
    assert.equal(scheduleDue({ days: [5], minute: 1439 }, now), Date.parse('2026-10-23T22:59:00Z'));
});

async function fixture(t) {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'tracked-route-'));
    const store = await new TrackedJourneyStore({ filePath: path.join(directory, 'routes.json') }).load();
    const planner = { jobs: new Map([['search', { result: { data: { journeys: [plan] } }, request: { accessibility: 'none' } }]]) };
    const pushes = [];
    const service = new TrackedJourneys({ store, planner, clock: () => now,
        boards: { board: async () => board([row('train', 2)]) },
        apns: { send: async payload => { pushes.push(payload); return { ok: true }; } }, topic: 'test' });
    const app = express(); app.use('/journeys', trackedJourneyRoutes(service));
    app.use((e, req, res, next) => res.status(e.status ?? 500).json({ error: { message: e.message } }));
    const server = app.listen(0); await new Promise(resolve => server.once('listening', resolve));
    const url = `http://127.0.0.1:${server.address().port}/journeys`;
    const request = async (route = '', method = 'GET', body, secret = 'a'.repeat(64)) => {
        const response = await fetch(url + route, { method, headers: { 'Content-Type': 'application/json',
            'X-TubeTrack-Install': 'installation-123', 'X-TubeTrack-Schedule-Key': secret }, body: body ? JSON.stringify(body) : undefined });
        return { status: response.status, body: response.status === 403 ? null : await response.json() };
    };
    t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
    return { service, store, pushes, request };
}

test('start, correction, stale revision, auth ownership, token isolation and completion work end to end', async t => {
    const { request, store } = await fixture(t);
    const started = await request('/start', 'POST', { searchID: 'search', journeyID: 'route' });
    assert.equal(started.status, 200);
    const active = started.body.data.active;
    assert.equal((await request('', 'GET', null, 'b'.repeat(64))).status, 403);
    assert.equal((await request('/start', 'POST', { searchID: 'search', journeyID: 'route' })).status, 409);
    assert.equal((await request('/progress', 'PUT', { id: active.id, revision: 99, legIndex: 1, phase: 'onboard' })).status, 409);
    const progressed = await request('/progress', 'PUT', { id: active.id, revision: active.revision, legIndex: 1, phase: 'onboard', boardedID: 'train' });
    assert.equal(progressed.status, 200);
    assert.equal(progressed.body.data.active.state.boardTitle, 'Canary Wharf → Stratford');
    await request('/token', 'PUT', { id: active.id, token: 'c'.repeat(64), environment: 'sandbox' });
    assert.equal((await request()).body.data.active.token, undefined);
    const completed = await request('/progress', 'PUT', { id: active.id, revision: progressed.body.data.active.revision, legIndex: 2, phase: 'complete' });
    assert.equal(completed.body.data.active, null);
    const reloaded = await new TrackedJourneyStore({ filePath: store.filePath }).load();
    assert.equal(reloaded.rows['installation-123'].active, null);
});

test('scheduled occurrence is claimed once, refreshes the route and survives restart', async t => {
    const { request, service, store, pushes } = await fixture(t);
    await request('/device', 'PUT', { token: 'd'.repeat(64), environment: 'sandbox' });
    const scheduled = await request('/schedules', 'POST', { searchID: 'search', journeyID: 'route', date: at(1) });
    assert.equal(scheduled.status, 200);
    const originalSend = service.apns.send;
    service.apns.send = async payload => {
        if (payload.payload.aps.event === 'start') assert.equal(store.rows['installation-123'].active.id, payload.activityId);
        return originalSend(payload);
    };
    let refreshes = 0; service.resolve = async () => { refreshes++; return plan; };
    service.clock = () => now + 60000;
    await service.tick(); await Promise.all([...service.pending]); await service.tick();
    assert.equal(refreshes, 1);
    assert.equal(pushes.filter(p => p.payload.aps.event === 'start').length, 1);
    const restored = await new TrackedJourneyStore({ filePath: store.filePath }).load();
    assert.equal(Object.keys(restored.rows['installation-123'].claims).length, 1);
    assert.equal(pushes[0].payload.aps['attributes-type'], 'JourneyActivityAttributes');
    assert.ok(Buffer.byteLength(JSON.stringify(pushes[0].payload)) < 4096);
});

test('active manual journey suppresses scheduled occurrence without restarting it', async t => {
    const { request, service, pushes } = await fixture(t);
    await request('/device', 'PUT', { token: 'd'.repeat(64), environment: 'sandbox' });
    await request('/schedules', 'POST', { searchID: 'search', journeyID: 'route', date: at(1) });
    await request('/start', 'POST', { searchID: 'search', journeyID: 'route' });
    service.clock = () => now + 60000;
    service.resolve = async () => { throw new Error('Must not replan while a manual journey is active'); };
    await service.tick();
    assert.equal(pushes.filter(p => p.payload.aps.event === 'start').length, 0);
});


test('failed end delivery persists for retry even after live sources fail', async t => {
    const { service, request, store, pushes } = await fixture(t);
    const start = (await request('/start', 'POST', { searchID: 'search', journeyID: 'route' })).body.data.active;
    await request('/token', 'PUT', { id: start.id, token: 'e'.repeat(64), environment: 'sandbox' });
    const sender = service.apns.send;
    service.apns.send = async () => { throw new Error('Temporary outage'); };
    await request('/progress', 'PUT', { id: start.id, revision: start.revision, legIndex: 2, phase: 'complete' });
    assert.equal(store.rows['installation-123'].active, null);
    assert.equal(store.rows['installation-123'].endings.length, 1);
    service.apns.send = sender; service.boards.board = async () => { throw new Error('Source outage'); };
    await service.tick();
    assert.equal(store.rows['installation-123'].endings.length, 0);
    assert.equal(pushes.at(-1).payload.aps.event, 'end');
    assert.ok(pushes.at(-1).expiration > now / 1000);
});

test('registration racing a background snapshot retains the latest update token', async t => {
    const { service, request, store } = await fixture(t);
    const start = (await request('/start', 'POST', { searchID: 'search', journeyID: 'route' })).body.data.active;
    const original = service.snapshot.bind(service);
    let unblock, arrived;
    const ready = new Promise(resolve => { arrived = resolve; });
    service.snapshot = async session => { arrived(); await new Promise(resolve => { unblock = resolve; }); return original(session); };
    const tick = service.tick(); await ready;
    await request('/token', 'PUT', { id: start.id, token: 'f'.repeat(64), environment: 'sandbox' });
    unblock(); await tick;
    assert.equal(store.rows['installation-123'].active.token, 'f'.repeat(64));
});

test('replacement validates a new route before ending the existing one', async t => {
    const { request } = await fixture(t);
    const old = (await request('/start', 'POST', { searchID: 'search', journeyID: 'route' })).body.data.active;
    assert.equal((await request('/start', 'POST', { searchID: 'missing', journeyID: 'route', replaceID: old.id, replaceRevision: old.revision })).status, 409);
    assert.equal((await request()).body.data.active.id, old.id);
    const replaced = await request('/start', 'POST', { searchID: 'search', journeyID: 'route', replaceID: old.id, replaceRevision: old.revision });
    assert.equal(replaced.status, 200); assert.notEqual(replaced.body.data.active.id, old.id);
});

test('scheduled planning does not block departure updates for another journey', async t => {
    const { service, request } = await fixture(t);
    await request('/device', 'PUT', { token: 'd'.repeat(64), environment: 'sandbox' });
    await request('/schedules', 'POST', { searchID: 'search', journeyID: 'route', date: at(1) });
    let release;
    service.resolve = () => new Promise(resolve => { release = resolve; });
    service.clock = () => now + 60000;
    await service.tick(); assert.equal(service.pending.size, 1); assert.equal(service.busy, false);
    release(plan); await Promise.all([...service.pending]);
});

test('via adapter checks mode-constrained DLR and propagates backward arrival times', async () => {
    const calls = [];
    const planner = new CombinedJourneys({ now: () => now, disruptions: { snapshot: async () => ({}), enrich: j => j },
        tflPlanner: { plan: async (query, options) => {
            calls.push({ query, options });
            const l = { ...leg(1, 20, 35), mode: 'dlr' };
            return { data: { journeys: [{ ...plan, departureTime: l.departureTime, arrivalTime: l.arrivalTime, legs: [l] }], messages: [], expiresAt: at(1) } };
        } }, fetch: async (_url, options) => {
            if (options.method === 'DELETE') return new Response(null, { status: 204 });
            return Response.json(options.method === 'POST' ? { id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', status: 'queued' }
                : { status: 'completed', result: { journeys: [], warnings: [], expiresAt: at(1) } });
        } });
    const job = await planner.start({ from: 'nr:CLK', to: 'HUBCAW', via: 'HUBLEW', timeMode: 'arriveBy', time: at(60) }, 'test');
    await planner.poll(job.id);
    assert.equal(calls[0].options.mode, 'dlr');
    assert.equal(calls[0].query.timeMode, 'arriveBy');
    assert.equal(calls[0].query.time, at(60));
    assert.equal(planner.jobs.get(job.id).index, 0);
    await planner.cancel(job.id);
});
