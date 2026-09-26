import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { LiveActivityNotifier } from '../lib/push/notifier.js';
import { PushTokenStore } from '../lib/push/token-store.js';
import { HEARTBEAT_MS } from '../lib/push/change-detector.js';

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

async function fixture({ rows = [], client = fakeClient(), statuses, clock = () => NOW_MS } = {}) {
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
        clock
    });
    return { store, notifier, client };
}

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
