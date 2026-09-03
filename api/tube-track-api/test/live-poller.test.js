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
