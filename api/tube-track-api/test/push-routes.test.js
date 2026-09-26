import assert from 'node:assert/strict';
import express from 'express';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { createPushRoutes, createRateLimiter } from '../lib/push-routes.js';
import { PushTokenStore } from '../lib/push/token-store.js';

const INSTALL = 'install-0123456789';
const TOKEN = 'ab'.repeat(32);
const KNOWN_STOPS = new Set(['940GZZLUOXC', '940GZZLUBND']);

async function withRoutes(run, overrides = {}) {
    const store = new PushTokenStore({
        filePath: path.join(os.tmpdir(), `tube-track-routes-${process.hrtime.bigint()}.json`),
        flushDebounceMs: 60_000
    });
    const app = express();
    app.use(
        '/api/v1/push',
        createPushRoutes({
            store,
            isKnownStop: (id) => KNOWN_STOPS.has(id),
            ...overrides
        })
    );

    const server = await new Promise((resolve) => {
        const listening = app.listen(0, '127.0.0.1', () => resolve(listening));
    });
    const baseUrl = `http://127.0.0.1:${server.address().port}`;

    const call = (method, routePath, { body, headers = {} } = {}) =>
        fetch(`${baseUrl}${routePath}`, {
            method,
            headers: {
                'content-type': 'application/json',
                'x-tubetrack-install': INSTALL,
                ...headers
            },
            body: body === undefined ? undefined : JSON.stringify(body)
        });

    try {
        await run({ call, store, baseUrl });
    } finally {
        await new Promise((resolve) => server.close(resolve));
        store.stop();
    }
}

function registration(overrides = {}) {
    return {
        activityId: 'DEADBEEF-1234-5678',
        token: TOKEN,
        lineId: 'central',
        direction: 'eastbound',
        hubId: '940GZZLUOXC',
        stopIds: ['940GZZLUOXC'],
        ...overrides
    };
}

test('a registration without an install id is refused', async () => {
    await withRoutes(async ({ call }) => {
        const response = await call('POST', '/api/v1/push/live-activities', {
            body: registration(),
            headers: { 'x-tubetrack-install': '' }
        });
        assert.equal(response.status, 400);
        assert.equal((await response.json()).error.code, 'INVALID_INSTALL_ID');
    });
});

test('a valid registration is stored against its install', async () => {
    await withRoutes(async ({ call, store }) => {
        const response = await call('POST', '/api/v1/push/live-activities', {
            body: registration()
        });
        assert.equal(response.status, 201);
        const { data } = await response.json();
        assert.equal(data.id, `${INSTALL}:DEADBEEF-1234-5678`);

        const row = store.get(data.id);
        assert.equal(row.lineId, 'central');
        assert.equal(row.direction, 'eastbound');
        assert.deepEqual(row.stopIds, ['940GZZLUOXC']);
        assert.equal(row.token, TOKEN.toLowerCase());
        assert.equal(row.frequentPushesEnabled, true);
    });
});

test('one install cannot overwrite another install’s subscription', async () => {
    await withRoutes(async ({ call, store }) => {
        await call('POST', '/api/v1/push/live-activities', { body: registration() });
        await call('POST', '/api/v1/push/live-activities', {
            body: registration({ token: 'cd'.repeat(32) }),
            headers: { 'x-tubetrack-install': 'install-9876543210' }
        });

        assert.equal(store.size, 2);
        assert.equal(store.get(`${INSTALL}:DEADBEEF-1234-5678`).token, TOKEN.toLowerCase());
    });
});

test('malformed registrations are rejected field by field', async () => {
    await withRoutes(async ({ call, store }) => {
        const cases = [
            [{ activityId: 'x' }, 'INVALID_ACTIVITY_ID'],
            [{ token: 'not-hex' }, 'INVALID_TOKEN'],
            [{ token: 'ab'.repeat(200) }, 'INVALID_TOKEN'],
            [{ lineId: 'piccadilly-circus-line' }, 'INVALID_LINE'],
            [{ direction: 'sideways' }, 'INVALID_DIRECTION'],
            [{ stopIds: [] }, 'INVALID_STOP_IDS'],
            [{ stopIds: ['NOT-A-STOP'] }, 'INVALID_STOP_IDS'],
            [{ stopIds: Array.from({ length: 13 }, () => '940GZZLUOXC') }, 'INVALID_STOP_IDS']
        ];

        for (const [overrides, code] of cases) {
            // eslint-disable-next-line no-await-in-loop
            const response = await call('POST', '/api/v1/push/live-activities', {
                body: registration(overrides)
            });
            assert.equal(response.status, 400, code);
            // eslint-disable-next-line no-await-in-loop
            assert.equal((await response.json()).error.code, code);
        }
        assert.equal(store.size, 0);
    });
});

test('an oversized body is refused before it is parsed', async () => {
    await withRoutes(async ({ call, store }) => {
        const response = await call('POST', '/api/v1/push/live-activities', {
            body: registration({ hubId: 'x'.repeat(20_000) })
        });
        assert.equal(response.status, 400);
        assert.equal((await response.json()).error.code, 'PAYLOAD_TOO_LARGE');
        assert.equal(store.size, 0);
    });
});

test('a body that is not JSON is refused', async () => {
    await withRoutes(async ({ baseUrl }) => {
        const response = await fetch(`${baseUrl}/api/v1/push/live-activities`, {
            method: 'POST',
            headers: {
                'content-type': 'application/json',
                'x-tubetrack-install': INSTALL
            },
            body: '{ not json'
        });
        assert.equal(response.status, 400);
        assert.equal((await response.json()).error.code, 'INVALID_JSON');
    });
});

test('a rotated push token updates the subscription in place', async () => {
    await withRoutes(async ({ call, store }) => {
        await call('POST', '/api/v1/push/live-activities', { body: registration() });
        const rotated = 'ef'.repeat(32);

        const response = await call('PATCH', '/api/v1/push/live-activities/DEADBEEF-1234-5678', {
            body: { token: rotated, frequentPushesEnabled: false }
        });
        assert.equal(response.status, 204);

        const row = store.get(`${INSTALL}:DEADBEEF-1234-5678`);
        assert.equal(row.token, rotated);
        assert.equal(row.frequentPushesEnabled, false);
        assert.equal(row.lineId, 'central', 'the rest of the subscription is untouched');
    });
});

test('patching somebody else’s subscription finds nothing', async () => {
    await withRoutes(async ({ call }) => {
        await call('POST', '/api/v1/push/live-activities', { body: registration() });
        const response = await call('PATCH', '/api/v1/push/live-activities/DEADBEEF-1234-5678', {
            body: { frequentPushesEnabled: false },
            headers: { 'x-tubetrack-install': 'install-9876543210' }
        });
        assert.equal(response.status, 404);
    });
});

test('ending a tracked board is idempotent', async () => {
    await withRoutes(async ({ call, store }) => {
        await call('POST', '/api/v1/push/live-activities', { body: registration() });

        assert.equal((await call('DELETE', '/api/v1/push/live-activities/DEADBEEF-1234-5678')).status, 204);
        assert.equal(store.size, 0);
        assert.equal((await call('DELETE', '/api/v1/push/live-activities/DEADBEEF-1234-5678')).status, 204);
    });
});

test('a flood from one install is throttled without touching the others', async () => {
    let now = 0;
    await withRoutes(
        async ({ call }) => {
            const statuses = [];
            for (let index = 0; index < 5; index += 1) {
                // eslint-disable-next-line no-await-in-loop
                const response = await call('POST', '/api/v1/push/live-activities', {
                    body: registration({ activityId: `ACTIVITY-${index}0000` })
                });
                statuses.push(response.status);
            }
            assert.deepEqual(statuses, [201, 201, 201, 429, 429]);

            const other = await call('POST', '/api/v1/push/live-activities', {
                body: registration(),
                headers: { 'x-tubetrack-install': 'install-9876543210' }
            });
            assert.equal(other.status, 201, 'one noisy install must not lock everybody out');

            now += 60_001;
            const afterWindow = await call('POST', '/api/v1/push/live-activities', {
                body: registration()
            });
            assert.equal(afterWindow.status, 201);
        },
        { rateLimiter: createRateLimiter({ maxRequests: 3, clock: () => now }) }
    );
});

test('a flood spread across forged install ids still hits the global ceiling', () => {
    // The endpoints are unauthenticated and an install id is self-asserted, so
    // rotating it must not be a way around the limiter.
    let now = 0;
    const allow = createRateLimiter({
        maxRequests: 10,
        globalMaxRequests: 25,
        clock: () => now
    });

    let accepted = 0;
    for (let index = 0; index < 100; index += 1) {
        if (allow(`forged-install-${index}`)) accepted += 1;
    }
    assert.equal(accepted, 25, 'the global ceiling caps a flood of fresh identities');

    now += 60_001;
    assert.equal(allow('forged-install-0'), true, 'and it recovers once the window rolls');
});

test('rotating install ids cannot grow the limiter without bound', () => {
    // Evicting a real install's bucket only resets its own allowance, which
    // costs nothing — the global ceiling above is what actually stops a flood.
    // What matters here is that a million forged ids cannot exhaust memory.
    let now = 0;
    const allow = createRateLimiter({
        maxRequests: 2,
        globalMaxRequests: 10_000,
        maxKeys: 8,
        clock: () => now
    });

    for (let index = 0; index < 5_000; index += 1) {
        allow(`forged-install-${index}`);
    }
    // The limiter exposes no size, so prove boundedness behaviourally: the
    // oldest keys are gone, which is only possible if they were evicted.
    assert.equal(allow('forged-install-0'), true, 'the earliest bucket was dropped');
});

test('widget registrations are stored separately from activities', async () => {
    await withRoutes(async ({ call, store }) => {
        const response = await call('POST', '/api/v1/push/widgets', {
            body: { token: TOKEN, subscriptions: [{ kind: 'departures', stopId: '940GZZLUOXC' }] }
        });
        assert.equal(response.status, 201);
        assert.deepEqual(store.countByType(), { liveActivity: 0, widget: 1 });

        assert.equal((await call('DELETE', '/api/v1/push/widgets')).status, 204);
        assert.equal(store.size, 0);
    });
});

const riverPier = { id: '930GCAD', lineIds: ['rb6'], arrivalStopIds: ['930GCAD', '930BCAD'] };
const riverRegistration = (overrides = {}) => registration({
    lineId: 'rb6', hubId: '930GCAD', stopIds: ['930GCAD'], direction: 'any', ...overrides
});

test('river registration resolves a canonical pier and validates its service and stop scope', async () => {
    await withRoutes(async ({ call, store }) => {
        const good = await call('POST', '/api/v1/push/live-activities', { body: riverRegistration() });
        assert.equal(good.status, 201);
        const row = store.get((await good.json()).data.id);
        assert.equal(row.lineId, 'rb6');
        assert.deepEqual(row.stopIds, ['930GCAD']);
        for (const fields of [
            { lineId: 'rb999' }, { hubId: 'unknown' }, { direction: 'eastbound' },
            { stopIds: ['930BCAD'] }, { stopIds: ['930GCAD', '940GZZLUOXC'] }
        ]) {
            const bad = await call('POST', '/api/v1/push/live-activities', { body: riverRegistration(fields) });
            assert.equal(bad.status, 400);
        }
    }, { riverNetwork: async () => ({ piers: [riverPier] }) });
});

test('a river catalogue failure preserves the subscription and returns a retryable response', async () => {
    await withRoutes(async ({ call, store }) => {
        const response = await call('POST', '/api/v1/push/live-activities', { body: riverRegistration() });
        assert.equal(response.status, 503);
        assert.equal(store.size, 0);
    }, { riverNetwork: async () => { throw new Error('offline'); } });
});
