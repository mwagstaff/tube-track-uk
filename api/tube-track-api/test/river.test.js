import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import express from 'express';
import { createRiverRoutes, normaliseRiverNetwork, normaliseRiverArrivals } from '../lib/river.js';
import { ResourceCache } from '../lib/resource-cache.js';

const fixture = (name) => JSON.parse(readFileSync(new URL(`./fixtures/river/${name}.json`, import.meta.url)));
const sequences = ['rb1-inbound', 'rb1-outbound', 'rb4-inbound', 'rb4-outbound', 'rb6-inbound', 'rb6-outbound'].map(fixture);
const network = normaliseRiverNetwork(fixture('lines'), fixture('piers').stopPoints, sequences);
const now = Date.parse('2026-09-25T12:00:00Z');
const prediction = (overrides = {}) => ({
    id: 'one', vehicleId: 'opaque-trip-identity', tripId: 'trip-one', naptanId: '930GCAW', lineId: 'rb1',
    destinationNaptanId: '930GBRVS', destinationName: 'Barking Riverside Pier', direction: 'outbound',
    expectedArrival: new Date(now + 180_000).toISOString(), timestamp: new Date(now - 5_000).toISOString(),
    timeToLive: new Date(now + 180_000).toISOString(), ...overrides
});

test('recorded catalogue discovers 24 logical piers and all route variants, excludes ferry and bus children', () => {
    assert.equal(network.piers.length, 24);
    assert.equal(network.routes.length, 11);
    assert.deepEqual(network.lines.map((line) => line.id), ['rb1', 'rb4', 'rb6']);
    const putney = network.piers.find((pier) => pier.id === '930GPUT');
    assert.deepEqual(putney.lineIds, ['rb6']);
    assert.deepEqual(putney.arrivalStopIds, ['930GPUT', '9300PUT1']);
    assert.equal(network.routes.some((route) => 'geometry' in route), false);
});

test('a newly discovered RB line survives without adding an enum case', () => {
    const result = normaliseRiverNetwork([{ id: 'rb99', name: 'RB99' }], [{ id: '930GNEW', commonName: 'New Pier', stopType: 'NaptanFerryPort', lat: 51.5, lon: 0, lines: [{ id: 'rb99' }] }], []);
    assert.deepEqual(result.piers[0].lineIds, ['rb99']);
});

test('fresh outer timestamps never resurrect the expired recorded mode predictions', () => {
    assert.deepEqual(normaliseRiverArrivals(fixture('mode-arrivals'), network, Date.parse('2026-09-24T23:50:00Z')), []);
});

test('normalisation tolerates missing optional fields, derives freshness from absolute dates and merges berth duplicates', () => {
    const results = normaliseRiverArrivals([
        prediction(), prediction({ naptanId: '9300CAW1', id: 'berth-copy' }),
        null, {}, prediction({ lineId: 'tube' }),
        prediction({ id: 'without-vehicle', vehicleId: undefined, tripId: undefined, expectedArrival: new Date(now + 300_000).toISOString() })
    ], network, now);
    assert.equal(results.length, 2);
    assert.equal(results[0].pierId, '930GCAW');
    assert.equal(results[1].vehicleId, null);
    assert.equal(results[0].terminatesHere, false);
});

test('expired, stale and invalid predictions are dropped; terminal arrivals are marked', () => {
    const results = normaliseRiverArrivals([
        prediction({ expectedArrival: new Date(now - 1).toISOString() }),
        prediction({ timestamp: new Date(now - 120_000).toISOString() }),
        prediction({ timeToLive: new Date(now - 1).toISOString() }),
        prediction({ expectedArrival: 'invalid' }), prediction({ timestamp: undefined }),
        prediction({ destinationNaptanId: '930GCAW' })
    ], network, now);
    assert.equal(results.length, 1);
    assert.equal(results[0].terminatesHere, true);
});

test('river endpoints share cached requests, reject unknown piers and isolate upstream failure', async () => {
    const calls = [];
    let fail = false;
    const client = { fetchJSON: async (path) => {
        calls.push(path);
        if (path === '/Line/Mode/river-bus') return fixture('lines');
        if (path.startsWith('/StopPoint/Mode/river-bus')) return fixture('piers');
        if (path.includes('/Route/Sequence/')) {
            const parts = path.split('/'); return fixture(`${parts[2]}-${parts[5]}`);
        }
        if (path === '/Line/Mode/river-bus/Status') return fixture('status');
        if (fail) throw new Error('upstream unavailable');
        return [];
    } };
    const app = express();
    app.use('/river', createRiverRoutes({ client, resourceCache: new ResourceCache() }));
    const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
    const url = `http://127.0.0.1:${server.address().port}/river`;
    try {
        const [a, b] = await Promise.all([fetch(`${url}/network`), fetch(`${url}/network`)]);
        assert.equal(a.status, 200); assert.equal(b.status, 200);
        assert.equal(calls.filter((p) => p === '/Line/Mode/river-bus').length, 1);
        assert.equal((await fetch(`${url}/arrivals/unknown`)).status, 404);
        assert.equal((await fetch(`${url}/arrivals/930GCAW`)).status, 200);
        assert.equal((await fetch(`${url}/arrivals/930GCAW`)).status, 200);
        assert.equal(calls.filter((p) => p === '/StopPoint/930GCAW/Arrivals').length, 1);
        assert.equal(calls.includes('/StopPoint/4900CAW0/Arrivals'), false);
        fail = true;
        assert.equal((await fetch(`${url}/live`)).status, 503);
        assert.equal((await fetch(`${url}/status`)).status, 200);
        assert.equal((await fetch(`${url}/network`)).status, 200);
    } finally { await new Promise((resolve) => server.close(resolve)); }
});

test('shared boat endpoint serves immediate estimates, coalesces upstream reads, and holds bounded gaps', async () => {
    let clock = now, modeCalls = 0, empty = false, fail = false;
    const raw = [
        prediction({ vehicleId: 'donor', tripId: 'donor', naptanId: '930GTMP', expectedArrival: new Date(now + 300_000).toISOString() }),
        prediction({ vehicleId: 'donor', tripId: 'donor', naptanId: '930GCAW', expectedArrival: new Date(now + 600_000).toISOString() }),
        prediction({ vehicleId: 'subject', tripId: 'subject', expectedArrival: new Date(now + 180_000).toISOString() })
    ];
    const client = { fetchJSON: async (path) => {
        if (path === '/Line/Mode/river-bus') return fixture('lines');
        if (path.startsWith('/StopPoint/Mode/river-bus')) return fixture('piers');
        if (path.includes('/Route/Sequence/')) {
            const parts = path.split('/'); return fixture(`${parts[2]}-${parts[5]}`);
        }
        modeCalls++;
        if (fail) throw new Error('offline');
        return empty ? [] : raw;
    } };
    const app = express();
    app.use('/river', createRiverRoutes({ client, resourceCache: new ResourceCache({ clock: () => clock }), clock: () => clock }));
    const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
    const url = `http://127.0.0.1:${server.address().port}/river`;
    try {
        const [first, second] = await Promise.all([fetch(`${url}/boats`).then((r) => r.json()), fetch(`${url}/boats`).then((r) => r.json())]);
        assert.equal(first.data.length, 1); assert.deepEqual(first.data, second.data);
        assert.equal(first.data[0].basis, 'predictedTravelTime'); assert.equal(modeCalls, 1);
        assert.equal((await fetch(`${url}/live`).then((r) => r.json())).data.length, 3);
        assert.equal(modeCalls, 1);
        clock += 31_000; empty = true;
        const held = await fetch(`${url}/boats`).then((r) => r.json());
        assert.deepEqual(held.data, first.data); assert.equal(held.meta.stale, true);
        assert.equal(held.meta.updatedAt, first.meta.updatedAt);
        clock += 31_000; fail = true;
        const failure = await fetch(`${url}/boats`).then((r) => r.json());
        assert.deepEqual(failure.data, first.data); assert.equal(failure.meta.stale, true);
        clock += 31_000;
        assert.deepEqual((await fetch(`${url}/boats`).then((r) => r.json())).data, []);
    } finally { await new Promise((resolve) => server.close(resolve)); }
});

test('recorded daytime boards produce seven immediate estimates and survive their observed empty-feed gap', async () => {
    const { RiverBoatEstimator } = await import('../lib/river-boat-estimator.js');
    const captured = fixture('live-2026-09-25');
    const estimator = new RiverBoatEstimator();
    const start = Date.parse(captured.meta.updatedAt);
    const boats = estimator.update(captured.data, network, start);
    assert.equal(captured.data.length, 104);
    assert.equal(boats.length, 7);
    assert.equal(boats.filter((boat) => boat.basis === 'predictedTravelTime').length, 5);
    assert.equal(boats.filter((boat) => boat.basis === 'reverseTravelTime').length, 2);
    assert.deepEqual(estimator.update([], network, Date.parse('2026-09-25T11:18:06.596Z')), boats);
    assert.deepEqual(estimator.update([], network, Date.parse('2026-09-25T11:18:32Z')), []);
});

// The return-journey rows are captured from the live feed at 11:44 UTC.
// The approaching row below is synthetic: it recreates the screenshot's
// two-minute Royal Wharf board, not an asserted historical API response.
test('Royal Wharf approach can use recorded return timings before a pier transition is observed', async () => {
    const { RiverBoatEstimator } = await import('../lib/river-boat-estimator.js');
    const captured = fixture('royal-wharf-return-2026-09-25');
    const start = Date.parse(captured.meta.updatedAt);
    const approaching = { ...captured.data.find(p => p.pierId === '930GWRF'),
        id: 'synthetic-royal-wharf-approach', vehicleId: 'approaching', tripId: 'approaching',
        direction: 'outbound', destinationId: '930GBRVS', destinationName: 'Barking Riverside Pier',
        expectedArrival: new Date(start + 120_000).toISOString() };
    const estimator = new RiverBoatEstimator();
    const boats = estimator.update([...captured.data, approaching], network, start);
    assert.equal(boats.length, 1);
    assert.equal(boats[0].previousPierId, '930GMIL');
    assert.equal(boats[0].nextPierId, '930GWRF');
    assert.equal(boats[0].basis, 'reverseTravelTime');
    assert.equal(Date.parse(boats[0].segmentStartedAt), start - 120_000);
    assert.deepEqual(estimator.current(Date.parse(approaching.observedAt) + 90_000), []);
});
