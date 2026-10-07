import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { ResourceCache } from '../lib/resource-cache.js';
import { createNationalRailDepartureSource, nationalRailPredictions, projectNationalRailBoard,
    railClockDate, NATIONAL_RAIL_CODES_BY_STATION, nationalRailCondition } from '../lib/push/national-rail-departures.js';
import { nationalRailDirection, NATIONAL_RAIL_DIRECTION_DATA } from '../lib/push/national-rail-direction.js';

const NOW = Date.parse('2026-10-06T09:00:00Z'); // 10:00 railway time.
const row = (overrides = {}) => ({ serviceID: 'train-1', operator: 'Southeastern', operatorCode: 'SE',
    serviceType: 'train', platform: '2', departure_time: { scheduled: '10:05', estimated: 'On time' },
    destination: [{ crs: 'VIC', locationName: 'London Victoria' }], ...overrides });
const board = (departures, overrides = {}) => ({ departures, dataStatus: 'live',
    lastSuccessfulUpdate: new Date(NOW).toISOString(), ...overrides });

test('server and app use exactly the same station codes including rail-only stations', () => {
    const app = JSON.parse(readFileSync(new URL('../../../ios/TubeTrackCore/Sources/TubeTrackCore/Resources/NationalRailStations.json', import.meta.url)));
    assert.deepEqual(NATIONAL_RAIL_CODES_BY_STATION, app);
    assert.deepEqual(app['nr:AYP'], ['AYP']);
});

test('app and server share the exact station coordinate data', () => {
    const app = JSON.parse(readFileSync(new URL('../../../ios/TubeTrackCore/Sources/TubeTrackCore/Resources/NationalRailDirections.json', import.meta.url)));
    assert.deepEqual(NATIONAL_RAIL_DIRECTION_DATA, app);
});

const directionCases = [
    ['KTH', ['VIC'], 'northbound'], ['KTH', ['ORP'], 'southbound'],
    ['LAD', ['CHX'], 'northbound'], ['LAD', ['HYS'], 'southbound'],
    ['MZH', ['CST'], 'northbound'], ['MZH', ['DFD'], 'eastbound'],
    ['DFD', ['MZH'], 'westbound'],
    ['GRP', ['CHX'], 'northbound'], ['GRP', ['SEV'], 'southbound'],
    ['GRP', ['BMN'], 'southbound'],
    ['SAC', ['BTN'], 'southbound'], ['ECR', ['BDM'], 'northbound'],
    [' kth ', [' vic '], 'northbound'],
    ['KTH', ['VIC', 'CHX'], 'northbound'],
    ['KTH', ['VIC', 'ORP'], null], ['KTH', ['VIC', 'XXX'], null],
    ['KTH', ['VIC', ''], null], ['XXX', ['VIC'], null],
    ['KTH', [], null], ['KTH', ['KTH'], null]
];
test('compass directions match destination bearings including diagonal London routes', () => {
    for (const [station, destinations, expected] of directionCases) {
        assert.equal(nationalRailDirection({ station, destinations }), expected, `${station} to ${destinations}`);
    }
    const coordinates = NATIONAL_RAIL_DIRECTION_DATA.coordinatesByStation;
    assert.ok(Object.keys(coordinates).length >= 2600);
    for (const crs of Object.values(NATIONAL_RAIL_CODES_BY_STATION).flat()) {
        assert.ok(coordinates[crs], `Missing coordinates for ${crs}`);
    }
});

test('destination directions scope projections and disruptions without service details', () => {
    const input = board([
        row({ serviceID: 'south', operatorCode: 'TL', operator: 'Thameslink', destination: { crs: 'BTN' } }),
        row({ serviceID: 'north', isCancelled: true,
            operatorCode: 'TL', operator: 'Thameslink', destination: { crs: 'BDM' } })]);
    const arrivals = nationalRailPredictions(input, 'SAC', NOW, { includeThameslink: true });
    assert.deepEqual(arrivals.map((item) => item.direction), ['southbound', 'northbound']);
    assert.deepEqual(projectNationalRailBoard({ arrivals, lineId: 'national-rail:TL', direction: 'southbound' })
        .map((item) => item.id), ['national-rail:SAC:south']);
    assert.deepEqual(nationalRailCondition(arrivals, 'national-rail:TL', 'southbound'), { rank: 4, headline: 'Departures on time' });
    const dividing = nationalRailPredictions(board([row({ destination: [{ crs: 'VIC' }, {}] })]), 'KTH', NOW);
    assert.equal(dividing[0].direction, null);
});

test('live-feed object destinations produce compass boards using only a cached station request', async () => {
    for (const [station, north, south] of [['KTH', 'VIC', 'ORP'], ['LAD', 'CHX', 'HYS']]) {
        const calls = [];
        const source = createNationalRailDepartureSource({ clock: () => NOW, resourceCache: new ResourceCache({ clock: () => NOW }),
            fetchImpl: async (url) => {
                calls.push(url.pathname);
                assert.equal(url.pathname, `/train-track/api/v2/departures/from/${station}`);
                return { ok: true, json: async () => board([
                    row({ serviceID: 'staff_202610068087168_north', destination: { crs: north } }),
                    row({ serviceID: 'staff_202610068087168_south', destination: { crs: south } })]) };
            } });
        const result = await source.departures(station);
        assert.deepEqual(result.data.map((item) => item.direction), ['northbound', 'southbound']);
        assert.equal(result.meta.stale, false);
        await source.departures(station);
        assert.equal(calls.length, 1);
    }
});

test('railway clocks agree across midnight, DST folds and the spring gap', () => {
    for (const [clock, reference, expected] of [
        ['00:17', '2026-10-05T22:50:00Z', '2026-10-05T23:17:00Z'],
        ['23:55', '2026-10-05T23:05:00Z', '2026-10-05T22:55:00Z'],
        ['01:30', '2026-10-25T00:20:00Z', '2026-10-25T00:30:00Z'],
        ['01:30', '2026-10-25T01:20:00Z', '2026-10-25T01:30:00Z']
    ]) assert.equal(railClockDate(clock, Date.parse(reference)), Date.parse(expected));
    assert.equal(railClockDate('01:30', Date.parse('2026-03-29T00:20:00Z')), null);
    assert.equal(railClockDate('Delayed', NOW), null);
});

test('operator projection preserves cancellations, unconfirmed delays and hidden platforms', () => {
    const rows = nationalRailPredictions(board([
        row(), row(), row({ serviceID: 'late', departure_time: { scheduled: '09:50', estimated: 'Delayed' } }),
        row({ serviceID: 'cancelled', isCancelled: true, platformIsHidden: true }),
        row({ serviceID: 'southern', operatorCode: 'SN', operator: 'Southern' }),
        row({ serviceID: 'arrived', destination: [{ crs: 'BKJ', locationName: 'Beckenham Junction' }] }),
        row({ serviceID: 'gone', departure_time: { scheduled: '09:55', actual: '09:59' } }),
        row({ serviceID: 'bus', serviceType: 'bus' })]), 'BKJ', NOW);
    const projected = projectNationalRailBoard({ arrivals: rows, lineId: 'national-rail:SE' });
    assert.deepEqual(projected.map((item) => item.id), ['national-rail:BKJ:late', 'national-rail:BKJ:cancelled', 'national-rail:BKJ:train-1']);
    assert.equal(projected[0].status, 'delayed');
    assert.equal(projected[0].hasExpectedTime, false);
    assert.equal(projected[1].status, 'cancelled');
    assert.equal(projected[1].platform, 'Platform to be');
    assert.equal(projected[2].expectedAtEpoch, (NOW + 300_000) / 1000);
});

test('Thameslink is included only for rail-only station boards; TfL duplicates stay excluded', () => {
    const input = board([row({ operatorCode: 'TL', operator: 'Thameslink' }), row({ operatorCode: 'LO' }), row({ operatorCode: 'XR' })]);
    assert.equal(nationalRailPredictions(input, 'BKJ', NOW).length, 0);
    assert.equal(nationalRailPredictions(input, 'BKJ', NOW, { includeThameslink: true }).length, 1);
});

test('source caches station lookups and retains the provider timestamp', async () => {
    let calls = 0;
    const source = createNationalRailDepartureSource({ clock: () => NOW, resourceCache: new ResourceCache({ clock: () => NOW }),
        fetchImpl: async (url) => { calls++; assert.equal(url.pathname, '/train-track/api/v2/departures/from/BKJ');
            return { ok: true, json: async () => board([row()]) }; } });
    const result = await source.departures('BKJ');
    await source.departures('BKJ');
    assert.equal(calls, 1);
    assert.equal(Date.parse(result.meta.updatedAt), NOW);
    assert.equal(result.data[0].lineId, 'national-rail:SE');
});

test('partial, stale, old, malformed and failed source boards cannot refresh an activity', async () => {
    for (const input of [board([], { dataStatus: 'partial' }), board([], { dataStatus: 'stale' }),
        board([], { lastSuccessfulUpdate: new Date(NOW - 91_000).toISOString() }), board(null), board([], { lastSuccessfulUpdate: null })]) {
        const source = createNationalRailDepartureSource({ clock: () => NOW, resourceCache: new ResourceCache(),
            fetchImpl: async () => ({ ok: true, json: async () => input }) });
        await assert.rejects(source.departures('BKJ'));
    }
    const source = createNationalRailDepartureSource({ resourceCache: new ResourceCache(), fetchImpl: async () => { throw new Error('offline'); } });
    await assert.rejects(source.departures('BKJ'));
});
