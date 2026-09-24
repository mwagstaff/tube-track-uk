import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { LiveActivityNotifier } from '../lib/push/notifier.js';
import { PushTokenStore } from '../lib/push/token-store.js';

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
});

test('a retired token is removed rather than retried forever', async () => {
    const client = fakeClient({
        responses: [{ status: 410, ok: false, dead: true, retryable: false, reason: 'Unregistered' }]
    });
    const { notifier, store } = await fixture({ rows: [subscription()], client });

    await notifier.notify(snapshotWith([arrival()]));
    assert.equal(store.get('activity-1'), null);
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
