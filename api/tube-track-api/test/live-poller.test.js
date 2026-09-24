import assert from 'node:assert/strict';
import test from 'node:test';

import { LiveCache } from '../lib/live-cache.js';
import { LivePoller } from '../lib/live-poller.js';
import { prediction } from './helpers.js';

function testMetrics() {
    return {
        requests: [],
        refreshes: [],
        cache: null,
        observeRefresh(value) {
            this.refreshes.push(value);
        },
        setCache(value) {
            this.cache = value;
        }
    };
}

test('replaces the cache only after every mode succeeds', async () => {
    const cache = new LiveCache();
    const metrics = testMetrics();
    const modes = ['tube', 'elizabeth-line'];
    const client = {
        async fetchArrivals(mode) {
            return [prediction({
                id: `${mode}-1`,
                vehicleId: `${mode}-vehicle`,
                lineId: mode === 'elizabeth-line' ? 'elizabeth' : 'victoria',
                modeName: mode
            })];
        }
    };
    const poller = new LivePoller({
        modes,
        client,
        cache,
        metrics,
        requestStaggerMs: 0
    });

    const result = await poller.refreshOnce();

    assert.equal(result.state.snapshot.arrivals.length, 2);
    assert.deepEqual(result.state.snapshot.modeCounts, {
        tube: 1,
        'elizabeth-line': 1
    });
    assert.equal(metrics.refreshes.at(-1).status, 'success');
    assert.equal(metrics.cache.itemCount, 2);
});

test('keeps the last successful generation when one mode fails', async () => {
    const cache = new LiveCache();
    cache.replace([], {
        startedAt: 1,
        completedAt: 2,
        modeCounts: { tube: 0 }
    });
    const originalGeneration = cache.read().snapshot.generation;
    const metrics = testMetrics();
    const poller = new LivePoller({
        modes: ['tube', 'elizabeth-line'],
        client: {
            async fetchArrivals(mode) {
                if (mode === 'elizabeth-line') {
                    throw new Error('simulated failure');
                }
                return [prediction()];
            }
        },
        cache,
        metrics,
        requestStaggerMs: 0
    });

    await assert.rejects(poller.refreshOnce(), /simulated failure/);
    assert.equal(cache.read().snapshot.generation, originalGeneration);
    assert.equal(metrics.refreshes.at(-1).status, 'failure');
});

function testLogger() {
    const entries = [];
    return {
        entries,
        info: (event, details) => entries.push({ level: 'info', event, details }),
        warn: (event, details) => entries.push({ level: 'warn', event, details }),
        error: (event, details) => entries.push({ level: 'error', event, details })
    };
}

function deferred() {
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
    return { promise, resolve, reject };
}

async function settled(predicate, { timeoutMs = 2_000 } = {}) {
    const deadline = Date.now() + timeoutMs;
    while (!predicate()) {
        if (Date.now() > deadline) {
            throw new Error('condition not met in time');
        }
        await new Promise((resolve) => setTimeout(resolve, 5));
    }
}

test('a refresh whose upstream request never settles times out and the loop keeps polling', async () => {
    // Regression for the 2026-09-21 stall: one mode fetch hung for hours, the
    // refreshing flag stayed set and no further poll ever ran.
    const cache = new LiveCache({ staleAfterMs: 1_000 });
    const metrics = testMetrics();
    const logger = testLogger();
    const calls = [];
    let hangOnce = true;
    const stuck = deferred();
    const client = {
        async fetchArrivals(mode, { signal }) {
            calls.push({ mode, signal });
            if (mode === 'overground' && hangOnce) {
                hangOnce = false;
                return stuck.promise; // ignores the abort signal entirely
            }
            return [prediction({ id: `${mode}-${calls.length}`, vehicleId: `${mode}-${calls.length}`, modeName: mode })];
        }
    };
    const poller = new LivePoller({
        modes: ['tube', 'overground'],
        client,
        cache,
        metrics,
        logger,
        requestStaggerMs: 0,
        pollIntervalMs: 1_000,
        refreshTimeoutMs: 40,
        watchdogIntervalMs: 60_000
    });

    poller.start();
    try {
        await settled(() => metrics.refreshes.some((entry) => entry.status === 'timeout'));
        assert.equal(poller.refreshing, false);
        assert.equal(poller.status().lastError.code, 'LIVE_REFRESH_TIMEOUT');
        assert.equal(calls[1].signal.aborted, true, 'the stuck request is told to abort');
        const failure = logger.entries.find((entry) => entry.event === 'live_cache_refresh_failed');
        assert.equal(failure.details.error.code, 'LIVE_REFRESH_TIMEOUT');
        assert.equal(cache.read(), null, 'a timed-out attempt publishes nothing');

        // The loop must carry on: the next cycle succeeds (pollInterval floor is 1s).
        await settled(() => metrics.refreshes.some((entry) => entry.status === 'success'), { timeoutMs: 3_000 });
        assert.equal(cache.read().snapshot.arrivals.length, 2);
        const generation = cache.read().snapshot.generation;

        // If the zombie request finally resolves, its stale data must not be published.
        stuck.resolve([prediction({ id: 'zombie', vehicleId: 'zombie', modeName: 'overground' })]);
        await new Promise((resolve) => setTimeout(resolve, 20));
        assert.equal(cache.read().snapshot.generation, generation);
        assert.ok(!cache.read().snapshot.arrivals.some((arrival) => arrival.id === 'zombie'));
    } finally {
        await poller.stop();
    }
});

test('stop() returns promptly even while an upstream request ignores abort', async () => {
    const poller = new LivePoller({
        modes: ['tube'],
        client: { fetchArrivals: () => new Promise(() => {}) },
        cache: new LiveCache(),
        metrics: testMetrics(),
        requestStaggerMs: 0,
        refreshTimeoutMs: 60_000,
        watchdogIntervalMs: 60_000
    });
    poller.start();
    await settled(() => poller.refreshing);

    const startedAt = Date.now();
    await poller.stop();
    assert.ok(Date.now() - startedAt < 500);
    assert.equal(poller.refreshing, false);
    assert.equal(poller.status().lastError, null, 'shutdown is not recorded as a failure');
});

test('watchdog logs while the cache is stale and reports recovery', () => {
    let nowMs = 1_000_000;
    const clock = () => nowMs;
    const cache = new LiveCache({ staleAfterMs: 90_000, clock });
    const logger = testLogger();
    const poller = new LivePoller({
        modes: ['tube'],
        client: { fetchArrivals: async () => [] },
        cache,
        metrics: testMetrics(),
        logger,
        clock
    });
    poller.startedAt = nowMs;

    // Starting up: nothing to report inside the stale window.
    assert.equal(poller.checkHealth().stale, false);

    cache.replace([], { startedAt: nowMs, completedAt: nowMs, modeCounts: {} });
    nowMs += 60_000;
    assert.equal(poller.checkHealth().stale, false);
    assert.equal(logger.entries.length, 0);

    nowMs += 6 * 60 * 60 * 1_000;
    poller.refreshing = true;
    poller.lastAttemptAt = 'attempt';
    const report = poller.checkHealth();
    assert.equal(report.stale, true);
    const warning = logger.entries.find((entry) => entry.event === 'live_cache_stale');
    assert.ok(warning);
    assert.equal(warning.level, 'warn');
    assert.equal(warning.details.ageSeconds, 21_660);
    assert.equal(warning.details.staleForSeconds, 21_570);
    assert.equal(warning.details.refreshing, true);
    assert.equal(warning.details.lastAttemptAt, 'attempt');
    assert.equal(poller.status().staleSince, 1_000_000 + 90_000);

    nowMs += 30_000;
    poller.checkHealth();
    assert.equal(logger.entries.filter((entry) => entry.event === 'live_cache_stale').length, 2);

    cache.replace([], { startedAt: nowMs, completedAt: nowMs, modeCounts: {} });
    nowMs += 1_000;
    assert.equal(poller.checkHealth().stale, false);
    const recovered = logger.entries.find((entry) => entry.event === 'live_cache_recovered');
    assert.ok(recovered);
    assert.equal(recovered.details.staleForSeconds, 21_601);
    assert.equal(poller.status().staleSince, null);
});

test('watchdog reports a cache that was never populated once the stale window has passed', () => {
    let nowMs = 5_000_000;
    const clock = () => nowMs;
    const logger = testLogger();
    const poller = new LivePoller({
        modes: ['tube'],
        client: { fetchArrivals: async () => [] },
        cache: new LiveCache({ staleAfterMs: 90_000, clock }),
        metrics: testMetrics(),
        logger,
        clock
    });
    poller.startedAt = nowMs;
    nowMs += 90_001;

    assert.equal(poller.checkHealth().stale, true);
    const warning = logger.entries.find((entry) => entry.event === 'live_cache_stale');
    assert.equal(warning.details.ageSeconds, null);
    assert.equal(warning.details.lastSuccessAt, null);
});

test('watchdog restarts a polling loop that stopped without being asked', async () => {
    let nowMs = 0;
    const clock = () => nowMs;
    const cache = new LiveCache({ staleAfterMs: 90_000, clock });
    const logger = testLogger();
    const poller = new LivePoller({
        modes: ['tube'],
        client: { fetchArrivals: async () => [prediction()] },
        cache,
        metrics: testMetrics(),
        logger,
        clock,
        requestStaggerMs: 0,
        watchdogIntervalMs: 60_000
    });
    // Simulate a dead loop: running, but no loop promise and a stale cache.
    poller.running = true;
    poller.startedAt = nowMs;
    poller.controller = new AbortController();
    nowMs = 200_000;

    poller.checkHealth();
    assert.ok(logger.entries.some((entry) => entry.event === 'live_poll_loop_restarted'));
    assert.ok(poller.loopPromise);
    await settled(() => cache.read() !== null);
    await poller.stop();
});

test('a notifier that throws cannot fail a refresh that already succeeded', async () => {
    const errors = [];
    const poller = new LivePoller({
        modes: ['tube'],
        client: { fetchArrivals: async () => [prediction()] },
        cache: new LiveCache(),
        logger: { info: () => {}, error: (event) => errors.push(event), warn: () => {} },
        notifier: {
            notify() {
                throw new Error('push exploded');
            }
        },
        requestStaggerMs: 0
    });

    const result = await poller.refreshOnce();
    assert.equal(result.skipped, false);
    assert.equal(result.state.snapshot.arrivals.length, 1);
    assert.deepEqual(errors, ['push_notify_failed']);
});

test('a notifier that rejects cannot fail a refresh either', async () => {
    const errors = [];
    const poller = new LivePoller({
        modes: ['tube'],
        client: { fetchArrivals: async () => [prediction()] },
        cache: new LiveCache(),
        logger: { info: () => {}, error: (event) => errors.push(event), warn: () => {} },
        notifier: { notify: async () => { throw new Error('apns down'); } },
        requestStaggerMs: 0
    });

    const result = await poller.refreshOnce();
    assert.equal(result.skipped, false);
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(errors, ['push_notify_failed']);
});

test('the snapshot handed to the notifier is the one just published', async () => {
    const seen = [];
    const poller = new LivePoller({
        modes: ['tube'],
        client: { fetchArrivals: async () => [prediction()] },
        cache: new LiveCache(),
        logger: { info: () => {}, error: () => {}, warn: () => {} },
        notifier: { notify: async (snapshot) => seen.push(snapshot) },
        requestStaggerMs: 0
    });

    const result = await poller.refreshOnce();
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(seen.length, 1);
    assert.equal(seen[0], result.state.snapshot);
});
