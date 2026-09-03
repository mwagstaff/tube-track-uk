import assert from 'node:assert/strict';
import test from 'node:test';

import { ResourceCache } from '../lib/resource-cache.js';

test('coalesces concurrent loads and serves stale data after an upstream failure', async () => {
    let now = 1_000;
    let loads = 0;
    const cache = new ResourceCache({ clock: () => now });
    const load = async () => {
        loads += 1;
        await Promise.resolve();
        return ['ok'];
    };

    const [first, second] = await Promise.all([
        cache.get('status', { freshForMs: 100, load }),
        cache.get('status', { freshForMs: 100, load })
    ]);
    assert.deepEqual(first.data, ['ok']);
    assert.deepEqual(second.data, ['ok']);
    assert.equal(loads, 1);

    now += 200;
    const stale = await cache.get('status', {
        freshForMs: 100,
        load: async () => { throw new Error('offline'); }
    });
    assert.deepEqual(stale.data, ['ok']);
    assert.equal(stale.meta.cached, true);
    assert.equal(stale.meta.stale, true);
});
