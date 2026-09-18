import assert from 'node:assert/strict';
import test from 'node:test';
import { JourneyPlanner, normalizeJourney, selectJourneys } from '../lib/journey-planner.js';
import { explicitInstant, parseJourneyTime, tflDateTime } from '../lib/journey-time.js';

const now = Date.parse('2026-09-16T12:00:00Z');
const stations = [
    { id: 'HUBA', name: 'Alpha', stopIds: ['940A', '910A'], aliases: ['Alpha Rail'], lineIds: ['victoria'] },
    { id: '940B', name: 'Beta', stopIds: ['940B'], aliases: [], lineIds: ['northern'] }
];
const allGood = ['victoria', 'northern'].map(id => ({ id, lineStatuses: [{ statusSeverity: 10 }] }));
const query = { from: '940A', to: '940B' };
const request = { requestedAt: now, timeMode: 'now', accessibility: 'none' };

function itinerary({ line = 'victoria', start = '13:05', end = '13:25', warnings = [], mode = 'tube' } = {}) {
    const time = (s) => `2026-09-16T${s}:00`;
    return {
        startDateTime: time(start), arrivalDateTime: time(end),
        legs: [{
            departureTime: time(start), arrivalTime: time(end),
            scheduledDepartureTime: time(start), scheduledArrivalTime: time(end),
            mode: { id: mode }, instruction: { summary: `${line} to Beta` },
            departurePoint: { naptanId: '940A', commonName: 'Alpha' },
            arrivalPoint: { naptanId: '940B', commonName: 'Beta' },
            routeOptions: [{ lineIdentifier: { id: line, name: line }, directions: ['Beta'] }],
            disruptions: warnings, plannedWorks: [], path: { stopPoints: [{ id: '940B', name: 'Beta' }] }
        }]
    };
}
const severe = { type: 'lineInfo', description: 'Victoria line: Severe delays due to an incident.' };
const accessibility = { type: 'stopInfo', description: 'Alpha: No step free access to another platform due to a lift closure.' };

function makePlanner(options = {}) {
    const calls = [];
    let time = now;
    let fail = false;
    const client = { fetchJSON: async (path, opts) => {
        calls.push({ path, ...opts });
        if (fail) throw new Error('Offline');
        if (path.startsWith('/Line/')) return allGood;
        if (path.startsWith('/StopPoint')) return { icsCode: path.endsWith('940A') ? '10001' : '10002' };
        return { recommendedMaxAgeMinutes: 2, journeys: [itinerary(), itinerary({ line: 'northern', end: '13:30' })], stopMessages: [] };
    } };
    return { planner: new JourneyPlanner({ client, clock: () => time, stations, ...options }), calls,
        advance: (ms) => { time += ms; }, fail: () => { fail = true; } };
}

test('London timestamps are independent of server timezone, including both DST transitions', () => {
    assert.equal(new Date(parseJourneyTime('2026-09-16T13:05:00', now)).toISOString(), '2026-09-16T12:05:00.000Z');
    assert.equal(new Date(parseJourneyTime('2026-01-16T13:05:00', now)).toISOString(), '2026-01-16T13:05:00.000Z');
    assert.equal(parseJourneyTime('2026-03-29T01:30:00', now), null);
    assert.equal(parseJourneyTime('2026-10-25T01:30:00', Date.parse('2026-10-25T00:20Z')), Date.parse('2026-10-25T00:30Z'));
    assert.equal(parseJourneyTime('2026-10-25T01:30:00', Date.parse('2026-10-25T01:20Z')), Date.parse('2026-10-25T01:30Z'));
    assert.deepEqual(tflDateTime(now), { date: '20260916', time: '1300' });
    assert.equal(explicitInstant('2026-02-30T12:00:00Z'), null);
    assert.equal(explicitInstant('2026-09-16T13:00:00'), null);
    assert.equal(explicitInstant('2026-09-16T13:00:00+01:00'), now);
});

test('ranks earliest arrival, reserves a less disrupted alternative, and deduplicates routes', () => {
    const raw = [
        itinerary({ warnings: [severe, accessibility] }),
        itinerary({ start: '13:07', end: '13:27', warnings: [severe] }),
        itinerary({ line: 'northern', end: '13:30', warnings: [accessibility] })
    ];
    const choices = selectJourneys(raw.map((j) => normalizeJourney(j, request)), request, now);
    assert.equal(choices.length, 2);
    assert.deepEqual(choices[0].labels, ['earliestArrival']);
    assert.deepEqual(choices[1].labels, ['lessDisrupted']);
    assert.equal(choices[1].disruptionScore, 0);
    assert.equal(choices[1].warnings[0].kind, 'accessibility');
    assert.equal(choices[0].waitingMinutes, 5);
    assert.equal(choices[0].legs[0].timing, 'estimated');
});

test('ranks arrival time including waits rather than in-vehicle duration', () => {
    const choices = selectJourneys([
        normalizeJourney(itinerary({ start: '13:05', end: '13:30' }), request),
        normalizeJourney(itinerary({ line: 'northern', start: '13:25', end: '13:40' }), request)
    ], request, now);
    assert.equal(choices[0].durationMinutes, 25);
});

test('arrive-by chooses later departures meeting deadline; expired departures are removed', () => {
    const journeys = [itinerary(), itinerary({ line: 'northern', start: '13:10', end: '13:30' }),
        itinerary({ line: 'central', start: '13:15', end: '13:40' })].map((j) => normalizeJourney(j, request));
    const choices = selectJourneys(journeys, { ...request, timeMode: 'arriveBy', requestedAt: now + 35 * 60_000 }, now);
    assert.deepEqual(choices[0].labels, ['latestDeparture']);
    assert.equal(choices[0].legs[0].lines[0].id, 'northern');
    assert.equal(choices.length, 2);
    assert.equal(selectJourneys(journeys, request, now + 16 * 60_000).length, 0);
});

test('rejects out-of-scope modes, invalid time sequences, and malformed upstream data', () => {
    assert.equal(normalizeJourney(itinerary({ mode: 'bus' }), request), null);
    assert.equal(normalizeJourney(itinerary({ mode: 'national-rail' }), request), null);
    assert.equal(normalizeJourney(itinerary({ start: '13:30', end: '13:10' }), request), null);
    assert.equal(normalizeJourney({ legs: [] }, request), null);
});

test('validates stations, same-hub endpoints, dates, preferences and repeated parameters before upstream calls', async () => {
    const { planner, calls } = makePlanner();
    for (const q of [
        { ...query, from: 'HUBMISSING' }, { ...query, to: '910A' },
        { ...query, from: ['940A', '940B'] }, { ...query, timeMode: 'anything' },
        { ...query, accessibility: '__proto__' }, { ...query, mode: 'bus' },
        { ...query, timeMode: 'departAt', time: '2026-09-16T13:00:00' },
        { ...query, timeMode: 'departAt', time: '2026-09-15T13:00:00Z' },
        { ...query, timeMode: 'arriveBy', time: '2027-09-16T13:00:00Z' }
    ]) await assert.rejects(planner.plan(q));
    assert.equal(calls.length, 0);
    assert.equal(planner.search('alpha')[0].id, 'HUBA');
});

test('resolves hub aliases to ICS, sets rail/accessibility options, and removes locations from metrics', async () => {
    const { planner, calls } = makePlanner();
    const response = await planner.plan({ ...query, accessibility: 'train' });
    const call = calls.find((c) => c.path.includes('JourneyResults'));
    assert.equal(call.path, '/Journey/JourneyResults/10001/to/10002');
    assert.equal(call.query.accessibilityPreference, 'StepFreeToVehicle');
    assert.equal(call.query.mode, 'tube,dlr,overground,elizabeth-line,tram');
    assert.equal(call.query.includeAlternativeRoutes, 'true');
    assert.ok(calls.every((c) => c.metricUrl === '/Journey'));
    assert.equal(response.data.from.id, 'HUBA');
    assert.equal(response.meta.stale, false);
    assert.equal(response.data.journeys.length, 2);
});

test('coalesces requests, caches briefly and never falls back to expired routes', async () => {
    const { planner, calls, advance, fail } = makePlanner();
    await Promise.all([planner.plan(query), planner.plan(query)]);
    assert.equal(calls.filter((c) => c.path.includes('JourneyResults')).length, 1);
    assert.equal((await planner.plan(query)).meta.cached, true);
    advance(30_000);
    fail();
    await assert.rejects(planner.plan(query), /Offline/);
});

test('limits active planning requests without preventing cached results', async () => {
    const { planner } = makePlanner();
    await planner.plan(query);
    planner.active = 2;
    assert.equal((await planner.plan(query)).meta.cached, true);
    await assert.rejects(planner.plan({ ...query, accessibility: 'platform' }), (e) => e.status === 429);
});

test('uses a bounded fallback and reports when a less-disrupted route cannot be found', async () => {
    let count = 0;
    const { planner } = makePlanner({ client: { fetchJSON: async (path) => {
        if (path.startsWith('/Line/')) return allGood;
        if (path.startsWith('/StopPoint')) return { icsCode: '10001' };
        count += 1;
        return { journeys: [itinerary({ warnings: [severe] })] };
    } } });
    const response = await planner.plan(query);
    assert.equal(count, 2);
    assert.match(response.data.messages.join(), /No less-disrupted/);
    assert.deepEqual(response.data.journeys[0].labels, ['earliestArrival']);
});

test('valid no-route response remains distinct from an upstream failure', async () => {
    const { planner } = makePlanner({ client: { fetchJSON: async (path) =>
        path.startsWith('/StopPoint') ? {} : { journeys: [] } } });
    const response = await planner.plan(query);
    assert.equal(response.data.journeys.length, 0);
    assert.match(response.data.messages[0], /No rail journeys/);
    const invalid = makePlanner({ client: { fetchJSON: async () => ({}) } });
    await assert.rejects(invalid.planner.plan(query), (e) => e.status === 503);
});


test('station lookup failure falls back to valid NaPTAN members and still returns journeys', async () => {
    const paths = [];
    const { planner } = makePlanner({ client: { fetchJSON: async (path) => {
        paths.push(path);
        if (path.startsWith('/Line/')) return allGood;
        if (path.startsWith('/StopPoint')) throw Object.assign(new Error('Timed out'), { code: 'TFL_TIMEOUT' });
        return { journeys: [itinerary(), itinerary({ line: 'northern' })] };
    } } });
    assert.equal((await planner.plan(query)).data.journeys.length, 2);
    assert.ok(paths.includes('/Journey/JourneyResults/940A/to/940B'));
});

test('retries a transient primary failure once with privacy-safe phase metrics', async () => {
    const calls = [];
    const { planner } = makePlanner({ client: { fetchJSON: async (path, options) => {
        if (path.startsWith('/Line/')) return allGood;
        if (path.startsWith('/StopPoint')) return { icsCode: '10001' };
        calls.push(options);
        if (calls.length === 1) throw Object.assign(new Error('Service unavailable'), { status: 503 });
        return { journeys: [itinerary(), itinerary({ line: 'northern' })] };
    } } });
    assert.equal((await planner.plan(query)).data.journeys.length, 2);
    assert.deepEqual(calls.map(c => c.metricLabel), ['journeys:primary', 'journeys:retry']);
    assert.ok(calls.every(c => c.metricUrl === '/Journey'));
});

test('timeouts return an actionable journey-specific 503 after one retry', async () => {
    let calls = 0;
    const { planner } = makePlanner({ client: { fetchJSON: async (path) => {
        if (path.startsWith('/Line/')) return allGood;
        if (path.startsWith('/StopPoint')) return {};
        calls += 1;
        throw Object.assign(new Error('Timeout'), { name: 'TfLRequestError', code: 'TFL_TIMEOUT' });
    } } });
    await assert.rejects(planner.plan(query), e => e.status === 503 && /TfL is taking too long/.test(e.message));
    assert.equal(calls, 2);
});

test('a slow optional alternative cannot discard a successful primary result', async () => {
    const { planner } = makePlanner({ client: { fetchJSON: async (path, { query: q, signal }) => {
        if (path.startsWith('/Line/')) return allGood;
        if (path.startsWith('/StopPoint')) return {};
        if (q.journeyPreference === 'LeastInterchange') {
            await new Promise((_, reject) => {
                const keepAlive = setTimeout(() => reject(new Error('Alternative exceeded bound')), 4_000);
                signal.addEventListener('abort', () => { clearTimeout(keepAlive); reject(signal.reason); }, { once: true });
            });
        }
        return { journeys: [itinerary()] };
    } } });
    const response = await planner.plan(query);
    assert.equal(response.data.journeys.length, 1);
    assert.ok(response.data.messages.includes('Additional alternatives could not be checked.'));
});

test('does not retry rate limiting or unresolved stations', async () => {
    for (const status of [300, 429]) {
        let calls = 0;
        const { planner } = makePlanner({ client: { fetchJSON: async (path) => {
            if (path.startsWith('/Line/')) return allGood;
            if (path.startsWith('/StopPoint')) return {};
            calls += 1;
            throw Object.assign(new Error('Unavailable'), { name: 'TfLRequestError', status });
        } } });
        await assert.rejects(planner.plan(query));
        assert.equal(calls, 1);
    }
});

test('planner all-clear notices are not normalized as disruptions', () => {
    const result = normalizeJourney(itinerary({ warnings: [
        { type: 'lineInfo', description: 'Victoria: Good service.' },
        { type: 'lineInfo', description: 'No disruption reported.' },
        { type: 'lineInfo', description: 'Minor delays northbound. Good service on other routes.' }
    ] }), request);
    assert.equal(result.warnings.length, 1);
    assert.equal(result.warnings[0].severity, 'minor');
});
