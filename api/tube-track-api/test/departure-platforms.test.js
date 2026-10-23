import assert from 'node:assert/strict';
import test from 'node:test';
import { coalesceDeparturePlatforms } from '../lib/departure-platforms.js';
import { projectBoard } from '../lib/push/departure-projection.js';

const row = (platform, overrides = {}) => ({ id: 'shared-dlr-id', vehicleId: null,
    stopId: '940GZZDLCAN', lineId: 'dlr', destinationName: 'Stratford DLR Station',
    direction: 'inbound', platformName: `Platform ${platform}`,
    expectedArrival: '2026-10-23T12:00:00Z', ...overrides });

for (const [a, b] of [[1, 2], [3, 4], [5, 6]]) {
    test(`merges known faces ${a}/${b}, including numeric platform labels`, () => {
        const rows = [row(b), row(a, { platformName: String(a) })];
        const merged = coalesceDeparturePlatforms(rows);
        assert.equal(merged.length, 1);
        assert.equal(merged[0].platformName, `Platforms ${a} & ${b}`);
        assert.equal(rows[0].platformName, `Platform ${b}`);
        assert.deepEqual(coalesceDeparturePlatforms(merged), merged);
    });
}

test('allows two seconds of prediction skew but keeps later trains', () => {
    assert.equal(coalesceDeparturePlatforms([row(3), row(4, {
        expectedArrival: '2026-10-23T12:00:02Z' })]).length, 1);
    assert.equal(coalesceDeparturePlatforms([row(3), row(4, {
        expectedArrival: '2026-10-23T12:00:03Z' })]).length, 2);
});

test('does not merge distinct services, tracks, stations, or missing times', () => {
    for (const changes of [{ id: 'different' }, { vehicleId: 'different' },
        { destinationName: 'Bank' }, { destinationStopId: 'different' },
        { direction: 'outbound' }, { platformName: 'Platform 3' },
        { platformName: 'Platform 5' }, { expectedArrival: null }]) {
        assert.equal(coalesceDeparturePlatforms([row(3), row(4, changes)]).length, 2);
    }
    for (const changes of [{ stopId: '940GZZDLMUD' }, { lineId: 'jubilee' }]) {
        assert.equal(coalesceDeparturePlatforms([row(3, changes), row(4, changes)]).length, 2);
    }
});

test('tracked board merges before limiting so duplicates cannot hide later trains', () => {
    const arrivals = [0, 5, 10].flatMap(minutes => [3, 4].map(platform => row(platform, {
        expectedArrival: new Date(Date.parse('2026-10-23T12:00:00Z') + minutes * 60_000).toISOString()
    })));
    const result = projectBoard({ arrivals, lineId: 'dlr', stopIds: ['940GZZDLCAN'], limit: 3 });
    assert.equal(result.length, 3);
    assert.deepEqual(result.map(departure => departure.platform), Array(3).fill('Platforms 3&4'));
    assert.equal(result[2].expectedAtEpoch - result[0].expectedAtEpoch, 600);
});

test('Tube alternative platforms retain one identified train without promising either track', () => {
    const first = row(3, { lineId: 'piccadilly', stopId: '940GZZLUACT', vehicleId: '315',
        platformName: 'Eastbound - Platform 3', destinationName: 'Cockfosters' });
    const second = { ...first, id: 'other-platform-id', platformName: 'Eastbound - Platform 4' };
    assert.deepEqual(coalesceDeparturePlatforms([first, second]), [
        { ...first, platformName: 'Eastbound - Check platform' }
    ]);
    const projected = projectBoard({ arrivals: [first, second], lineId: 'piccadilly', direction: 'eastbound' });
    assert.equal(projected.length, 1);
    assert.equal(projected[0].platform, 'Check platform');
    for (const vehicleId of [null, '', '000']) {
        assert.equal(coalesceDeparturePlatforms([{ ...first, vehicleId }, { ...second, vehicleId }]).length, 2);
    }
    assert.equal(coalesceDeparturePlatforms([first, { ...second, vehicleId: '316' }]).length, 2);
    assert.equal(coalesceDeparturePlatforms([first, { ...second, stopId: 'other-station' }]).length, 2);
    assert.equal(coalesceDeparturePlatforms([first, { ...second, destinationName: 'Heathrow' }]).length, 2);
});
