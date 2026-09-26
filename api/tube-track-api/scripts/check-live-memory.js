// Run with node --expose-gc --max-old-space-size=192 scripts/check-live-memory.js.
// No credentials or network: exercises the real client, normalisation, poller,
// and cache with realistic JSON, while keeping the shutdown signal alive.
import assert from 'node:assert/strict';
import { setImmediate } from 'node:timers/promises';
import { LiveCache } from '../lib/live-cache.js';
import { LivePoller } from '../lib/live-poller.js';
import { TfLClient } from '../lib/tfl-client.js';
import { prediction } from '../test/helpers.js';

assert.equal(typeof global.gc, 'function', 'Run with --expose-gc');
const shutdown = new AbortController();
const cache = new LiveCache();
const body = JSON.stringify(Array.from({ length: 2_000 }, (_, index) => prediction({ id: String(index) })));
const client = new TfLClient({ apiKey: 'test', fetchImpl: async () => new Response(body) });
const poller = new LivePoller({ modes: ['tube'], cache, client, requestStaggerMs: 0 });
const oldArrivals = [];
const samples = [];

for (let cycle = 1; cycle <= 100; cycle += 1) {
    await poller.refreshOnce({ signal: shutdown.signal });
    oldArrivals.push(new WeakRef(cache.read().snapshot.arrivals[0]));
    // WeakRef targets stay alive until the end of their current JS job.
    await setImmediate();
    global.gc();
    if (cycle % 10 === 0) samples.push({ cycle, heapUsedBytes: process.memoryUsage().heapUsed });
}

const retainedGenerations = oldArrivals.filter((ref) => ref.deref()).length;
console.log(JSON.stringify({ node: process.version, samples, retainedGenerations }));
assert.equal(shutdown.signal.aborted, false);
assert.equal(retainedGenerations, 1, 'Only the current arrival generation should survive GC');
assert.ok(samples.at(-1).heapUsedBytes - samples[0].heapUsedBytes < 8 * 1024 * 1024,
    'Retained heap should plateau after warmup, not grow with every poll');
shutdown.abort();
