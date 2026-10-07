import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { LiveActivityNotifier } from '../lib/push/notifier.js';
import { PushTokenStore } from '../lib/push/token-store.js';
import { HEARTBEAT_MS } from '../lib/push/change-detector.js';
import { createRailDepartureSource } from '../lib/push/rail-departures.js';
import { ResourceCache } from '../lib/resource-cache.js';
import { JourneyScheduler } from '../lib/scheduled-journeys.js';

const NOW_MS = 1_800_000_000_000;

function snapshotWith(arrivals) {
    return { arrivals, updatedAtMs: NOW_MS };
}

function arrival({ id = 'p1', vehicleId = 'v1', seconds = 300, platformName = 'Eastbound - Platform 2' } = {}) {
    return {
        id,
        vehicleId,
        stopId: '940GZZLUOXC',
        stationName: 'Oxford Circus Underground Station',
        lineId: 'central',
        platformName,
        direction: null,
        destinationStopId: null,
        destinationName: 'Hainault Underground Station',
        towards: null,
        timeToStation: seconds,
        expectedArrival: new Date(NOW_MS + seconds * 1_000).toISOString()
    };
}

function fakeClient({ responses = [] } = {}) {
    const sends = [];
    let index = 0;
    return {
        sends,
        async send(request) {
            sends.push(request);
            const response = responses[index] ?? { status: 200, ok: true, dead: false, retryable: false };
            index += 1;
            if (response instanceof Error) throw response;
            return response;
        }
    };
}

async function fixture({ rows = [], client = fakeClient(), statuses, clock = () => NOW_MS, railDepartures, nationalRail } = {}) {
    const store = new PushTokenStore({
        filePath: path.join(os.tmpdir(), `tube-track-notifier-${process.hrtime.bigint()}.json`),
        flushDebounceMs: 60_000,
        clock
    });
    for (const row of rows) store.upsert(row);

    const notifier = new LiveActivityNotifier({
        store,
        client,
        topic: 'dev.skynolimit.TubeTrackUK.push-type.liveactivity',
        statuses: statuses ?? (async () => []),
        railDepartures,
        nationalRail,
        clock
    });
    return { store, notifier, client };
}

const ABBEY_WOOD = '910GABWDXR';
const HEATHROW = '910GHTRWTM4';
function abbeyWoodBulk() {
    // Observed 2026-09-30: outbound times equal feed generation time, not
    // departure time. These occupy all four slots before genuine future rows.
    return [0, 1, 2, 3].map((index) => ({
        ...arrival({ id: `expired-${index}`, vehicleId: `v-${index}`, seconds: -120 }),
        stopId: ABBEY_WOOD, stationName: 'Abbey Wood', lineId: 'elizabeth',
        platformName: '4', direction: 'outbound', destinationStopId: HEATHROW,
        destinationName: 'Heathrow Terminal 4 Rail Station'
    })).concat({
        ...arrival({ seconds: 300 }), stopId: ABBEY_WOOD, stationName: 'Abbey Wood',
        lineId: 'elizabeth', destinationStopId: ABBEY_WOOD, destinationName: 'Abbey Wood'
    });
}

function abbeyWoodDeparture(overrides = {}) {
    return { naptanId: ABBEY_WOOD, stationName: 'Abbey Wood',
        destinationNaptanId: HEATHROW, destinationName: 'Heathrow Terminal 4 Rail Station',
        platformName: 'Platform 4', departureStatus: 'OnTime',
        estimatedTimeOfDeparture: new Date(NOW_MS + 300_000).toISOString(),
        scheduledTimeOfDeparture: new Date(NOW_MS + 300_000).toISOString(), ...overrides };
}

test('Abbey Wood pushes real departures instead of expired bulk rows or incoming terminators', async () => {
    const calls = [];
    const railDepartures = createRailDepartureSource({ clock: () => NOW_MS,
        resourceCache: new ResourceCache({ clock: () => NOW_MS }),
        client: { async fetchJSON(path, options) {
            calls.push({ path, options });
            return [abbeyWoodDeparture(),
                abbeyWoodDeparture({ destinationNaptanId: ABBEY_WOOD, destinationName: 'Abbey Wood' }),
                abbeyWoodDeparture({ estimatedTimeOfDeparture: null, scheduledTimeOfDeparture: null }),
                abbeyWoodDeparture({ estimatedTimeOfDeparture: new Date(NOW_MS - 120_000).toISOString() })];
        } }
    });
    const { notifier, client } = await fixture({ railDepartures, rows: ['any', 'westbound'].map((direction) =>
        subscription({ id: direction, hubId: ABBEY_WOOD, stopIds: [ABBEY_WOOD], lineId: 'elizabeth', direction })) });
    await notifier.notify(snapshotWith(abbeyWoodBulk()));
    assert.equal(calls.length, 1);
    assert.equal(calls[0].path, `/StopPoint/${ABBEY_WOOD}/ArrivalDepartures`);
    assert.deepEqual(calls[0].options.query, { lineIds: 'elizabeth' });
    assert.equal(client.sends.length, 2);
    for (const sent of client.sends) {
        const board = sent.payload.aps['content-state'].departures;
        assert.equal(board.length, 1);
        assert.equal(board[0].destination, 'Heathrow Terminal 4');
        assert.equal(board[0].platform, 'Platform 4');
        assert.equal(board[0].expectedAtEpoch, NOW_MS / 1000 + 300);
    }
});

test('rail correction is also used when only expired outbound rows remain', async () => {
    const { notifier, client } = await fixture({
        rows: [subscription({ stopIds: [ABBEY_WOOD], lineId: 'elizabeth', direction: 'any' })],
        railDepartures: { async departures() { return { data: [], meta: {
            updatedAt: new Date(NOW_MS).toISOString(), stale: false
        } }; } }
    });
    await notifier.notify(snapshotWith(abbeyWoodBulk().slice(0, 4)));
    assert.deepEqual(client.sends[0].payload.aps['content-state'].departures, []);
});

test('unavailable, stale or malformed rail departure feeds never overwrite a tracked board', async () => {
    for (const kind of ['failure', 'stale', 'old', 'malformed']) {
        const railDepartures = kind === 'malformed'
            ? createRailDepartureSource({ resourceCache: new ResourceCache(),
                client: { async fetchJSON() { return { error: 'bad response' }; } } })
            : { async departures() {
                if (kind === 'failure') throw new Error('offline');
                return { data: [], meta: { stale: kind === 'stale',
                    updatedAt: new Date(NOW_MS - (kind === 'old' ? 120_000 : 0)).toISOString() } };
            } };
        const { notifier, client, store } = await fixture({ railDepartures,
            rows: [subscription({ stopIds: [ABBEY_WOOD], lineId: 'elizabeth', direction: 'any' })] });
        await notifier.notify(snapshotWith(abbeyWoodBulk()));
        assert.equal(client.sends.length, 0, kind);
        assert.equal(store.get('activity-1').sequence, undefined, kind);
    }
});

test('ordinary future Elizabeth line predictions need no per-station request', async () => {
    const { notifier, client } = await fixture({
        rows: [subscription({ stopIds: [ABBEY_WOOD], lineId: 'elizabeth', direction: 'any' })],
        railDepartures: { async departures() { assert.fail('unexpected departure request'); } }
    });
    const future = { ...abbeyWoodBulk()[0], expectedArrival: new Date(NOW_MS + 300_000).toISOString() };
    await notifier.notify(snapshotWith([future]));
    assert.equal(client.sends.length, 1);
    assert.equal(client.sends[0].payload.aps['content-state'].departures[0].expectedAtEpoch, NOW_MS / 1000 + 300);
});

test('Abbey Wood interchange aliases cannot replace corrected departures in updates or scheduled starts', async () => {
    const bulk = abbeyWoodBulk();
    const alias = bulk.map((row) => ({ ...row, stopId: '910GABWD',
        stationName: 'Abbey Wood (London) Rail Station', direction: null }));
    const calls = [];
    const railDepartures = createRailDepartureSource({ clock: () => NOW_MS,
        resourceCache: new ResourceCache({ clock: () => NOW_MS }),
        client: { async fetchJSON(path) { calls.push(path); return [abbeyWoodDeparture()]; } }
    });
    // The real subscription includes both stops; older ones may name only the alias.
    for (const stopIds of [[ABBEY_WOOD, '910GABWD'], ['910GABWD']]) {
        const board = { hubId: 'HUBABW', stopIds, lineId: 'elizabeth', direction: 'any' };
        const { notifier, client } = await fixture({ railDepartures, rows: [subscription(board)] });
        await notifier.notify(snapshotWith([...bulk, ...alias]));
        const scheduler = new JourneyScheduler({ railDepartures, cache: { read: () => ({
            staleModes: [], snapshot: { arrivals: [...bulk, ...alias],
                modeUpdatedAt: { 'elizabeth-line': new Date(NOW_MS).toISOString() } }
        }) } });
        const started = await scheduler.initialState(board, NOW_MS);
        const pushed = client.sends[0].payload.aps['content-state'];
        assert.deepEqual(started.departures, pushed.departures);
        assert.equal(pushed.departures.length, 1);
        assert.equal(pushed.departures[0].expectedAtEpoch, NOW_MS / 1000 + 300);
        assert.equal(pushed.departures[0].destination, 'Heathrow Terminal 4');
    }
    assert.deepEqual(calls, [`/StopPoint/${ABBEY_WOOD}/ArrivalDepartures`]);
});

function subscription(overrides = {}) {
    return {
        id: 'activity-1',
        type: 'liveActivity',
        token: 'aa'.repeat(32),
        hubId: '940GZZLUOXC',
        stopIds: ['940GZZLUOXC'],
        lineId: 'central',
        direction: 'eastbound',
        startedAtMs: NOW_MS - 60_000,
        frequentPushesEnabled: true,
        ...overrides
    };
}

test('nothing is sent when nobody is tracking a board', async () => {
    const { notifier, client } = await fixture();
    const result = await notifier.notify(snapshotWith([arrival()]));
    assert.deepEqual(result, { sent: 0, considered: 0 });
    assert.equal(client.sends.length, 0);
});

test('National Rail pushes fetch by CRS once per pass and preserve operator scope and freshness', async () => {
    const calls = [];
    const nationalRail = { async departures(crs, options) {
        calls.push({ crs, options });
        return { data: [{ id: 'national-rail:BKJ:1', lineId: 'national-rail:SE', stopId: 'BKJ',
            destinationName: 'London Victoria', platformName: 'Platform 2', hasExpectedTime: false,
            expectedArrival: null, scheduledDeparture: new Date(NOW_MS - 600_000).toISOString(), status: 'delayed' },
        { id: 'national-rail:BKJ:2', lineId: 'national-rail:SN', stopId: 'BKJ', destinationName: 'London Bridge',
            platformName: 'Platform 3', hasExpectedTime: true, expectedArrival: new Date(NOW_MS + 300_000).toISOString() }],
        meta: { updatedAt: new Date(NOW_MS - 10_000).toISOString(), stale: false } };
    } };
    const { store, notifier, client } = await fixture({ nationalRail, rows: ['one', 'two'].map((id) =>
        subscription({ id, hubId: 'nr:BKJ', stopIds: ['BKJ'], lineId: 'national-rail:SE', direction: 'any' })) });
    try {
        await notifier.notify(snapshotWith([]));
        assert.equal(calls.length, 1);
        assert.deepEqual(calls[0], { crs: 'BKJ', options: { includeThameslink: true } });
        assert.equal(client.sends.length, 2);
        const aps = client.sends[0].payload.aps;
        assert.equal(aps['content-state'].departures.length, 1);
        assert.equal(aps['content-state'].departures[0].status, 'delayed');
        assert.equal(aps['content-state'].departures[0].hasExpectedTime, false);
        assert.equal(aps['content-state'].updatedAtEpoch, (NOW_MS - 10_000) / 1000);
        assert.equal(aps['stale-date'], (NOW_MS - 10_000) / 1000 + 90);
        assert.equal(aps['content-state'].conditionHeadline, 'Delays');
    } finally { store.stop(); }
});

test('failed, stale or regressed National Rail boards preserve the last board while Tube pushes continue', async () => {
    for (const result of [new Error('offline'), { data: [], meta: { updatedAt: new Date(NOW_MS).toISOString(), stale: true } },
        { data: [], meta: { updatedAt: new Date(NOW_MS - 91_000).toISOString() } },
        { data: [], meta: { updatedAt: new Date(NOW_MS - 10_000).toISOString() } }]) {
        const previous = [{ id: 'kept', destination: 'Victoria', expectedAtEpoch: NOW_MS / 1000 + 300 }];
        const nationalRail = { async departures() { if (result instanceof Error) throw result; return result; } };
        const { store, notifier, client } = await fixture({ nationalRail, rows: [subscription({ id: 'rail',
            hubId: 'nr:BKJ', stopIds: ['BKJ'], lineId: 'national-rail:SE', direction: 'any',
            lastSourceUpdatedAtMs: NOW_MS, lastBoard: previous }), subscription({ id: 'tube' })] });
        try {
            await notifier.notify(snapshotWith([arrival()]));
            assert.equal(client.sends.length, 1);
            assert.equal(client.sends[0].payload.aps['content-state'].departures[0].destination, 'Hainault');
            assert.deepEqual(store.get('rail').lastBoard, previous);
        } finally { store.stop(); }
    }
});

test('National Rail pushes preserve direction and keep the last board when destination coordinates are unavailable', async () => {
    const arrivals = [
        { id: 'in', lineId: 'national-rail:SE', direction: 'northbound', destinationName: 'Victoria',
            expectedArrival: new Date(NOW_MS + 300_000).toISOString(), hasExpectedTime: true },
        { id: 'out', lineId: 'national-rail:SE', direction: 'southbound', destinationName: 'Orpington', status: 'cancelled',
            expectedArrival: new Date(NOW_MS + 600_000).toISOString(), hasExpectedTime: true }
    ];
    const nationalRail = { async departures() {
        return { data: arrivals, meta: { updatedAt: new Date(NOW_MS).toISOString(), stale: false } };
    } };
    const { notifier, client, store } = await fixture({ nationalRail, rows: ['northbound', 'southbound'].map((direction) =>
        subscription({ id: direction, hubId: 'HUBBEK', stopIds: ['BKJ'], lineId: 'national-rail:SE', direction })) });
    try {
        await notifier.notify(snapshotWith([]));
        assert.equal(client.sends.length, 2);
        assert.deepEqual(client.sends.map((send) => send.payload.aps['content-state'].departures.map((item) => item.id)), [['in'], ['out']]);
        assert.deepEqual(client.sends.map((send) => send.payload.aps['content-state'].conditionHeadline), ['Departures on time', 'Cancellations']);
        for (const arrival of arrivals) arrival.direction = null;
        await notifier.notify(snapshotWith([]));
        assert.equal(client.sends.length, 2);
        assert.deepEqual(store.get('northbound').lastBoard.map((item) => item.id), ['in']);
        assert.deepEqual(store.get('southbound').lastBoard.map((item) => item.id), ['out']);
    } finally { store.stop(); }
});

test('does not push an old board for a stale mode while healthy modes update', async () => {
    const { notifier, client, store } = await fixture({ rows: [
        subscription(),
        subscription({ id: 'activity-2', lineId: 'elizabeth', token: 'bb'.repeat(32) })
    ] });
    const elizabeth = { ...arrival({ id: 'eliz', vehicleId: 'eliz-v' }), lineId: 'elizabeth' };

    await notifier.notify(snapshotWith([arrival(), elizabeth]), { staleModes: ['tube'] });

    assert.equal(client.sends.length, 1);
    assert.equal(store.get('activity-1').sequence, undefined);
    assert.equal(store.get('activity-2').sequence, 1);
});

test('the first snapshot pushes the board the client would have built', async () => {
    const { notifier, client, store } = await fixture({ rows: [subscription()] });
    await notifier.notify(snapshotWith([arrival()]));

    assert.equal(client.sends.length, 1);
    const sent = client.sends[0];
    assert.equal(sent.pushType, 'liveactivity');
    assert.equal(sent.topic, 'dev.skynolimit.TubeTrackUK.push-type.liveactivity');

    const state = sent.payload.aps['content-state'];
    assert.deepEqual(state.departures.map((row) => row.id), ['v1']);
    assert.equal(state.departures[0].platform, 'Platform 2');
    assert.equal(state.departures[0].destination, 'Hainault');
    assert.equal(state.sequence, 1);
    // A push must never leave the client guessing how old its board is.
    assert.equal(state.updatedAtEpoch, NOW_MS / 1_000);
    assert.ok(sent.payload.aps['stale-date'] > sent.payload.aps.timestamp);

    assert.equal(store.get('activity-1').sequence, 1);
});

test('an unchanged board spends no push on the next poll', async () => {
    const { notifier, client } = await fixture({ rows: [subscription()] });
    await notifier.notify(snapshotWith([arrival()]));
    await notifier.notify(snapshotWith([arrival()]));
    assert.equal(client.sends.length, 1);
});

test('a heartbeat advances Updated even when the departure predictions are unchanged', async () => {
    let nowMs = NOW_MS;
    const { notifier, client } = await fixture({
        rows: [subscription()], clock: () => nowMs
    });
    const arrivals = [arrival({ seconds: 1_800 })];
    await notifier.notify({ arrivals, updatedAtMs: nowMs });
    nowMs += HEARTBEAT_MS;
    await notifier.notify({ arrivals, updatedAtMs: nowMs });

    assert.equal(client.sends.length, 2);
    const first = client.sends[0].payload.aps['content-state'];
    const second = client.sends[1].payload.aps['content-state'];
    assert.deepEqual(second.departures, first.departures);
    assert.equal(second.updatedAtEpoch, nowMs / 1_000);
    assert.ok(second.updatedAtEpoch > first.updatedAtEpoch);
});

test('the sequence number advances so a late push can be discarded', async () => {
    const { notifier, client } = await fixture({ rows: [subscription()] });
    await notifier.notify(snapshotWith([arrival()]));
    await notifier.notify(snapshotWith([arrival({ vehicleId: 'v2' })]));

    assert.equal(client.sends.length, 2);
    assert.equal(client.sends[1].payload.aps['content-state'].sequence, 2);
});

test('a line with problems carries its headline; a healthy one does not', async () => {
    const statuses = async () => [
        {
            id: 'central',
            lineStatuses: [{ statusSeverity: 6, statusSeverityDescription: 'Severe Delays' }]
        }
    ];
    const { notifier, client } = await fixture({ rows: [subscription()], statuses });
    await notifier.notify(snapshotWith([arrival()]));

    const state = client.sends[0].payload.aps['content-state'];
    assert.equal(state.conditionRank, 0);
    assert.equal(state.conditionHeadline, 'Severe Delays');

    const healthy = await fixture({
        rows: [subscription()],
        statuses: async () => [
            { id: 'central', lineStatuses: [{ statusSeverity: 10, statusSeverityDescription: 'Good Service' }] }
        ]
    });
    await healthy.notifier.notify(snapshotWith([arrival()]));
    const healthyState = healthy.client.sends[0].payload.aps['content-state'];
    assert.equal(healthyState.conditionRank, 4);
    assert.equal(healthyState.conditionHeadline, null);
});

test('losing line status costs a headline, not the board', async () => {
    const warnings = [];
    const { store, notifier, client } = await fixture({
        rows: [subscription()],
        statuses: async () => {
            throw new Error('TfL is down');
        }
    });
    notifier.logger = { warn: (event) => warnings.push(event) };

    await notifier.notify(snapshotWith([arrival()]));
    assert.equal(client.sends.length, 1);
    assert.deepEqual(warnings, ['push_statuses_unavailable']);
    assert.equal(store.get('activity-1').lastBoard.length, 1);
    assert.equal(client.sends[0].payload.aps['content-state'].conditionRank, 3);
});

test('a retired token is removed rather than retried forever', async () => {
    const client = fakeClient({
        responses: [{ status: 410, ok: false, dead: true, retryable: false, reason: 'Unregistered' }]
    });
    const { notifier, store } = await fixture({ rows: [subscription()], client });

    await notifier.notify(snapshotWith([arrival()]));
    assert.equal(store.get('activity-1'), null);
    assert.equal(client.sends.length, 1);
});

test('a development token rejected by production is routed to sandbox and remembered', async () => {
    let nowMs = NOW_MS;
    const client = fakeClient({ responses: [
        { status: 400, ok: false, dead: true, reason: 'BadDeviceToken' }
    ] });
    const { notifier, store } = await fixture({
        rows: [subscription()], client, clock: () => nowMs
    });
    await notifier.notify(snapshotWith([arrival()]));
    assert.deepEqual(client.sends.map((request) => request.environment), ['production', 'sandbox']);
    assert.equal(store.get('activity-1').apnsEnvironment, 'sandbox');
    nowMs += 30_000;
    await notifier.notify({ ...snapshotWith([arrival()]), updatedAtMs: nowMs });
    assert.equal(client.sends.length, 3);
    assert.equal(client.sends[2].environment, 'sandbox');
    assert.equal(client.sends[2].payload.aps['content-state'].updatedAtEpoch, nowMs / 1_000);
    assert.equal(client.sends[2].priority, 5);
});

test('production tokens also recover when the configured default is sandbox', async () => {
    const client = fakeClient({ responses: [
        { status: 400, ok: false, dead: true, reason: 'BadDeviceToken' }
    ] });
    client.environment = 'sandbox';
    const { notifier, store } = await fixture({ rows: [subscription()], client });
    await notifier.notify(snapshotWith([arrival()]));
    assert.deepEqual(client.sends.map((request) => request.environment), ['sandbox', 'production']);
    assert.equal(store.get('activity-1').apnsEnvironment, 'production');
});

test('a token invalid in both environments is retired after exactly two attempts', async () => {
    const invalid = { status: 400, ok: false, dead: true, reason: 'BadDeviceToken' };
    const client = fakeClient({ responses: [invalid, invalid] });
    const { notifier, store } = await fixture({ rows: [subscription()], client });
    await notifier.notify(snapshotWith([arrival()]));
    assert.equal(client.sends.length, 2);
    assert.equal(store.get('activity-1'), null);
});

test('an outage during environment discovery preserves the subscription for the next poll', async () => {
    const client = fakeClient({ responses: [
        { status: 400, ok: false, dead: true, reason: 'BadDeviceToken' },
        { status: 503, ok: false, dead: false, retryable: true, reason: 'ServiceUnavailable' }
    ] });
    const { notifier, store } = await fixture({ rows: [subscription()], client });
    await notifier.notify(snapshotWith([arrival()]));
    assert.ok(store.get('activity-1'));
    assert.equal(store.get('activity-1').lastPushedAtMs, undefined);
});

test('a board with frequent updates disabled still receives a fresh snapshot each minute', async () => {
    let nowMs = NOW_MS;
    const { notifier, client } = await fixture({
        rows: [subscription({ frequentPushesEnabled: false })], clock: () => nowMs
    });
    for (let poll = 0; poll <= 4; poll += 1) {
        nowMs = NOW_MS + poll * 30_000;
        await notifier.notify({ ...snapshotWith([arrival()]), updatedAtMs: nowMs });
    }
    assert.deepEqual(client.sends.map((request) => request.payload.aps['content-state'].updatedAtEpoch),
        [0, 60, 120].map((seconds) => NOW_MS / 1_000 + seconds));
});

test('a rejected push leaves the subscription alone to try again', async () => {
    const client = fakeClient({
        responses: [{ status: 503, ok: false, dead: false, retryable: true, reason: 'ServiceUnavailable' }]
    });
    const { notifier, store } = await fixture({ rows: [subscription()], client });

    await notifier.notify(snapshotWith([arrival()]));
    const row = store.get('activity-1');
    assert.ok(row, 'the subscription survives a transient failure');
    // Nothing was delivered, so nothing may be recorded as the last board —
    // otherwise the next real change would look like no change at all.
    assert.equal(row.lastBoard, undefined);
});

test('a transport failure cannot break the poll loop', async () => {
    const client = {
        sends: [],
        async send() {
            throw new Error('connection reset');
        }
    };
    const { notifier, store } = await fixture({ rows: [subscription()], client });

    await assert.doesNotReject(notifier.notify(snapshotWith([arrival()])));
    assert.ok(store.get('activity-1'), 'the subscription is kept for the next poll');
});

test('a thrown error anywhere resolves rather than rejecting into the poller', async () => {
    const { notifier } = await fixture({ rows: [subscription()] });
    notifier.store = {
        all() {
            throw new Error('store exploded');
        }
    };
    notifier.logger = { error: () => {} };

    const result = await notifier.notify(snapshotWith([arrival()]));
    assert.deepEqual(result, { skipped: true, reason: 'error' });
});

test('a slow pass does not let polls pile up on top of each other', async () => {
    let release;
    const gate = new Promise((resolve) => {
        release = resolve;
    });
    const client = {
        sends: [],
        async send(request) {
            client.sends.push(request);
            await gate;
            return { status: 200, ok: true, dead: false, retryable: false };
        }
    };
    const { notifier } = await fixture({ rows: [subscription()], client });

    const first = notifier.notify(snapshotWith([arrival()]));
    const second = await notifier.notify(snapshotWith([arrival()]));
    assert.deepEqual(second, { skipped: true, reason: 'in_flight' });

    release();
    await first;
    assert.equal(client.sends.length, 1);
});

test('a subscription outliving the activity cap is dropped', async () => {
    const { notifier, store, client } = await fixture({
        rows: [subscription({ startedAtMs: NOW_MS - 91 * 60 * 1_000 })]
    });

    await notifier.notify(snapshotWith([arrival()]));
    assert.equal(store.get('activity-1'), null);
    assert.equal(client.sends.length, 0);
});

test('each subscription gets only the board it asked for', async () => {
    const { notifier, client } = await fixture({
        rows: [
            subscription({ id: 'east', direction: 'eastbound' }),
            subscription({ id: 'west', direction: 'westbound' })
        ]
    });

    await notifier.notify(
        snapshotWith([
            arrival({ id: 'e', vehicleId: 've', platformName: 'Eastbound - Platform 2' }),
            arrival({ id: 'w', vehicleId: 'vw', platformName: 'Westbound - Platform 1' })
        ])
    );

    assert.equal(client.sends.length, 2);
    const boards = client.sends.map((sent) =>
        sent.payload.aps['content-state'].departures.map((row) => row.id)
    );
    assert.deepEqual(boards.sort(), [['ve'], ['vw']].sort());
});

function riverPrediction(overrides = {}) {
    return {
        id: 'river-1', pierId: '930GCAD', lineId: 'rb6', destinationName: 'Putney Pier',
        expectedArrival: new Date(NOW_MS + 900_000).toISOString(),
        observedAt: new Date(NOW_MS).toISOString(), expiresAt: null, terminatesHere: false,
        ...overrides
    };
}
const riverSubscription = () => subscription({ id: 'river', hubId: '930GCAD', stopIds: ['930GCAD'], lineId: 'rb6', direction: 'any' });
const riverSource = (predictions, updatedAtMs = NOW_MS, stale = false) => ({
    data: predictions, meta: { updatedAt: new Date(updatedAtMs).toISOString(), stale }
});

test('river pushes use their own source, expiry rules and service status', async () => {
    const { notifier, client } = await fixture({ rows: [riverSubscription()] });
    notifier.river = {
        arrivals: async () => riverSource([
            riverPrediction(), riverPrediction({ id: 'terminal', terminatesHere: true }),
            riverPrediction({ id: 'other-pier', pierId: '930GOTH' }),
            riverPrediction({ id: 'other-line', lineId: 'rb1' }),
            riverPrediction({ id: 'expired', expiresAt: new Date(NOW_MS - 1).toISOString() }),
            riverPrediction({ id: 'old', observedAt: new Date(NOW_MS - 91_000).toISOString() })
        ], NOW_MS - 30_000),
        status: async () => ({ data: [{ id: 'rb6', entries: [{ severity: 9, description: 'Minor delays' }] }] })
    };
    await notifier.notify(snapshotWith([arrival()]));
    assert.equal(client.sends.length, 1);
    const aps = client.sends[0].payload.aps;
    assert.deepEqual(aps['content-state'].departures, [{
        id: 'river-1', destination: 'Putney Pier', platform: null, expectedAtEpoch: NOW_MS / 1000 + 900
    }]);
    assert.equal(aps['content-state'].updatedAtEpoch, NOW_MS / 1000 - 30);
    assert.equal(aps['stale-date'], NOW_MS / 1000 + 60);
    assert.equal(aps['content-state'].conditionRank, 1);
    assert.equal(aps['content-state'].conditionHeadline, 'Minor delays');
});

test('stale or failing river data never empties the pier board or prevents rail updates', async () => {
    const { notifier, client } = await fixture({ rows: [riverSubscription(), subscription()] });
    for (const source of [
        async () => { throw new Error('offline'); },
        async () => riverSource([], NOW_MS, true),
        async () => riverSource([], NOW_MS - 91_000)
    ]) {
        notifier.river = { arrivals: source };
        await notifier.notify(snapshotWith([arrival({ vehicleId: String(client.sends.length) })]));
    }
    assert.equal(client.sends.length, 3);
    assert.ok(client.sends.every((sent) => sent.payload.aps['content-state'].departures[0].destination === 'Hainault'));
});

test('a river empty poll needs a second distinct source update before replacing a valid board', async () => {
    let nowMs = NOW_MS;
    let source = riverSource([riverPrediction()]);
    const { notifier, client } = await fixture({ rows: [riverSubscription()], clock: () => nowMs });
    notifier.river = { arrivals: async () => source, status: async () => ({ data: [] }) };
    await notifier.notify(snapshotWith([]));
    nowMs += 30_000;
    source = riverSource([], nowMs);
    await notifier.notify(snapshotWith([]));
    nowMs += 10_000;
    await notifier.notify(snapshotWith([]));
    assert.equal(client.sends.length, 1);
    nowMs += 20_000;
    source = riverSource([], nowMs);
    await notifier.notify(snapshotWith([]));
    assert.equal(client.sends.length, 2);
    assert.deepEqual(client.sends[1].payload.aps['content-state'].departures, []);
});

function thameslinkDeparture({ id = 'tl-1', minutes = 5, direction = 'Northbound', status = 'onTime',
    destinationName = 'Bedford', stopId = '910GFRNDNLT' } = {}) {
    const expected = new Date(NOW_MS + minutes * 60_000).toISOString();
    return {
        id, stopId, stationName: 'Farringdon', lineId: 'thameslink', lineName: 'Thameslink',
        platformName: 'Platform 4', direction, destinationStopId: '910GBEDFDM', destinationName,
        scheduledDeparture: expected, expectedDeparture: expected,
        timeToStation: minutes * 60, status, cause: null
    };
}

function thameslinkSubscription(overrides = {}) {
    return subscription({
        id: 'activity-tl', hubId: 'HUBZFD', lineId: 'thameslink', direction: 'northbound',
        stopIds: ['940GZZLUFCN', '910GFRNDXR', '910GFRNDNLT'], ...overrides
    });
}

function thameslinkSource(departures, updatedAtMs = NOW_MS - 10_000, stale = false) {
    return { data: departures, meta: { updatedAt: new Date(updatedAtMs).toISOString(), stale } };
}

test('Thameslink pushes read the per-station board, filter direction and carry service status', async () => {
    const requested = [];
    const { notifier, client } = await fixture({
        rows: [thameslinkSubscription()],
        statuses: async () => [{ id: 'thameslink', lineStatuses: [{ statusSeverity: 9, statusSeverityDescription: 'Minor Delays', reason: 'Signal failure' }] }]
    });
    notifier.thameslink = {
        departures: async (stopIds) => {
            requested.push(stopIds);
            return thameslinkSource([
                thameslinkDeparture({ id: 'cancelled', minutes: 3, status: 'cancelled' }),
                thameslinkDeparture({ id: 'south', minutes: 4, direction: 'Southbound', destinationName: 'Brighton' }),
                thameslinkDeparture({ id: 'late', minutes: 9, status: 'delayed' })
            ]);
        }
    };
    await notifier.notify(snapshotWith([]));
    // Only the Thameslink platforms of the interchange are fetched.
    assert.deepEqual(requested, [['910GFRNDNLT']]);
    assert.equal(client.sends.length, 1);
    const state = client.sends[0].payload.aps['content-state'];
    assert.deepEqual(state.departures.map((row) => [row.id, row.destination, row.platform, row.status]), [
        ['cancelled', 'Bedford', 'Platform 4', 'cancelled'],
        ['late', 'Bedford', 'Platform 4', 'delayed']
    ]);
    assert.equal(state.updatedAtEpoch, NOW_MS / 1000 - 10);
    assert.equal(state.conditionRank, 1);
});

test('a train being cancelled is pushed at once, and failures never empty a Thameslink board', async () => {
    const { notifier, client, store } = await fixture({ rows: [thameslinkSubscription()] });
    let source = thameslinkSource([thameslinkDeparture()]);
    notifier.thameslink = { departures: async () => source };
    await notifier.notify(snapshotWith([]));
    assert.equal(client.sends.length, 1);

    for (const failing of [
        async () => { throw new Error('offline'); },
        async () => thameslinkSource([], NOW_MS, true),
        async () => thameslinkSource([], NOW_MS - 91_000)
    ]) {
        notifier.thameslink = { departures: failing };
        await notifier.notify(snapshotWith([]));
    }
    assert.equal(client.sends.length, 1);
    assert.equal(store.get('activity-tl').lastBoard[0].id, 'tl-1');

    source = thameslinkSource([thameslinkDeparture({ status: 'cancelled' })], NOW_MS - 5_000);
    notifier.thameslink = { departures: async () => source };
    await notifier.notify(snapshotWith([]));
    assert.equal(client.sends.length, 2);
    assert.equal(client.sends[1].priority, 10);
    assert.equal(client.sends[1].payload.aps['content-state'].departures[0].status, 'cancelled');
});

test('boards tracking the same station share one fetch per pass', async () => {
    const { notifier } = await fixture({
        rows: [thameslinkSubscription(), thameslinkSubscription({ id: 'activity-tl-2', token: 'bb'.repeat(32) })]
    });
    let calls = 0;
    notifier.thameslink = { departures: async () => { calls += 1; return thameslinkSource([thameslinkDeparture()]); } };
    await notifier.notify(snapshotWith([]));
    assert.equal(calls, 1);
});
