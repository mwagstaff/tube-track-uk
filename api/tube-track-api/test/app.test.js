import assert from 'node:assert/strict';
import test from 'node:test';

import { createApp } from '../lib/app.js';
import { LiveCache } from '../lib/live-cache.js';
import { createMetrics } from '../lib/metrics.js';
import { normaliseArrival } from '../lib/normalise-arrival.js';
import { ResourceCache } from '../lib/resource-cache.js';
import { prediction } from './helpers.js';

async function withServer(run) {
    const cache = new LiveCache();
    const poller = {
        status: () => ({
            running: true,
            refreshing: false,
            lastAttemptAt: null,
            lastSuccessAt: null,
            lastError: null
        })
    };
    const metrics = createMetrics({ cache, collectProcessMetrics: false });
    const upstreamRequests = [];
    const client = {
        fetchJSON: async (path, options) => {
            upstreamRequests.push({ path, options });
            return [];
        }
    };
    const resourceCache = new ResourceCache();
    const app = createApp({ cache, poller, metrics, client, resourceCache });
    const server = await new Promise((resolve) => {
        const listening = app.listen(0, '127.0.0.1', () => resolve(listening));
    });
    const address = server.address();
    const baseUrl = `http://127.0.0.1:${address.port}`;
    try {
        await run({ baseUrl, cache, upstreamRequests });
    } finally {
        await new Promise((resolve) => server.close(resolve));
    }
}

test('reports starting and returns 503 before the live cache is ready', async () => {
    await withServer(async ({ baseUrl }) => {
        const health = await fetch(`${baseUrl}/healthcheck`);
        assert.equal(health.status, 503);
        assert.equal((await health.json()).ready, false);

        const live = await fetch(`${baseUrl}/api/v1/live`);
        assert.equal(live.status, 503);
        assert.equal((await live.json()).error.code, 'LIVE_CACHE_NOT_READY');
    });
});

test('filters the shared live snapshot for line and station requests', async () => {
    await withServer(async ({ baseUrl, cache, upstreamRequests }) => {
        const victoria = normaliseArrival(prediction(), 'tube');
        const central = {
            ...victoria,
            id: 'central-one',
            lineId: 'central',
            stopId: '940GZZLUCEN'
        };
        cache.replace([victoria, central], {
            startedAt: Date.now() - 100,
            completedAt: Date.now(),
            modeCounts: { tube: 2 }
        });

        const live = await fetch(`${baseUrl}/api/v1/live?lineIds=victoria`);
        assert.deepEqual((await live.json()).data.map((item) => item.lineId), ['victoria']);

        const arrivals = await fetch(`${baseUrl}/api/v1/arrivals/940GZZLUSVS`);
        assert.deepEqual((await arrivals.json()).data.map((item) => item.id), [victoria.id]);
        assert.equal(upstreamRequests.length, 0);
    });
});

test('caches status requests and validates planned-work dates', async () => {
    await withServer(async ({ baseUrl, upstreamRequests }) => {
        const first = await fetch(`${baseUrl}/api/v1/status`);
        const second = await fetch(`${baseUrl}/api/v1/status`);
        assert.equal(first.status, 200);
        assert.equal(second.status, 200);
        assert.equal(upstreamRequests.length, 1);
        assert.match(upstreamRequests[0].path, /\/Line\/Mode\/.+\/Status/);

        const invalid = await fetch(`${baseUrl}/api/v1/planned-works?from=nope&to=2026-09-03`);
        assert.equal(invalid.status, 400);
        assert.equal((await invalid.json()).error.code, 'INVALID_DATE_RANGE');
    });
});

test('serves normalised live data, health state, conditional responses and metrics', async () => {
    await withServer(async ({ baseUrl, cache }) => {
        const arrival = normaliseArrival(prediction(), 'tube');
        cache.replace([arrival], {
            startedAt: Date.now() - 100,
            completedAt: Date.now(),
            modeCounts: { tube: 1 }
        });

        const health = await fetch(`${baseUrl}/healthcheck`);
        assert.equal(health.status, 200);
        const healthBody = await health.json();
        assert.equal(healthBody.status, 'ok');
        assert.equal(healthBody.liveCache.count, 1);

        const live = await fetch(`${baseUrl}/api/v1/live`);
        assert.equal(live.status, 200);
        const etag = live.headers.get('etag');
        const liveBody = await live.json();
        assert.equal(liveBody.data[0].stopId, '940GZZLUSVS');
        assert.equal(liveBody.data[0].naptanId, undefined);
        assert.equal(liveBody.meta.count, 1);

        const unchanged = await fetch(`${baseUrl}/api/v1/live`, {
            headers: { 'if-none-match': etag }
        });
        assert.equal(unchanged.status, 304);

        const metrics = await fetch(`${baseUrl}/metrics`);
        assert.equal(metrics.status, 200);
        assert.match(await metrics.text(), /tube_track_http_requests_total/);
    });
});

test('returns a bounded JSON 404 for unknown paths', async () => {
    await withServer(async ({ baseUrl }) => {
        const response = await fetch(`${baseUrl}/does-not-exist`);
        assert.equal(response.status, 404);
        assert.equal((await response.json()).error.code, 'NOT_FOUND');
    });
});
