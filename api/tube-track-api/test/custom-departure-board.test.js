import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { departureDirection, callsAtSelected, createCustomDepartureSource, orderedUniqueDepartures, DEPARTURE_STOPS } from '../lib/custom-departure-board.js';
import { createNationalRailDepartureSource } from '../lib/push/national-rail-departures.js';
import { ResourceCache } from '../lib/resource-cache.js';

const now = Date.parse('2026-10-07T09:00:00Z');
const iso = delta => new Date(now + delta).toISOString();
const prediction = (id, destinationStopId, seconds = 120) => ({ id, vehicleId: id, stopId: 'limehouse',
    lineId: 'dlr', destinationStopId, destinationName: destinationStopId, expectedArrival: iso(seconds * 1000) });
const routes = [
    { lineId: 'dlr', stopIds: ['lewisham', 'limehouse', 'shadwell', 'bank'] },
    { lineId: 'dlr', stopIds: ['woolwich', 'limehouse', 'shadwell', 'tower'] }
];

test('terminal and intermediate filters respect branches and travel order', () => {
    assert.equal(callsAtSelected(prediction('1', 'bank'), ['limehouse'], ['bank'], routes), true);
    assert.equal(callsAtSelected(prediction('2', 'tower'), ['limehouse'], ['bank'], routes), false);
    assert.equal(callsAtSelected(prediction('3', 'bank'), ['limehouse'], ['shadwell'], routes), true);
    assert.equal(callsAtSelected(prediction('4', 'bank'), ['limehouse'], ['lewisham'], routes), false);
    assert.equal(callsAtSelected(prediction('5', 'unknown'), ['limehouse'], ['bank'], routes), null);
    assert.equal(callsAtSelected(prediction('6', 'tower'), ['limehouse'], ['bank', 'tower'], routes), true);
});

test('express and ambiguous stopping patterns are never assumed to call', () => {
    const patterns = [{ lineId: 'dlr', stopIds: ['limehouse', 'shadwell', 'bank'] },
        { lineId: 'dlr', stopIds: ['limehouse', 'bank'] }];
    assert.equal(callsAtSelected(prediction('1', 'bank'), ['limehouse'], ['shadwell'], patterns), null);
});

test('app and server share endpoints including Kent House, hub aliases and CRS codes', () => {
    const app = JSON.parse(readFileSync(new URL('../../../ios/TubeTrackCore/Sources/TubeTrackCore/Resources/DepartureStops.json', import.meta.url)));
    assert.deepEqual(app, DEPARTURE_STOPS);
    assert.deepEqual(app.find(s => s.id === 'nr:KTH').railCodes, ['KTH']);
    assert.ok(app.find(s => s.id === 'HUBBAN').stopIDs.includes('940GZZDLBNK'));
    assert.equal(new Set(app.map(s => s.id)).size, app.length);
});

test('National Rail filter confirms Bromley South without changing the Orpington terminus', async () => {
    const source = createNationalRailDepartureSource({ resourceCache: new ResourceCache({ clock: () => now }), clock: () => now,
        fetchImpl: async url => {
            assert.match(url.pathname, /departures\/from\/KTH\/to\/BMS$/);
            const base = { operator: 'Southeastern', operatorCode: 'SE',
                departure_time: { scheduled: '10:05', estimated: 'On time' },
                destination: { crs: 'ORP', locationName: 'Orpington' }, filterCRS: 'BMS' };
            return { ok: true, json: async () => ({ dataStatus: 'live', lastSuccessfulUpdate: iso(0), departures: [
                { ...base, serviceID: 'good' }, { ...base, serviceID: 'skips', filterLocationCancelled: true },
                { ...base, serviceID: 'unknown', filterCRS: null }
            ] }) };
        } });
    const result = await source.departures('KTH', { destinationCRS: 'BMS', includeAllOperators: true });
    assert.equal(result.data.length, 1);
    assert.equal(result.data[0].destinationName, 'Orpington');
});

function fixture(arrivals, overrides = {}) {
    const stops = ['limehouse', 'bank', 'shadwell', 'tower', 'lewisham'].map(id => ({
        id, name: id, stopIDs: [id.toUpperCase()], lineIDs: ['dlr'], railCodes: [], mode: 'rail'
    }));
    return createCustomDepartureSource({ stops, clock: () => now,
        cache: { read: () => ({ staleModes: [], snapshot: { arrivals, updatedAt: iso(0), modeUpdatedAt: { dlr: iso(0) } } }) },
        resourceCache: new ResourceCache({ clock: () => now }),
        client: { fetchJSON: async () => ({ orderedLineRoutes: routes.map(route => ({ naptanIds: route.stopIds.map(id => id.toUpperCase()) })) }) },
        river: { network: async () => ({ data: { piers: [] } }) }, ...overrides });
}

test('filters before limiting and combines selected destinations in departure order', async () => {
    const arrivals = Array.from({ length: 8 }, (_, i) => prediction(String(i), i < 6 ? 'tower' : 'bank', 60 + i * 60));
    const source = fixture(arrivals);
    const result = await source.board({ originID: 'limehouse', destinationIDs: ['bank'], lineIDs: [] });
    assert.deepEqual(result.arrivals.map(row => row.id), ['6', '7']);
    const both = await source.board({ originID: 'limehouse', destinationIDs: ['bank', 'tower'], lineIDs: [] });
    assert.equal(both.arrivals.length, 8);
});

test('unverified services are excluded with a visible count, stale sources fail', async () => {
    const result = await fixture([prediction('1', 'unknown')]).board({ originID: 'limehouse', destinationIDs: ['bank'], lineIDs: [] });
    assert.equal(result.unverifiedCount, 1);
    assert.equal(result.arrivals.length, 0);
    await assert.rejects(fixture([], { cache: { read: () => null } }).board({ originID: 'limehouse', destinationIDs: [], lineIDs: [] }));
});

test('sorting removes duplicates and departed rows without losing unconfirmed delays', () => {
    const future = prediction('1', 'bank');
    const late = { ...prediction('late', 'bank', -600), expectedArrival: null, scheduledDeparture: iso(-600000), status: 'delayed' };
    const result = orderedUniqueDepartures([future, future, prediction('gone', 'bank', -30), late], now);
    assert.deepEqual(result.map(row => row.id), ['late', '1']);
});

test('board validation bounds selection size and rejects unknown endpoints', async () => {
    const source = fixture([]);
    await assert.rejects(source.validate({ originID: 'limehouse', destinationIDs: Array(9).fill('bank'), lineIDs: [] }));
    await assert.rejects(source.validate({ originID: 'missing', destinationIDs: [], lineIDs: [] }));
    await assert.rejects(source.validate({ originID: 'limehouse', destinationIDs: ['limehouse'], lineIDs: [] }));
});

test('river boards use downstream calling piers and exclude boats terminating here', async () => {
    const network = { piers: ['west', 'middle', 'east'].map(id => ({ id, name: id, lineIds: ['rb1'] })),
        routes: [{ lineId: 'rb1', direction: 'outbound', stopIds: ['west', 'middle', 'east'] }] };
    const source = fixture([], { river: {
        network: async () => ({ data: network }),
        arrivals: async () => ({ meta: { updatedAt: iso(0), stale: false }, data: [
            { id: 'boat', pierId: 'west', lineId: 'rb1', destinationId: 'east', destinationName: 'East',
                direction: 'outbound', expectedArrival: iso(120000) },
            { id: 'terminating', pierId: 'west', lineId: 'rb1', destinationId: 'east',
                terminatesHere: true, expectedArrival: iso(60000) }
        ] })
    } });
    const board = await source.board({ originID: 'west', destinationIDs: ['middle'], lineIDs: [] });
    assert.deepEqual(board.arrivals.map(row => row.id), ['boat']);
});

test('multi-destination rail boards combine operators without repeating a train', async () => {
    const stops = [
        { id: 'origin', name: 'Origin', stopIDs: ['origin'], lineIDs: [], railCodes: ['AAA'], mode: 'rail' },
        ...['BBB', 'CCC'].map(id => ({ id, name: id, stopIDs: [id], lineIDs: [], railCodes: [id], mode: 'rail' }))
    ];
    const railRow = (id, operator, time) => ({ id, lineId: `national-rail:${operator}`, operatorName: operator,
        stopId: 'AAA', destinationStopId: 'DDD', destinationName: 'Terminus', expectedArrival: iso(time) });
    const board = await fixture([], { stops, nationalRail: {
        departures: async (crs, options) => ({ meta: { updatedAt: iso(0), stale: false }, data: options.destinationCRS === 'BBB'
            ? [railRow('shared', 'SE', 60000), railRow('other', 'SN', 180000)] : [railRow('shared', 'SE', 60000)] })
    } }).board({ originID: 'origin', destinationIDs: ['BBB', 'CCC'], lineIDs: [] });
    assert.deepEqual(board.arrivals.map(row => row.id), ['shared', 'other']);
});


test('DLR tracking uses the same compass direction as the visible board', () => {
    const origin = DEPARTURE_STOPS.find(stop => stop.name === 'Island Gardens');
    assert.equal(departureDirection({ lineId: 'dlr', direction: 'inbound', platformName: '2',
        destinationStopId: '940GZZDLBNK', destinationName: 'Bank' }, origin, DEPARTURE_STOPS), 'Northbound');
    assert.equal(departureDirection({ lineId: 'dlr', direction: 'outbound', platformName: '1',
        destinationName: 'Lewisham DLR Station' }, origin, DEPARTURE_STOPS), 'Southbound');
});

test('direction requests filter the board used by background tracking', async () => {
    const source = fixture([
        { ...prediction('north', 'bank'), direction: 'northbound', stopId: 'LIMEHOUSE' },
        { ...prediction('south', 'lewisham'), direction: 'southbound', stopId: 'LIMEHOUSE' }
    ]);
    const result = await source.board({ originID: 'limehouse', destinationIDs: [], lineIDs: ['dlr'], direction: 'Northbound' });
    assert.deepEqual(result.arrivals.map(row => row.id), ['north']);
    await assert.rejects(source.validate({ originID: 'limehouse', destinationIDs: [], lineIDs: [], direction: {} }), /Invalid/);
});

test('failed rail refresh retains a still-fresh source snapshot but expires at 90 seconds', async () => {
    let time = now, fail = false;
    const cache = new ResourceCache({ clock: () => time });
    const source = createNationalRailDepartureSource({ resourceCache: cache, clock: () => time,
        fetchImpl: async () => {
            if (fail) throw new Error('upstream timeout');
            return { ok: true, json: async () => ({ dataStatus: 'live', lastSuccessfulUpdate: iso(0), departures: [
                { serviceID: 'train', operator: 'Southeastern', operatorCode: 'SE',
                  departure_time: { scheduled: '10:05', estimated: 'On time' },
                  destination: { crs: 'CHX', locationName: 'London Charing Cross' } }
            ] }) };
        } });
    await source.departures('LEW');
    time += 31_000; fail = true;
    const recent = await source.departures('LEW');
    assert.equal(recent.data.length, 1);
    assert.equal(recent.meta.updatedAt, iso(0));
    time = now + 91_000;
    await assert.rejects(source.departures('LEW'), /stale/);
});
