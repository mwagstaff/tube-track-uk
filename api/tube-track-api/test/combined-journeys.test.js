import test from 'node:test';
import { JourneyDisruptions } from '../lib/journey-disruptions.js';
import assert from 'node:assert/strict';
import { CombinedJourneys, imminentJourneyCandidates, normalizeCombinedJourney, validateCombinedQuery } from '../lib/combined-journeys.js';

const now = Date.parse('2026-10-09T10:00:00Z');
const at = minute => new Date(now + minute * 60000).toISOString();
const query = { from: 'nr:KTH', to: '940GZZLUOXC', timeMode: 'now', accessibility: 'none' };
function rail(overrides = {}) {
    return { kind: 'vehicle', mode: 'rail', from: { crs: 'KTH', name: 'Kent House' }, to: { crs: 'VIC', name: 'Victoria' },
        departure: at(5), arrival: at(25), operator: 'SE', serviceId: 'train',
        callingPoints: [{ station: { crs: 'KTH', name: 'Kent House' } }, { station: { crs: 'VIC', name: 'Victoria' } }], ...overrides };
}
const journey = legs => ({ id: 'route', departure: legs[0].departure, arrival: legs.at(-1).arrival, changes: 0, legs });

test('map-only validation accepts National Rail and Tube endpoints in either direction', () => {
    assert.equal(validateCombinedQuery(query, now).from.id, 'nr:KTH');
    assert.equal(validateCombinedQuery({ ...query, from: query.to, to: query.from }, now).to.id, 'nr:KTH');
    assert.throws(() => validateCombinedQuery({ ...query, from: 'EUS' }, now), { code: 'UNKNOWN_STATION' });
    assert.throws(() => validateCombinedQuery({ ...query, to: query.from }, now), { code: 'SAME_STATION' });
    assert.throws(() => validateCombinedQuery({ ...query, timeMode: 'departAt', time: '2026-10-09T12:00:00' }, now), { code: 'INVALID_TIME' });
    assert.throws(() => validateCombinedQuery({ ...query, include: 'bus' }, now), { code: 'INVALID_QUERY' });
});

test('timetabled rail routes warn explicitly and map CRS back to map identities', () => {
    const result = normalizeCombinedJourney(journey([rail()]));
    assert.equal(result.legs[0].from.id, 'nr:KTH');
    assert.equal(result.legs[0].timing, 'scheduled');
    assert.match(result.warnings[0].message, /Live times are unavailable/);
    assert.equal(result.legs[0].lines[0].name, 'Southeastern');
});

test('live rail delays retain scheduled times, expected times and source time', () => {
    const result = normalizeCombinedJourney(journey([rail({ departure: at(12), arrival: at(33),
        scheduledDeparture: at(5), scheduledArrival: at(25),
        live: { status: 'delayed', departure: at(12), arrival: at(33), updatedAt: at(0), platform: '2' } })]));
    assert.equal(result.legs[0].timing, 'live');
    assert.equal(result.legs[0].scheduledDepartureTime, at(5));
    assert.equal(result.legs[0].departureTime, at(12));
    assert.equal(result.legs[0].from.platform, '2');
    assert.equal(result.legs[0].liveUpdatedAt, at(0));
});

test('cancelled journeys and unsupported modes are excluded whole; replacement buses remain explicit', () => {
    assert.equal(normalizeCombinedJourney(journey([rail({ live: { cancelled: true } })])), null);
    assert.equal(normalizeCombinedJourney(journey([rail({ mode: 'public-bus' })])), null);
    const result = normalizeCombinedJourney(journey([rail({ mode: 'replacementBus' })]));
    assert.equal(result.legs[0].mode, 'replacement-bus');
    assert.match(result.legs[0].instruction, /official replacement bus/);
});

test('mixed routes retain access allowances and reject an impossible connection', () => {
    const tfl = { kind: 'transfer', mode: 'tubeTransfer', from: { crs: 'VIC' }, to: { crs: 'OXC' }, departure: at(25), arrival: at(45),
        localJourney: { status: 'available', notes: ['Allow 5 minutes for the interchange.'], steps: [{
            mode: 'tube', instruction: 'Victoria line to Oxford Circus', from: { id: 'HUBVIC', name: 'Victoria' },
            to: { id: '940GZZLUOXC', name: 'Oxford Circus' }, departureTime: at(30), arrivalTime: at(40),
            durationMinutes: 10, timing: 'estimated', lines: [{ id: 'victoria', name: 'Victoria', direction: 'Oxford Circus' }], warnings: [], stops: []
        }] } };
    const result = normalizeCombinedJourney(journey([rail(), tfl]));
    assert.deepEqual(result.legs.map(l => l.mode), ['national-rail', 'transfer', 'tube', 'transfer']);
    assert.equal(result.legs.at(-1).arrivalTime, at(45));
    assert.equal(normalizeCombinedJourney(journey([rail({ arrival: at(35) }), tfl])), null);
});

test('versioned job adapter ranks results and forwards cancellation without changing legacy APIs', async () => {
    const calls = [];
    const upstreamID = 'a'.repeat(8) + '-aaaa-aaaa-aaaa-' + 'a'.repeat(12);
    const service = new CombinedJourneys({ now: () => now, fetch: async (url, options) => {
        calls.push({ url, ...options });
        if (options.method === 'DELETE') return new Response(null, { status: 204 });
        return Response.json(options.method === 'POST' ? { id: upstreamID, status: 'queued' } : {
            status: 'completed', result: { journeys: [journey([rail()])], warnings: ['Live feed unavailable.'],
                expiresAt: at(0.3), search: { searchTruncated: true } }
        });
    } });
    const started = await service.start(query, 'test-client');
    assert.match(calls[0].url, /v5\/journey-planner\/search-jobs$/);
    assert.equal(JSON.parse(calls[0].body).origin, 'nr:KTH');
    const finished = await service.poll(started.id);
    assert.equal(finished.result.data.journeys[0].labels[0], 'earliestArrival');
    assert.ok(finished.result.data.messages.includes('Some alternatives could not be checked within this search.'));
    assert.equal(finished.result.meta.stale, false);
    await service.cancel(started.id);
    assert.equal(calls.at(-1).method, 'DELETE');
    await assert.rejects(service.poll(started.id), { code: 'SEARCH_EXPIRED' });
});

test('TfL fallback is explicit when combined planning is unavailable', async () => {
    const service = new CombinedJourneys({ now: () => now, disruptions: {}, fetch: async () => Response.json({}, { status: 503 }),
        tflPlanner: { plan: async () => ({ data: { journeys: [], messages: [] }, meta: {} }) } });
    const result = await service.start({ ...query, from: '940GZZLUVIC' }, 'test-client');
    assert.equal(result.status, 'completed');
    assert.match(result.result.data.messages[0], /National Rail alternatives have not been checked/);
    await assert.rejects(service.start(query, 'test-client'), { code: 'UPSTREAM_UNAVAILABLE' });
});


test('platform allowances do not falsely mark disruption coverage incomplete', () => {
    const service = new JourneyDisruptions({ fetch: async () => [], stations: [], clock: () => now,
        nonVehicleModes: ['walking', 'transfer'] });
    service.lineIDs = ['southeastern'];
    const trip = normalizeCombinedJourney(journey([rail()]));
    trip.legs.push({ ...trip.legs[0], mode: 'transfer', lines: [], warnings: [] });
    const feed = { status: 'available', checkedAt: at(0), data: [{ id: 'southeastern', lineStatuses: [{ statusSeverity: 10 }] }] };
    const [result] = service.enrich([trip], { realtime: feed, plannedWorks: feed });
    assert.equal(result.disruption.coverage, 'complete');
    assert.equal(result.legs.at(-1).disruption.coverage, 'notApplicable');
});

test('an incomplete empty refresh returns a retryable error with the station notice', async () => {
    const notice = 'TfL: Arsenal station is closed due to infrastructure damage.';
    const service = new CombinedJourneys({ now: () => now, fetch: async (_url, options) =>
        Response.json(options.method === 'POST' ? { id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', status: 'queued' }
            : { status: 'completed', result: { journeys: [], warnings: ['Generic timetable warning', notice],
                expiresAt: at(1), search: { searchTruncated: true } } }) });
    const job = await service.start(query, 'test');
    await assert.rejects(service.poll(job.id), error => error.code === 'SEARCH_INCOMPLETE'
        && error.status === 503 && error.message.startsWith(notice));
});

test('imminent departures exclude late choices but retain overnight fallback and arrive-by', () => {
    const routes = [5, 25, 54, 65].map(minutes => ({ departureTime: at(minutes) }));
    const request = { timeMode: 'now', requestedAt: now };
    assert.deepEqual(imminentJourneyCandidates(routes, request, now), routes.slice(0, 2));
    assert.deepEqual(imminentJourneyCandidates(routes.slice(2), request, now), routes.slice(2));
    assert.deepEqual(imminentJourneyCandidates(routes, { ...request, timeMode: 'arriveBy' }, now), routes);
    assert.deepEqual(imminentJourneyCandidates(routes, request, now + 26 * 60000), [routes[2]]);
    assert.deepEqual(imminentJourneyCandidates(routes, { ...request, timeMode: 'departAt', requestedAt: now + 50 * 60000 }, now), routes.slice(2));
});

test('rail branding is carried to journey lines with a safe unknown-colour fallback', () => {
    const branded = normalizeCombinedJourney(journey([rail({ operatorBranding: { name: 'Southeastern', colour: '#1D2452' } })]));
    assert.equal(branded.legs[0].lines[0].colour, '#1D2452');
    assert.equal(branded.legs[0].lines[0].operatorCode, 'SE');
    const malformed = normalizeCombinedJourney(journey([rail({ operatorBranding: { colour: 'invalid' } })]));
    assert.equal(malformed.legs[0].lines[0].colour, undefined);
});

test('fewer-change preference cannot reintroduce a late departure', async () => {
    const early = { ...journey([rail()]), id: 'early', changes: 3 };
    const late = { ...journey([rail({ departure: at(54), arrival: at(120), operator: 'SW' })]), id: 'late', changes: 0 };
    const service = new CombinedJourneys({ now: () => now, fetch: async (_url, options) =>
        Response.json(options.method === 'POST' ? { id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', status: 'queued' }
            : { status: 'completed', result: { journeys: [early, late], warnings: [], expiresAt: at(1) } }) });
    const job = await service.start(query, 'test');
    const response = await service.poll(job.id);
    assert.equal(response.result.data.journeys.length, 1);
    assert.equal(response.result.data.journeys[0].departureTime, at(5));
});
