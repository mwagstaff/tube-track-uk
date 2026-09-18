import assert from 'node:assert/strict';
import test from 'node:test';
import { JourneyDisruptions, statusSeverity } from '../lib/journey-disruptions.js';
import { JourneyPlanner } from '../lib/journey-planner.js';

const now = Date.parse('2026-09-17T12:00:00Z');
const iso = n => new Date(n).toISOString();
const stations = [
    { id: 'HUBA', stopIds: ['940A', '910A'], lineIds: ['victoria', 'elizabeth'] },
    { id: '940B', stopIds: ['940B'], lineIds: ['northern'] }
];
const line = (id, statuses = [{ statusSeverity: 10 }]) => ({ id, name: id, lineStatuses: statuses });
const allGood = ['victoria', 'northern', 'elizabeth'].map(id => line(id));
const period = (from = now, to = now + 3_600_000) => ({ fromDate: iso(from), toDate: iso(to) });
const feed = (data = allGood, status = 'available') => ({ data, status, checkedAt: iso(now) });
function journey(overrides = {}) {
    return { id: 'journey', routeKey: 'victoria', warnings: [], legs: [{
        id: '0', mode: 'tube', from: { id: '940A' }, to: { id: '940B' },
        lines: [{ id: 'victoria', name: 'Victoria' }], stops: [{ id: '940B' }],
        warnings: [], departureTime: iso(now + 300_000), arrivalTime: iso(now + 1_500_000), ...overrides
    }] };
}
const service = () => new JourneyDisruptions({ fetch: async () => allGood, stations, clock: () => now });
const enriched = (j = journey(), realtime = feed(), plannedWorks = feed()) =>
    service().enrich([j], { realtime, plannedWorks })[0];
const issue = (code, reason = 'Reported disruption', extra = {}) => ({
    statusSeverity: code, statusSeverityDescription: reason, reason, validityPeriods: [period()], ...extra
});

test('explicitly confirms no issues only after both applicable feeds cover every line', () => {
    const result = enriched();
    assert.equal(result.disruption.status, 'noIssues');
    assert.equal(result.disruption.hasDisruption, false);
    assert.equal(result.disruption.summary, 'No disruption reported.');
    assert.equal(result.disruption.coverage, 'complete');
    assert.deepEqual(result.disruption.issues, []);
    assert.equal(result.legs[0].disruption.status, 'noIssues');
    assert.equal(result.disruption.sources.length, 2);
});

test('uses TfL severity categories, including closed/suspended services and minor delays', () => {
    for (const code of [1, 2, 3, 4, 5, 6, 8, 11, 16, 20]) assert.equal(statusSeverity(code), 'major');
    for (const code of [7, 9, 14]) assert.equal(statusSeverity(code), 'minor');
    const minor = enriched(journey(), feed([line('victoria', [issue(9, 'Minor delays')])]));
    assert.equal(minor.disruption.status, 'minorDelays');
    assert.equal(minor.disruption.hasDisruption, true);
    assert.equal(minor.disruptionScore, 1);
    assert.equal(minor.legs[0].warnings[0].severity, 'minor');
    const major = enriched(journey(), feed([line('victoria', [issue(6, 'Severe delays')])]));
    assert.equal(major.disruption.status, 'majorIssues');
    assert.equal(major.disruptionScore, 10);
    assert.equal(major.warnings[0].severity, 'severe');
    assert.equal(major.disruption.issues[0].statusCode, 6);
});

test('planned closure severity and validity are retained without inventing a delay duration', () => {
    const works = feed([line('victoria', [issue(4, 'Planned closure', { disruption: { category: 'PlannedWork' } })])]);
    const result = enriched(journey(), feed(), works);
    assert.equal(result.disruption.status, 'majorIssues');
    assert.equal(result.disruption.issues[0].kind, 'plannedWork');
    assert.deepEqual(result.disruption.issues[0].sources, ['plannedWorks']);
    assert.deepEqual(result.disruption.issues[0].validityPeriods, [{ from: iso(now), to: iso(now + 3_600_000) }]);
    assert.equal(result.legs[0].departureTime, journey().legs[0].departureTime);
});

test('filters expired/future periods against each leg, including exclusive closure end', () => {
    for (const p of [period(now - 10000, now + 300_000), period(now + 1_500_000, now + 2_000_000)]) {
        const result = enriched(journey(), feed([line('victoria', [issue(6, 'Severe delays', { validityPeriods: [p] })])]));
        assert.equal(result.disruption.status, 'noIssues');
    }
});

test('current incidents are not projected into a future scheduled journey', () => {
    const result = enriched(journey({ departureTime: iso(now + 86_400_000), arrivalTime: iso(now + 87_000_000) }),
        feed([line('victoria', [issue(6)])]), feed());
    assert.equal(result.disruption.status, 'noIssues');
    assert.equal(result.disruption.sources.find(s => s.source === 'realtime').status, 'notApplicable');
    assert.equal(result.disruption.sources.find(s => s.source === 'plannedWorks').status, 'available');
});

test('unknown, missing, stale and failed data never produces a false all-clear', () => {
    for (const realtime of [feed([], 'unavailable'), feed(allGood, 'stale'), feed([]),
        feed([line('victoria', [])]), feed([line('victoria', [{ statusSeverity: 999 }])])]) {
        const result = enriched(journey(), realtime);
        assert.equal(result.disruption.status, 'unknown');
        assert.equal(result.disruption.hasDisruption, null);
        assert.notEqual(result.disruption.coverage, 'complete');
    }
    const badDates = feed([line('victoria', [issue(4, 'Closure', { validityPeriods: [{ fromDate: 'bad' }] })])]);
    assert.equal(enriched(journey(), feed(), badDates).disruption.status, 'unknown');
});

test('retains a confirmed issue when another source fails and marks its coverage incomplete', () => {
    const result = enriched(journey(), feed([line('victoria', [issue(6)])]), feed([], 'unavailable'));
    assert.equal(result.disruption.status, 'majorIssues');
    assert.equal(result.disruption.hasDisruption, true);
    assert.equal(result.disruption.coverage, 'partial');
});

test('stale issues are identified as last-known, not confirmed disruption', () => {
    const result = enriched(journey(), feed([line('victoria', [issue(6)])], 'stale'));
    assert.equal(result.disruption.status, 'unknown');
    assert.equal(result.disruption.issues[0].stale, true);
    assert.equal(result.disruptionScore, 0);
    assert.deepEqual(result.warnings, []);
});

test('deduplicates identical notices from planner, live status, planned works and several legs', () => {
    const j = journey({ warnings: [{ id: 'old', message: 'Severe delays', kind: 'line', severity: 'severe' }] });
    j.legs.push({ ...j.legs[0], id: '1', warnings: [] });
    const status = feed([line('victoria', [issue(6, 'Severe delays')])]);
    const result = enriched(j, status, status);
    assert.equal(result.disruption.issues.length, 1);
    assert.deepEqual(result.disruption.issues[0].sources.sort(), ['journeyPlanner', 'plannedWorks', 'realtime']);
    assert.equal(result.disruptionScore, 10);
});

test('accessibility notices remain informational, and walking is not treated as unmonitored rail', () => {
    const j = journey({ warnings: [{ id: 'lift', message: 'Lift unavailable', kind: 'accessibility', severity: 'information' }] });
    j.legs.push({ ...j.legs[0], mode: 'walking', id: 'walk', lines: [], warnings: [] });
    const result = enriched(j);
    assert.equal(result.disruption.status, 'information');
    assert.equal(result.disruptionScore, 0);
    assert.equal(result.legs[1].disruption.coverage, 'notApplicable');
});

test('matches line aliases and station hubs, while distinguishing uncertain line-level notices', () => {
    const j = journey({ lines: [{ id: 'elizabeth-line', name: 'Elizabeth line' }] });
    const result = enriched(j, feed([line('elizabeth', [issue(11, 'Part closed', {
        disruption: { affectedStops: [{ naptanId: '910A' }] }
    })])]));
    assert.equal(result.disruption.issues[0].lineId, 'elizabeth');
    assert.equal(result.disruption.issues[0].scope, 'station');
    const elsewhere = enriched(journey(), feed([line('victoria', [issue(6, 'Delays elsewhere')])]));
    assert.equal(elsewhere.disruption.issues[0].scope, 'line');
});

test('coalesces and caches feed checks, covers London dates across midnight and DST', async () => {
    const calls = [];
    const lookup = new JourneyDisruptions({ stations, clock: () => now, fetch: async (path, options) => {
        calls.push({ path, options }); return allGood;
    } });
    const journeys = [journey({ departureTime: '2026-10-24T22:50:00Z', arrivalTime: '2026-10-25T02:20:00Z' })];
    const snapshots = await Promise.all([lookup.snapshot(journeys, new AbortController().signal), lookup.snapshot(journeys, new AbortController().signal)]);
    assert.equal(calls.length, 1); // Future searches need only the dated feed.
    assert.match(calls[0].path, /Status\/2026-10-24\/to\/2026-10-26$/);
    assert.equal(snapshots[0].plannedWorks.status, 'available');
    await lookup.snapshot(journeys, new AbortController().signal);
    assert.equal(calls.length, 1);
});

test('malformed or cancelled lookups are optional and return unavailable coverage', async () => {
    const lookup = new JourneyDisruptions({ stations, clock: () => now, fetch: async () => ({ error: 'bad' }) });
    const snapshot = await lookup.snapshot([journey()], new AbortController().signal);
    assert.equal(snapshot.realtime.status, 'unavailable');
    assert.equal(snapshot.plannedWorks.status, 'unavailable');
    const aborted = await lookup.snapshot([journey()], AbortSignal.abort());
    assert.equal(aborted.realtime.status, 'unavailable');
});

// Exercise the real planner path: independent feed information must affect
// route comparison even if JourneyResults itself contains no warning.
test('planner enriches before ranking and retains a less-disrupted alternative', async () => {
    const itinerary = (id, end) => ({ startDateTime: iso(now + 300_000), arrivalDateTime: iso(now + end),
        legs: [{ mode: { id: 'tube' }, departureTime: iso(now + 300_000), arrivalTime: iso(now + end),
            departurePoint: { naptanId: '940A' }, arrivalPoint: { naptanId: '940B' },
            routeOptions: [{ lineIdentifier: { id, name: id } }], disruptions: [] }] });
    const planner = new JourneyPlanner({ stations, clock: () => now, client: { fetchJSON: async path => {
        if (path.startsWith('/StopPoint')) return {};
        if (path.startsWith('/Journey')) return { journeys: [itinerary('victoria', 900_000), itinerary('northern', 1200_000)] };
        if (path.includes('/Mode/')) return [line('victoria', [issue(6, 'Severe delays')]), line('northern')];
        return allGood;
    } } });
    const response = await planner.plan({ from: '940A', to: '940B' });
    assert.equal(response.data.journeys[0].disruption.status, 'majorIssues');
    assert.equal(response.data.journeys[1].disruption.status, 'noIssues');
    assert.deepEqual(response.data.journeys[1].labels, ['lessDisrupted']);
});

test('a failed refresh preserves last-known notices without confirming them', async () => {
    let time = now;
    let offline = false;
    const lookup = new JourneyDisruptions({ stations, clock: () => time, fetch: async () => {
        if (offline) throw new Error('Offline');
        return [line('victoria', [issue(6, 'Severe delays')])];
    } });
    await lookup.snapshot([journey()], new AbortController().signal);
    time += 301_000;
    offline = true;
    const snapshot = await lookup.snapshot([journey()], new AbortController().signal);
    assert.equal(snapshot.realtime.status, 'stale');
    assert.equal(snapshot.realtime.checkedAt, iso(now));
    assert.equal(snapshot.plannedWorks.status, 'stale');
    const result = lookup.enrich([journey()], snapshot)[0];
    assert.equal(result.disruption.status, 'unknown');
    assert.equal(result.disruption.hasDisruption, null);
    assert.equal(result.disruption.issues[0].stale, true);
});

test('uncertain alternatives cannot be advertised as less disrupted', async () => {
    const { selectJourneys } = await import('../lib/journey-planner.js');
    const first = enriched(journey(), feed([line('victoria', [issue(6)])]));
    const second = enriched(journey(), feed([], 'unavailable'));
    Object.assign(first, { departureTime: iso(now + 300_000), arrivalTime: iso(now + 900_000) });
    Object.assign(second, { id: 'other', routeKey: 'other', departureTime: iso(now + 300_000), arrivalTime: iso(now + 1200_000) });
    const choices = selectJourneys([first, second], { timeMode: 'now', requestedAt: now }, now);
    assert.equal(choices.length, 2);
    assert.deepEqual(choices[1].labels, []);
});

test('near-term dated statuses refresh with realtime data instead of retaining old delays for five minutes', async () => {
    let time = now;
    let calls = 0;
    let delayed = true;
    const lookup = new JourneyDisruptions({ stations, clock: () => time, fetch: async () => {
        calls += 1;
        return delayed ? [line('victoria', [issue(9, 'Minor delays')])] : allGood;
    } });
    const initial = await lookup.snapshot([journey()], new AbortController().signal);
    assert.equal(lookup.enrich([journey()], initial)[0].disruption.status, 'minorDelays');
    delayed = false;
    time += 30_001;
    const refreshed = await lookup.snapshot([journey()], new AbortController().signal);
    assert.equal(calls, 4);
    assert.equal(lookup.enrich([journey()], refreshed)[0].disruption.status, 'noIssues');
});
