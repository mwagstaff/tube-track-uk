import assert from 'node:assert/strict';
import test from 'node:test';

import { TfLClient, TfLRequestError } from '../lib/tfl-client.js';
import { prediction } from './helpers.js';

test('adds the API key and count parameter without returning raw response metadata', async () => {
    let requestedUrl;
    const observations = [];
    const client = new TfLClient({
        apiKey: 'private-test-key',
        fetchImpl: async (url) => {
            requestedUrl = new URL(url);
            return new Response(JSON.stringify([prediction()]), {
                status: 200,
                headers: { 'content-type': 'application/json' }
            });
        },
        metrics: {
            observeTflRequest(value) {
                observations.push(value);
            }
        }
    });

    const result = await client.fetchArrivals('tube');

    assert.equal(requestedUrl.pathname, '/Mode/tube/Arrivals');
    assert.equal(requestedUrl.searchParams.get('count'), '-1');
    assert.equal(requestedUrl.searchParams.get('app_key'), 'private-test-key');
    assert.equal(result.length, 1);
    assert.equal(observations[0].status, '200');
    assert.equal(
        observations[0].url,
        'https://api.tfl.gov.uk/Mode/tube/Arrivals?count=-1'
    );
    assert.doesNotMatch(observations[0].url, /private-test-key|app_key/);
    assert.ok(observations[0].responseBytes > 0);
});

test('wraps HTTP failures without putting the secret in the error', async () => {
    const client = new TfLClient({
        apiKey: 'do-not-leak-this',
        fetchImpl: async () => new Response('rate limited', { status: 429 })
    });

    await assert.rejects(
        client.fetchArrivals('tube'),
        (error) => {
            assert.ok(error instanceof TfLRequestError);
            assert.equal(error.status, 429);
            assert.equal(error.code, 'TFL_HTTP_ERROR');
            assert.doesNotMatch(error.message, /do-not-leak-this/);
            return true;
        }
    );
});

test('rejects a successful non-array response', async () => {
    const client = new TfLClient({
        apiKey: 'test-key',
        fetchImpl: async () => new Response('{}', { status: 200 })
    });

    await assert.rejects(
        client.fetchArrivals('tube'),
        (error) => error.code === 'TFL_INVALID_RESPONSE'
    );
});

test('queues requests beyond the configured TfL concurrency limit', async () => {
    const resolvers = [];
    const queueDepths = [];
    const inFlight = [];
    const client = new TfLClient({
        apiKey: 'test-key',
        maxConcurrentRequests: 1,
        fetchImpl: () => new Promise((resolve) => resolvers.push(resolve)),
        metrics: {
            setTflRequestQueueDepth(value) {
                queueDepths.push(value);
            },
            setTflRequestsInFlight(value) {
                inFlight.push(value);
            }
        }
    });

    const first = client.fetchJSON('/first');
    const second = client.fetchJSON('/second');
    await new Promise((resolve) => setImmediate(resolve));

    assert.equal(resolvers.length, 1);
    assert.equal(queueDepths.at(-1), 1);
    assert.equal(inFlight.at(-1), 1);

    resolvers.shift()(new Response('{}', { status: 200 }));
    await first;
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(resolvers.length, 1);
    assert.equal(queueDepths.at(-1), 0);

    resolvers.shift()(new Response('{}', { status: 200 }));
    await second;
    assert.equal(inFlight.at(-1), 0);
});


test('per-request deadline releases the shared concurrency gate without changing the client default', async () => {
    const client = new TfLClient({
        apiKey: 'test-key', timeoutMs: 1000, maxConcurrentRequests: 1,
        fetchImpl: async (url, { signal }) => {
            if (url.pathname === '/fast') return new Response('{}');
            return new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
        }
    });
    const keepAlive = setTimeout(() => {}, 1500);
    try {
        const slow = client.fetchJSON('/slow', { timeoutMs: 10 });
        const next = client.fetchJSON('/fast');
        await assert.rejects(slow, error => error.code === 'TFL_TIMEOUT');
        assert.deepEqual(await next, {});
        assert.equal(client.activeRequests, 0);
        assert.equal(client.timeoutMs, 1000);
    } finally {
        clearTimeout(keepAlive);
    }
});
