import assert from 'node:assert/strict';
import test from 'node:test';

import { LiveCache } from '../lib/live-cache.js';
import { normaliseArrival } from '../lib/normalise-arrival.js';
import { prediction } from './helpers.js';

test('atomically indexes arrivals without cloning indexed records', () => {
    let now = 2_000;
    const cache = new LiveCache({
        staleAfterMs: 5_000,
        clock: () => now
    });
    const later = normaliseArrival(prediction({
        id: 'later',
        timeToStation: 120
    }), 'tube');
    const sooner = normaliseArrival(prediction({
        id: 'sooner',
        timeToStation: 30
    }), 'tube');

    cache.replace([later, sooner], {
        startedAt: 1_000,
        completedAt: 2_000,
        modeCounts: { tube: 2 }
    });

    let state = cache.read();
    assert.equal(state.snapshot.arrivals.length, 2);
    assert.equal(state.snapshot.arrivalsByStop.get(sooner.stopId)[0], sooner);
    assert.equal(state.snapshot.trainsByVehicleId.get('victoria:vehicle-1'), sooner);
    assert.equal(state.stale, false);

    now = 8_001;
    state = cache.read();
    assert.equal(state.stale, true);
    assert.equal(state.ageSeconds, 6);
});

test('derives countdown seconds when the mode feed only supplies timestamps', () => {
    const arrival = normaliseArrival(prediction({ timeToStation: null }), 'tube');

    assert.equal(arrival.timeToStation, 90);
});

test('marks a mode that has never loaded as stale without hiding healthy arrivals', () => {
    let nowMs = 10_000;
    const cache = new LiveCache({ staleAfterMs: 5_000, clock: () => nowMs });
    const tube = normaliseArrival(prediction({ id: 'tube' }), 'tube');
    const state = cache.replaceModes(new Map([['tube', [tube]]]), {
        modes: ['tube', 'elizabeth-line'], startedAt: nowMs, completedAt: nowMs
    });

    assert.deepEqual(state.snapshot.arrivals.map((arrival) => arrival.id), ['tube']);
    assert.equal(state.snapshot.modeUpdatedAt['elizabeth-line'], null);
    assert.deepEqual(state.staleModes, ['elizabeth-line']);
    assert.equal(state.stale, true);

    nowMs += 5_001;
    assert.deepEqual(cache.read().staleModes, ['tube', 'elizabeth-line']);
});
