import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

import { normaliseOperatorStatuses } from '../lib/national-rail.js';
import { ResourceCache } from '../lib/resource-cache.js';
import {
    createThameslinkDataSource, normaliseThameslinkDepartures, stationDisplayName, THAMESLINK_STOP_IDS
} from '../lib/thameslink.js';

const fixture = JSON.parse(await readFile(new URL('./fixtures/thameslink/west-hampstead-arrival-departures.json', import.meta.url)));
const NOW = Date.parse('2026-09-27T22:22:43Z');

test('normalises National Rail departures with direction, status and cause', () => {
    const rows = normaliseThameslinkDepartures(fixture, '910GWHMPSTM', NOW);
    assert.deepEqual(rows.map((row) => [row.destinationName, row.direction, row.status]), [
        ['Luton', 'Northbound', 'cancelled'],
        ['Bedford', 'Northbound', 'onTime'],
        ['Luton', 'Northbound', 'onTime'],
        ['Bedford', 'Northbound', 'onTime'],
        ['Brighton', 'Southbound', 'onTime']
    ]);
    const cancelled = rows[0];
    assert.equal(cancelled.cause, 'This service has been cancelled because of a fault on this train');
    assert.equal(cancelled.expectedDeparture, cancelled.scheduledDeparture);
    assert.equal(cancelled.platformName, 'Platform 2');
    assert.equal(cancelled.stationName, 'West Hampstead Thameslink');
    assert.equal(cancelled.lineId, 'thameslink');
    assert.equal(rows[1].timeToStation, 377);
    assert.equal(new Set(rows.map((row) => row.id)).size, rows.length);
});

test('drops departed, terminating and arrival-only rows', () => {
    const base = fixture[0];
    const rows = normaliseThameslinkDepartures([
        { ...base, scheduledTimeOfDeparture: '2026-09-27T22:10:00Z', estimatedTimeOfDeparture: '2026-09-27T22:10:00Z' },
        { ...base, destinationNaptanId: '910GWHMPSTM' },
        { ...base, scheduledTimeOfDeparture: null, estimatedTimeOfDeparture: null },
        { ...base, departureStatus: 'Delayed', estimatedTimeOfDeparture: '2026-09-27T22:34:00Z' }
    ], '910GWHMPSTM', NOW);
    assert.deepEqual(rows.map((row) => [row.status, row.expectedDeparture]), [
        ['delayed', '2026-09-27T22:34:00.000Z']
    ]);
});

test('names stations as the app does and knows the mapped Thameslink stops', () => {
    assert.equal(stationDisplayName('Sutton (London) Rail Station'), 'Sutton');
    assert.equal(stationDisplayName('Brent Cross West Station'), 'Brent Cross West');
    assert.ok(THAMESLINK_STOP_IDS.has('910GSTPXBOX'));
    assert.ok(THAMESLINK_STOP_IDS.has('910GFRNDNLT'));
    assert.ok(!THAMESLINK_STOP_IDS.has('910GBEDFDM'), 'off-map stations are not boards');
});

test('keeps other stops when one board fails and shares the station cache', async () => {
    const requests = [];
    const client = {
        fetchJSON: async (path) => {
            requests.push(path);
            if (path.includes('910GFRNDNLT')) throw new Error('upstream down');
            return fixture;
        }
    };
    const source = createThameslinkDataSource({ client, resourceCache: new ResourceCache(), clock: () => NOW });
    const result = await source.departures(['910GWHMPSTM', '910GFRNDNLT']);
    assert.equal(result.data.length, 5);
    assert.deepEqual(result.meta.unavailableStopIds, ['910GFRNDNLT']);
    assert.equal(result.meta.stale, true);
    await source.departures(['910GWHMPSTM']);
    assert.equal(requests.filter((path) => path.includes('910GWHMPSTM')).length, 1);
    await assert.rejects(source.departures(['910GFRNDNLT']), /upstream down/);
});

test('reports other National Rail operators but never lines the app draws itself', () => {
    const statuses = normaliseOperatorStatuses([
        { id: 'thameslink', name: 'Thameslink', lineStatuses: [] },
        { id: 'southern', name: 'Southern', lineStatuses: [{ statusSeverity: 9, statusSeverityDescription: 'Minor Delays', reason: 'Signal failure' }] },
        { id: 'c2c', name: 'c2c', lineStatuses: [{ id: 1, statusSeverity: 10, statusSeverityDescription: 'Good Service' }] }
    ]);
    assert.deepEqual(statuses.map((line) => line.id), ['c2c', 'southern']);
    assert.deepEqual(statuses[1].lineStatuses[0], {
        id: 0, statusSeverity: 9, statusSeverityDescription: 'Minor Delays', reason: 'Signal failure'
    });
});

test('Blackfriars direction depends on the departure station', () => {
    const base = { ...fixture[0], destinationNaptanId: '910GBLFR',
        destinationName: 'London Blackfriars Rail Station' };
    for (const stop of ['910GBCKNHMH', '910GBELNGHM', '910GCATFORD']) {
        assert.equal(normaliseThameslinkDepartures([base], stop, NOW)[0].direction, 'Northbound');
    }
    assert.equal(normaliseThameslinkDepartures([base], '910GWHMPSTM', NOW)[0].direction, 'Southbound');
    assert.equal(normaliseThameslinkDepartures([base], 'unknown', NOW)[0].direction, null);
    const sevenoaks = { ...base, destinationNaptanId: '910GSVNOAKS' };
    assert.equal(normaliseThameslinkDepartures([sevenoaks], '910GBCKNHMH', NOW)[0].direction, 'Southbound');
});
