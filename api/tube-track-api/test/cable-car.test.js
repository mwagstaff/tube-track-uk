import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import express from 'express';
import { cableCarNetwork, cableCarStatus, cableCarWorks, cableCarHours, createCableCarRoutes } from '../lib/cable-car.js';
import { ResourceCache } from '../lib/resource-cache.js';

const fixture = name => JSON.parse(readFileSync(new URL(`./fixtures/cable-car/${name}.json`, import.meta.url)));
const hours = JSON.parse(readFileSync(new URL('../data/cable-car-hours.json', import.meta.url)));

test('recorded catalogue uses terminal IDs rather than nearby interchange hub IDs', () => {
    const network = cableCarNetwork(fixture('stops'), fixture('outbound'));
    assert.equal(network.id, 'london-cable-car');
    assert.deepEqual(network.terminals.map(t => t.id), ['940GZZALGWP', '940GZZALRDK']);
    assert.equal(network.coordinates.length, 2);
    assert.equal(network.coordinates[0].latitude, network.terminals[0].latitude);
    assert.equal(network.coordinates[1].longitude, network.terminals[1].longitude);
    assert.throws(() => cableCarNetwork([], fixture('outbound')));
});

test('recorded timetable first/last journeys agree with reviewed public hours, not old StopPoint hours', () => {
    assert.deepEqual(cableCarHours(fixture('timetable'), hours).weekly, hours.weekly);
    const changed = fixture('timetable');
    changed.timetable.routes[0].schedules[0].firstJourney.hour = '7';
    assert.equal(cableCarHours(changed, hours).isVerified, false);
    assert.throws(() => cableCarHours({}, hours));
    assert.equal(readFileSync(new URL('../../../ios/TubeTrackUK/Resources/CableCarHours.json', import.meta.url), 'utf8'),
        readFileSync(new URL('../data/cable-car-hours.json', import.meta.url), 'utf8'));
});

test('empty status is unknown, unknown severity survives, malformed upstream does not become good', () => {
    assert.equal(cableCarStatus(fixture('status')).entries[0].statusSeverity, 10);
    const raw = [{ id: 'london-cable-car', lineStatuses: [] }];
    assert.deepEqual(cableCarStatus(raw).entries, []);
    raw[0].lineStatuses = [{ statusSeverity: 999, statusSeverityDescription: 'New TfL status', reason: 'Details' }, {}];
    assert.equal(cableCarStatus(raw).entries[0].statusSeverity, 999);
    assert.equal(cableCarStatus(raw).entries[1].statusSeverity, -1);
    assert.throws(() => cableCarStatus([]));
    assert.throws(() => cableCarStatus({ message: 'Unavailable' }));
});

test('future works require bounded validity, deduplicate, preserve partial day and disclose undated notices', () => {
    const period = { fromDate: '2026-10-01T11:00:00Z', toDate: '2026-10-01T14:00:00Z' };
    const raw = [{ id: 'london-cable-car', lineStatuses: [
        { statusSeverity: 4, statusSeverityDescription: 'Planned Closure', reason: 'Maintenance', validityPeriods: [period, period] },
        { statusSeverity: 999, statusSeverityDescription: 'Information' },
        { statusSeverity: 10, statusSeverityDescription: 'Good Service' }
    ] }];
    const result = cableCarWorks(raw, '2026-10-01', '2026-10-02');
    assert.equal(result.works.length, 1);
    assert.equal(result.works[0].start, '2026-10-01T11:00:00.000Z');
    assert.equal(result.undatedCount, 1);
    assert.deepEqual(cableCarWorks(fixture('future'), '2026-09-25', '2026-10-25').works, []);
});

test('isolated endpoints retain stale timestamps, coalesce requests and validate dates before upstream access', async () => {
    let now = Date.parse('2026-09-25T12:00:00Z'), failed = false;
    const calls = [];
    const client = { fetchJSON: async path => {
        calls.push(path);
        if (failed) throw new Error('TfL unavailable');
        if (path.includes('/StopPoints')) return fixture('stops');
        if (path.includes('/Route/')) return fixture('outbound');
        if (path.includes('/Timetable/')) return fixture('timetable');
        return fixture('status');
    } };
    const app = express();
    app.use('/cable', createCableCarRoutes({ client, resourceCache: new ResourceCache({ clock: () => now }), hoursLoader: async () => hours }));
    const server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
    const base = `http://127.0.0.1:${server.address().port}/cable`;
    try {
        const responses = await Promise.all([fetch(`${base}/status`), fetch(`${base}/status`)]);
        assert.equal(responses[0].status, 200);
        assert.equal(calls.length, 1);
        const first = await responses[0].json();
        assert.equal((await fetch(`${base}/hours`)).status, 200);
        assert.equal((await fetch(`${base}/network`)).status, 200);
        assert.equal((await fetch(`${base}/planned-works?from=2026-09-25&to=2026-10-25`)).status, 200);
        for (const query of ['from=2026-02-30&to=2026-03-01', 'from=2026-10-01&to=2026-09-25', 'from=2026-09-25&to=2027-09-25']) {
            assert.equal((await fetch(`${base}/planned-works?${query}`)).status, 400);
        }
        now += 120_000; failed = true;
        const stale = await (await fetch(`${base}/status`)).json();
        assert.equal(stale.meta.stale, true);
        assert.equal(stale.meta.updatedAt, first.meta.updatedAt);
        assert.equal((await fetch(`${base}/planned-works?from=2026-10-01&to=2026-10-02`)).status, 503);
        assert.equal((await fetch(`${base}/network`)).status, 200);
    } finally { await new Promise(resolve => server.close(resolve)); }
});
