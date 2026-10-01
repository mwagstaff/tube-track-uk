import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import express from 'express';
import { ScheduledJourneyStore, JourneyScheduler, createScheduledJourneyRoutes,
    validateJourneys, londonTime, londonWindow } from '../lib/scheduled-journeys.js';
import { PushTokenStore } from '../lib/push/token-store.js';
import { createPushRoutes } from '../lib/push-routes.js';

const station = { id: '940GZZLUOXC', name: 'Oxford Circus', lineIds: ['central'], stopIds: ['940GZZLUOXC'] };
const stations = new Map([[station.id, station]]);
const board = { hubId: station.id, stationName: station.name, lineId: 'central', direction: 'eastbound', stopIds: station.stopIds };
const journey = (changes = {}) => ({ id: 'journey-0001', name: 'Office', enabled: true, days: [1, 2, 3, 4, 5],
    morning: { startMinute: 480, endMinute: 600, board }, afternoon: null, ...changes });
const token = 'ab'.repeat(32);
const secret = 'cd'.repeat(32);
const install = 'install-0001';

async function fixture(run) {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tube-schedules-'));
    const store = await new ScheduledJourneyStore({ dataDir: dir }).load();
    const pushStore = new PushTokenStore({ dataDir: dir });
    let now = Date.parse('2026-09-29T06:00:00Z');
    const app = express();
    app.use('/schedules', createScheduledJourneyRoutes({ store, stationById: stations, clock: () => now }));
    app.use('/push', createPushRoutes({ store: pushStore, scheduleStore: store, isKnownStop: (id) => stations.has(id), clock: () => now }));
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    const call = async (method, route, body, key = secret) => fetch(`http://127.0.0.1:${server.address().port}${route}`, {
        method, headers: { 'content-type': 'application/json', 'X-TubeTrack-Install': install, 'X-TubeTrack-Schedule-Key': key },
        body: body === undefined ? undefined : JSON.stringify(body)
    });
    const sends = [];
    const apns = { send: async (request) => { sends.push(request); return { ok: true }; } };
    const cache = { read: () => ({ staleModes: [], snapshot: { arrivals: [], modeUpdatedAt: { tube: new Date(now).toISOString() } } }) };
    const scheduler = new JourneyScheduler({ store, pushStore, apns, cache, topic: 'app.push-type.liveactivity', clock: () => now });
    const setup = async (journeys = [journey()]) => {
        assert.equal((await call('PUT', '/schedules/device', { token, activitiesEnabled: true, frequentPushesEnabled: true, environment: 'sandbox' })).status, 204);
        assert.equal((await call('PUT', '/schedules', { journeys, revision: 0 })).status, 200);
    };
    try { await run({ store, pushStore, scheduler, sends, apns, call, setup, cache, setTime: (date) => { now = Date.parse(date); } }); }
    finally { await scheduler.stop(); pushStore.stop(); await pushStore.flush(); await new Promise((r) => server.close(r)); await fs.rm(dir, { recursive: true, force: true }); }
}

test('one or both windows, day shortcuts and the configurable cap are validated', () => {
    assert.equal(validateJourneys([journey()], stations).length, 1);
    assert.equal(validateJourneys([journey({ morning: null, afternoon: { startMinute: 960, endMinute: 1080, board } })], stations).length, 1);
    for (const change of [{ days: [] }, { morning: null }, { morning: { startMinute: 480, endMinute: 601, board } },
        { morning: { startMinute: 480, endMinute: 480, board } }, { morning: { startMinute: 1380, endMinute: 60, board } },
        { morning: { startMinute: 480, endMinute: 600, board: { ...board, lineId: 'victoria' } } }]) {
        assert.throws(() => validateJourneys([journey(change)], stations));
    }
    assert.throws(() => validateJourneys(Array.from({ length: 4 }, (_, i) => journey({ id: `journey-000${i}`, enabled: false })), stations));
});

test('overlaps are rejected within and between enabled journeys; touching windows and different days are allowed', () => {
    assert.throws(() => validateJourneys([journey({ afternoon: { startMinute: 599, endMinute: 650, board } })], stations), /overlap/);
    assert.throws(() => validateJourneys([journey(), journey({ id: 'journey-0002' })], stations), /overlap/);
    assert.equal(validateJourneys([journey(), journey({ id: 'journey-0002', days: [6, 7] })], stations).length, 2);
    assert.equal(validateJourneys([journey(), journey({ id: 'journey-0002', enabled: false })], stations).length, 2);
    assert.equal(validateJourneys([journey({ afternoon: { startMinute: 600, endMinute: 660, board } })], stations).length, 1);
});

test('London recurrence follows BST independently of host time and resolves clock changes', () => {
    assert.equal(londonTime(Date.parse('2026-09-29T07:00:00Z')).minute, 480);
    assert.equal(londonTime(Date.parse('2026-12-29T08:00:00Z')).minute, 480);
    assert.equal(londonTime(Date.parse('2026-09-27T23:30:00Z')).day, 1);
    assert.equal(londonWindow('2026-03-29', 90, 150), null, 'missing 01:30 is skipped');
    assert.equal(londonWindow('2026-10-25', 90, 150).start, Date.parse('2026-10-25T00:30:00Z'));
    const fold = londonWindow('2026-10-25', 30, 150);
    assert.equal(fold.end - fold.start, 7200000, 'a repeated hour cannot extend the two-hour maximum');
});

test('schedule saves are durable, authenticated, canonical and revision checked', async () => fixture(async ({ setup, call, store }) => {
    await setup();
    const disk = await new ScheduledJourneyStore({ filePath: store.filePath }).load();
    assert.equal(disk.rows[install].journeys[0].morning.board.stationName, station.name);
    assert.equal((await call('GET', '/schedules', undefined, 'ef'.repeat(32))).status, 403);
    assert.equal((await call('PUT', '/schedules', { journeys: [], revision: 0 })).status, 409);
    assert.equal((await call('PUT', '/schedules', { journeys: [], revision: 1 })).status, 200);
    assert.deepEqual((await (await call('GET', '/schedules')).json()).journeys, []);
}));

test('failed disk writes do not acknowledge or publish a changed schedule', async () => fixture(async ({ setup, call, store }) => {
    await setup();
    const original = store.filePath;
    store.filePath = path.join(original, 'impossible.json');
    assert.equal((await call('PUT', '/schedules', { journeys: [], revision: 1 })).status, 503);
    assert.equal(store.rows[install].journeys.length, 1);
    store.filePath = original;
}));

test('starts once with the existing ActivityKit schema, including after restart, and ends without a live feed', async () => fixture(async ({ setup, scheduler, setTime, sends, store, pushStore, call, cache }) => {
    await setup();
    setTime('2026-09-29T07:00:00Z');
    await scheduler.tick();
    assert.equal(sends.length, 1);
    const aps = sends[0].payload.aps;
    assert.equal(aps.event, 'start');
    assert.equal(aps['attributes-type'], 'DepartureActivityAttributes');
    assert.equal(aps.attributes.hardEndsAtEpoch - aps.attributes.startedAtEpoch, 7200);
    assert.equal(aps.attributes.scheduleID, 'journey-0001');
    assert.equal(aps['input-push-token'], 1);
    await scheduler.tick();
    scheduler.store = await new ScheduledJourneyStore({ filePath: store.filePath }).load();
    await scheduler.tick();
    assert.equal(sends.length, 1);
    assert.equal((await call('POST', '/push/live-activities', { activityId: aps.attributes.activityID,
        token, ...board })).status, 201);
    const row = pushStore.all()[0];
    assert.equal(row.scheduleId, 'journey-0001');
    assert.equal(row.hardEndsAtMs, aps.attributes.hardEndsAtEpoch * 1000);
    cache.read = () => null;
    setTime('2026-09-29T09:00:01Z');
    await scheduler.tick();
    assert.equal(sends[1].payload.aps.event, 'end');
    assert.equal(pushStore.size, 0);
}));

test('manual tracking suppresses the entire occurrence even if it ends during the window', async () => fixture(async ({ setup, scheduler, setTime, sends, pushStore, store }) => {
    await setup();
    setTime('2026-09-29T07:00:00Z');
    pushStore.upsert({ id: 'manual', token, type: 'liveActivity', installId: install, startedAtMs: Date.parse('2026-09-29T06:50:00Z') });
    await scheduler.tick();
    assert.equal(sends.length, 0);
    assert.equal(Object.values(store.rows[install].occurrences)[0].status, 'manual');
    pushStore.delete('manual');
    setTime('2026-09-29T07:01:00Z');
    await scheduler.tick();
    assert.equal(sends.length, 0);
}));

test('deleting a journey cancels its active board, even when the update token arrives late', async () => fixture(async ({ setup, scheduler, setTime, sends, call }) => {
    await setup(); setTime('2026-09-29T07:00:00Z'); await scheduler.tick();
    const activityId = sends[0].payload.aps.attributes.activityID;
    assert.equal((await call('PUT', '/schedules', { journeys: [], revision: 1 })).status, 200);
    assert.equal((await call('POST', '/push/live-activities', { activityId, token, ...board })).status, 201);
    await scheduler.tick();
    assert.equal(sends[1].payload.aps.event, 'end');
}));

test('stale feeds, wrong weekdays, disabled activities and long-delayed windows never start', async () => fixture(async ({ setup, scheduler, setTime, sends, cache, store }) => {
    await setup();
    setTime('2026-09-29T07:00:00Z'); cache.read = () => null; await scheduler.tick(); assert.equal(sends.length, 0);
    setTime('2026-09-29T07:04:00Z'); await scheduler.tick(); assert.equal(sends.length, 0);
    setTime('2026-10-03T07:00:00Z'); await scheduler.tick(); assert.equal(sends.length, 0);
    store.rows[install].device.activitiesEnabled = false;
    setTime('2026-10-05T07:00:00Z'); await scheduler.tick(); assert.equal(sends.length, 0);
}));

test('ambiguous APNs failures never produce duplicate starts', async () => fixture(async ({ setup, scheduler, apns, setTime, store }) => {
    await setup(); setTime('2026-09-29T07:00:00Z');
    let calls = 0; apns.send = async () => { calls += 1; throw new Error('connection lost'); };
    await scheduler.tick(); await scheduler.tick();
    assert.equal(calls, 1);
    assert.equal(Object.values(store.rows[install].occurrences)[0].status, 'unknown');
}));
