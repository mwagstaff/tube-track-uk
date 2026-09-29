import assert from 'node:assert/strict';
import test from 'node:test';

import { ThameslinkNetwork, ThameslinkTrainEstimator } from '../lib/thameslink-trains.js';

// North–south line with a junction at J:  N1 - N2 - J - S1 - S2
//                                                  \
//                                                   E1 - E2 (east branch)
// Every hop is 1,600 m, so the default run time is 100 s + 30 s dwell = 130 s.
const station = (id, latitude, longitude) => ({ id, name: id, latitude, longitude });
const network = {
    stations: [
        station('N1', 51.60, -0.10), station('N2', 51.58, -0.10), station('J', 51.56, -0.10),
        station('S1', 51.54, -0.10), station('S2', 51.52, -0.10),
        station('E1', 51.56, -0.08), station('E2', 51.56, -0.06)
    ],
    segments: [['N1', 'N2'], ['N2', 'J'], ['J', 'S1'], ['S1', 'S2'], ['J', 'E1'], ['E1', 'E2']]
        .map(([from, to]) => ({ from, to, lengthM: 1_600 })),
    patterns: []
};
// Off-map places beyond each edge.
const coordinates = { NORTHTOWN: [52.50, -0.10], SOUTHTOWN: [50.60, -0.10], EASTTOWN: [51.56, 1.50] };
const NOW = Date.parse('2026-09-28T08:00:00Z');
const at = (seconds) => new Date(NOW + seconds * 1_000).toISOString();

function call(destination, arrival, departure = arrival === null ? null : arrival + 30, extra = {}) {
    return {
        destinationNaptanId: destination, destinationName: `${destination} Rail Station`,
        scheduledTimeOfArrival: arrival === null ? null : at(arrival),
        estimatedTimeOfArrival: arrival === null ? null : at(arrival),
        scheduledTimeOfDeparture: departure === null ? null : at(departure),
        estimatedTimeOfDeparture: departure === null ? null : at(departure),
        departureStatus: 'OnTime', ...extra
    };
}

const estimator = (patterns = []) =>
    new ThameslinkTrainEstimator({ network: new ThameslinkNetwork({ ...network, patterns }, coordinates) });
const boards = (entries) => new Map(Object.entries(entries));

test('places one train between the stations either side of its next call', () => {
    // Southbound: due at S1 in 60 s, then S2 130 s + 30 s dwell later.
    const trains = estimator().estimate(boards({
        S1: [call('SOUTHTOWN', 60)],
        S2: [call('SOUTHTOWN', 220)]
    }), NOW);
    assert.equal(trains.length, 1, 'the later call at S2 is the same train');
    const [train] = trains;
    assert.equal(train.previousStationId, 'J');
    assert.equal(train.nextStationId, 'S1');
    assert.equal(train.secondsToNextStation, 60);
    assert.ok(Math.abs(train.progress - (1 - 60 / 130)) < 0.01);
    assert.equal(train.destination, 'SOUTHTOWN');
});

test('a following train does not turn a train round', () => {
    // A northbound train due at S1 in 60 s. The next northbound train is due at
    // S2 a headway later, just when this train would reach S2 if it were going
    // south, so the boards alone cannot tell; TfL's calling pattern can.
    const trains = estimator([['SOUTHTOWN', 'S2', 'S1', 'J', 'N2', 'N1', 'NORTHTOWN']]).estimate(boards({
        S1: [call('NORTHTOWN', 60)],
        J: [call('NORTHTOWN', 220)],
        S2: [call('NORTHTOWN', 250)]
    }), NOW);
    assert.equal(trains.filter((item) => item.nextStopId === 'J').length, 0, 'its call at J is the same train');
    const train = trains.find((item) => item.nextStopId === 'S1');
    assert.equal(train.previousStationId, 'S2', 'it approaches S1 from the south');
    assert.equal(train.nextStationId, 'S1');
});

test('a train standing at a platform is drawn at that station', () => {
    const [train] = estimator().estimate(boards({ S1: [call('SOUTHTOWN', -20, 40)] }), NOW);
    assert.equal(train.nextStationId, 'S1');
    assert.equal(train.secondsToNextStation, 1);
});

test('cancelled calls and trains that have left are ignored', () => {
    const trains = estimator().estimate(boards({
        S1: [call('SOUTHTOWN', 60, 90, { departureStatus: 'Cancelled' }), call('SOUTHTOWN', -200, -170)]
    }), NOW);
    assert.deepEqual(trains, []);
});

test('never guesses which branch a train came from, unless a pattern or its last call says', () => {
    // Southbound towards S1 via J: from N2 or from E1? Nothing says.
    const board = { S1: [call('SOUTHTOWN', 200)] };
    assert.deepEqual(estimator().estimate(boards(board), NOW), []);

    // TfL's calling pattern runs this service in from the east.
    const [fromPattern] = estimator([['EASTTOWN', 'E2', 'E1', 'J', 'S1', 'S2', 'SOUTHTOWN']])
        .estimate(boards(board), NOW);
    assert.deepEqual([fromPattern.previousStationId, fromPattern.nextStationId], ['E1', 'J']);

    // Without a pattern, the board it has just left says the same.
    const learner = estimator();
    // Two minutes ago it was due to leave E1 in 40 s, and it has since left.
    learner.estimate(boards({ E1: [call('SOUTHTOWN', -100, -80)], S1: [call('SOUTHTOWN', 200)] }), NOW - 120_000);
    const [fromHistory] = learner.estimate(boards(board), NOW);
    assert.deepEqual([fromHistory.previousStationId, fromHistory.nextStationId], ['E1', 'J']);
});

test('learns run times from consecutive calls of the same train', () => {
    const learner = estimator();
    learner.estimate(boards({ S1: [call('SOUTHTOWN', 60, 90)], S2: [call('SOUTHTOWN', 280)] }), NOW);
    assert.equal(learner.runTime('S1', 'S2'), 190);
});

test('a Monday morning peak places the fleet on the right tracks, once each', async () => {
    const { readFile } = await import('node:fs/promises');
    const load = async (name) => JSON.parse(await readFile(new URL(`./fixtures/thameslink/${name}`, import.meta.url)));
    const earlier = await load('boards-b1.json');
    const later = await load('boards-b2.json');
    const real = new ThameslinkTrainEstimator();
    real.estimate(new Map(Object.entries(earlier.boards)), Date.parse(earlier.capturedAt));
    const trains = real.estimate(new Map(Object.entries(later.boards)), Date.parse(later.capturedAt));

    assert.ok(trains.length >= 25, `expected most of the peak fleet, got ${trains.length}`);
    assert.equal(new Set(trains.map((train) => train.id)).size, trains.length);
    // Every train is on a real segment and heading for its next call.
    for (const train of trains) {
        assert.ok(real.network.neighbours.get(train.previousStationId).has(train.nextStationId), train.id);
        assert.ok(train.progress > 0 && train.progress < 1);
    }
    const byNextStop = (stopId, destination) => trains.find((train) =>
        train.nextStopId === stopId && train.destinationStopId === destination);
    // The Bedford fast calls at West Hampstead Thameslink coming up from
    // Kentish Town, then leaves the map without stopping again.
    const bedford = byNextStop('910GWHMPSTM', '910GBEDFDM');
    assert.deepEqual([bedford.previousStationId, bedford.nextStationId], ['910GKNTSHTN', '910GWHMPSTM']);
    // A Sevenoaks train reaches St Mary Cray from the Bickley junction.
    const sevenoaks = byNextStop('910GSTMRYC', '910GSVNOAKS');
    assert.deepEqual([sevenoaks.previousStationId, sevenoaks.nextStationId], ['910GBICKLEY', '910GSTMRYC']);
});
