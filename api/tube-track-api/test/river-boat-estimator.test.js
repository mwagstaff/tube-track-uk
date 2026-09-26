import assert from 'node:assert/strict';
import test from 'node:test';
import { RiverBoatEstimator } from '../lib/river-boat-estimator.js';

const now = Date.parse('2026-09-25T12:00:00Z');
const at = (seconds) => new Date(now + seconds * 1000).toISOString();
const network = { routes: [{ lineId: 'rb1', direction: 'outbound', stopIds: ['A', 'B', 'C', 'D'] }] };
const prediction = (vehicleId, pierId, arrival, observed = 0, overrides = {}) => ({
    vehicleId, tripId: vehicleId, pierId, lineId: 'rb1', direction: 'outbound',
    destinationId: 'D', destinationName: 'D Pier', expectedArrival: at(arrival),
    observedAt: at(observed), expiresAt: at(600), ...overrides
});
// The donor is a future origin departure; it teaches A→B timing without being
// misrepresented as a boat already under way. The subject is due at B in 2 min.
const firstSnapshot = () => [prediction('donor', 'A', 300), prediction('donor', 'B', 780),
    prediction('subject', 'B', 120), prediction('subject', 'C', 640)];

test('cold start learns pier-pair duration from boards and positions only the sailing journey', () => {
    const estimator = new RiverBoatEstimator();
    const boats = estimator.update(firstSnapshot(), network, now);
    assert.equal(boats.length, 1);
    assert.equal(boats[0].previousPierId, 'A'); assert.equal(boats[0].nextPierId, 'B');
    assert.equal(boats[0].basis, 'predictedTravelTime');
    assert.equal(boats[0].segmentStartedAt, at(-360)); // 75% through an 8-minute leg.
    assert.equal(boats[0].observedAt, at(0));
});

test('a second client shares learned history, but source age never renews on a cached read', () => {
    const estimator = new RiverBoatEstimator();
    estimator.update(firstSnapshot(), network, now);
    const boats = estimator.update([prediction('new-client-subject', 'B', 180, 30)], network, now + 30_000);
    assert.equal(boats.filter((boat) => boat.id.includes('new-client-subject')).length, 1);
    const held = estimator.update([], network, now + 60_000);
    assert.equal(held.length, 2);
    assert.equal(held.find((boat) => boat.id.includes(':subject:')).observedAt, at(0));
    assert.equal(estimator.update([], network, now + 91_000).length, 1);
    assert.equal(estimator.update([], network, now + 121_000).length, 0);
});

test('empty snapshots retain estimates through upstream cache expiry, but only until the fixed observation bound or arrival', () => {
    const estimator = new RiverBoatEstimator();
    const boats = estimator.update(firstSnapshot(), network, now);
    assert.deepEqual(estimator.update([], network, now + 30_000), boats);
    assert.deepEqual(estimator.update([], network, now + 91_000), []);
    const short = new RiverBoatEstimator();
    short.update(firstSnapshot().map((p) => p.vehicleId === 'subject' ? { ...p, expiresAt: at(20) } : p), network, now);
    assert.equal(short.current(now + 20_000).length, 1);
    assert.deepEqual(short.current(now + 91_000), []);
    const arriving = new RiverBoatEstimator();
    arriving.update([prediction('donor', 'A', 300), prediction('donor', 'B', 780), prediction('subject', 'B', 20)], network, now);
    assert.deepEqual(arriving.current(now + 20_000), []);
});

test('same-source expiry across successive cached snapshots preserves the witnessed transition', () => {
    const estimator = new RiverBoatEstimator();
    assert.equal(estimator.update([prediction('one', 'A', 10), prediction('one', 'C', 120)], network, now).length, 0);
    const boats = estimator.update([prediction('one', 'C', 120)], network, now + 15_000);
    assert.equal(boats.length, 1); assert.equal(boats[0].basis, 'observedTransition');
    assert.equal(boats[0].previousPierId, 'A'); assert.equal(boats[0].segmentStartedAt, at(10));
    assert.equal(boats[0].observedAt, at(0));
});

test('ambiguous branch predecessors, conflicting ETAs, missing identity and future starts are excluded', () => {
    const ambiguous = { routes: [...network.routes, { lineId: 'rb1', direction: 'outbound', stopIds: ['X', 'B', 'C', 'D'] }] };
    assert.equal(new RiverBoatEstimator().update(firstSnapshot(), ambiguous, now).length, 0);
    assert.equal(new RiverBoatEstimator().update(firstSnapshot().map((p) => p.vehicleId === 'subject'
        ? { ...p, vehicleId: null } : p), network, now).length, 0);
    const future = firstSnapshot().filter((p) => p.vehicleId === 'donor');
    future.push(prediction('later', 'B', 1000));
    assert.equal(new RiverBoatEstimator().update(future, network, now).length, 0);
    assert.equal(new RiverBoatEstimator().update([...firstSnapshot(), prediction('subject', 'A', 120)], network, now).length, 0);
});

test('wrong direction, backwards calling order and unknown destination cannot create estimates', () => {
    for (const overrides of [{ direction: 'inbound' }, { destinationId: 'elsewhere' }]) {
        const rows = firstSnapshot().map((p) => p.vehicleId === 'subject' ? { ...p, ...overrides } : p);
        assert.equal(new RiverBoatEstimator().update(rows, network, now).length, 0);
    }
    assert.equal(new RiverBoatEstimator().update([...firstSnapshot(), prediction('subject', 'A', 150)], network, now).length, 0);
});

test('model medians resist a single outlier and repeated requests do not multiply a journey’s vote', () => {
    const estimator = new RiverBoatEstimator();
    const rows = [prediction('one', 'A', 300), prediction('one', 'B', 600),
        prediction('two', 'A', 300), prediction('two', 'B', 620),
        prediction('outlier', 'A', 300), prediction('outlier', 'B', 1800)];
    for (let i = 0; i < 20; i++) estimator.update(rows, network, now);
    const boats = estimator.update([prediction('subject', 'B', 120)], network, now);
    assert.equal(boats.length, 1);
    assert.equal(boats[0].segmentStartedAt, at(-200)); // Median 320 sec, not outlier 1500.
});

test('network changes and old timing observations cannot seed a new estimate', () => {
    const estimator = new RiverBoatEstimator();
    estimator.update(firstSnapshot(), network, now);
    const changed = { routes: [{ ...network.routes[0], stopIds: ['X', 'B', 'C', 'D'] }] };
    assert.deepEqual(estimator.update([prediction('new', 'B', 120)], changed, now), []);
    const old = new RiverBoatEstimator(); old.update(firstSnapshot(), network, now);
    assert.deepEqual(old.update([prediction('new', 'B', 86460, 86401, { expiresAt: at(87000) })], network, now + 86401_000), []);
});

test('older snapshots cannot rewind a retained boat or extend its lifetime', () => {
    const estimator = new RiverBoatEstimator();
    estimator.update(firstSnapshot(), network, now);
    const fresh = estimator.update([prediction('subject', 'B', 150, 30)], network, now + 30_000);
    assert.deepEqual(estimator.update([prediction('subject', 'B', 120, 0)], network, now + 40_000), fresh);
});

test('a changed or ambiguous journey identity cannot leave duplicate markers behind', () => {
    const estimator = new RiverBoatEstimator(); estimator.update(firstSnapshot(), network, now);
    const changed = prediction('subject', 'A', 300, 30, { tripId: 'next-trip' });
    assert.deepEqual(estimator.update([changed], network, now + 30_000), []);
    const ambiguous = new RiverBoatEstimator(); ambiguous.update(firstSnapshot(), network, now);
    assert.deepEqual(ambiguous.update([prediction('subject', 'B', 120, 30),
        prediction('subject', 'B', 120, 30, { tripId: 'other-trip' })], network, now + 30_000), []);
});

test('millisecond timestamp skew between piers in the same batch does not lose a transition', () => {
    const estimator = new RiverBoatEstimator();
    estimator.update([prediction('one', 'A', 10, 0.3), prediction('one', 'C', 120, 0.1)], network, now);
    const boats = estimator.update([prediction('one', 'C', 120, 0.1)], network, now + 15_000);
    assert.equal(boats.length, 1); assert.equal(boats[0].segmentStartedAt, at(10));
    assert.equal(boats[0].observedAt, at(0.1));
});

test('a late response for an old trip cannot evict the current trip', () => {
    const estimator = new RiverBoatEstimator();
    estimator.update(firstSnapshot(), network, now);
    const fresh = estimator.update([prediction('subject', 'B', 150, 30)], network, now + 30_000);
    assert.deepEqual(estimator.update([prediction('subject', 'A', 200, 0,
        { tripId: 'old-trip' })], network, now + 40_000), fresh);
});

const returnNetwork = { routes: [...network.routes,
    { lineId: 'rb1', direction: 'inbound', stopIds: ['D', 'C', 'B', 'A'] }] };
const returnSnapshot = () => [prediction('return', 'D', 1800, 0, { direction: 'inbound', destinationId: 'A' }),
    prediction('return', 'B', 2400, 0, { direction: 'inbound', destinationId: 'A' }),
    prediction('return', 'A', 2640, 0, { direction: 'inbound', destinationId: 'A' }),
    prediction('approaching', 'B', 120)];

test('return journey timing fills a cold-start gap without displaying future departures', () => {
    const boats = new RiverBoatEstimator().update(returnSnapshot(), returnNetwork, now);
    assert.equal(boats.length, 1);
    assert.equal(boats[0].basis, 'reverseTravelTime');
    assert.equal(boats[0].previousPierId, 'A'); assert.equal(boats[0].nextPierId, 'B');
    assert.equal(boats[0].segmentStartedAt, at(-120));
    assert.equal(boats[0].expiresAt, at(90));
});

test('same-direction timing takes precedence over the return journey fallback', () => {
    const boats = new RiverBoatEstimator().update([...returnSnapshot(),
        prediction('donor', 'A', 300), prediction('donor', 'B', 780)], returnNetwork, now);
    const boat = boats.find(b => b.id.includes('approaching'));
    assert.equal(boat.basis, 'predictedTravelTime');
    assert.equal(boat.segmentStartedAt, at(-360));
});

test('return timing cannot bypass branch ambiguity, future start, source age or service boundaries', () => {
    const ambiguous = { routes: [...returnNetwork.routes,
        { lineId: 'rb1', direction: 'outbound', stopIds: ['X', 'B', 'C', 'D'] }] };
    assert.deepEqual(new RiverBoatEstimator().update(returnSnapshot(), ambiguous, now), []);
    const future = returnSnapshot().map(p => p.vehicleId === 'approaching' ? { ...p, expectedArrival: at(300) } : p);
    assert.deepEqual(new RiverBoatEstimator().update(future, returnNetwork, now), []);
    const stale = returnSnapshot().map(p => p.vehicleId === 'return' ? { ...p, observedAt: at(-91) } : p);
    assert.deepEqual(new RiverBoatEstimator().update(stale, returnNetwork, now), []);
    const otherLine = returnSnapshot().map(p => p.vehicleId === 'return' ? { ...p, lineId: 'rb6' } : p);
    const withOtherLine = { routes: [...returnNetwork.routes, { ...returnNetwork.routes[1], lineId: 'rb6' }] };
    assert.deepEqual(new RiverBoatEstimator().update(otherLine, withOtherLine, now), []);
});
