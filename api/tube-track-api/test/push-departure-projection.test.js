import assert from 'node:assert/strict';
import test from 'node:test';
import {
    compactPlatformLabel,
    destinationLabel,
    directionLabel,
    matchesDirection,
    projectBoard
} from '../lib/push/departure-projection.js';

const BASE_MS = 1_800_000_000_000;

function arrival({
    id = 'p1',
    vehicleId = null,
    stopId = '940GZZLUOXC',
    stationName = 'Oxford Circus Underground Station',
    lineId = 'central',
    platformName = 'Eastbound - Platform 2',
    direction = null,
    destinationStopId = null,
    destinationName = 'Hainault Underground Station',
    towards = null,
    seconds = 120
} = {}) {
    return {
        id,
        vehicleId,
        stopId,
        stationName,
        lineId,
        platformName,
        direction,
        destinationStopId,
        destinationName,
        towards,
        timeToStation: seconds,
        expectedArrival: new Date(BASE_MS + seconds * 1_000).toISOString()
    };
}

// Mirrors DepartureDirectionFilterTests.platformFixtures in TubeTrackCore.
// Any change on either side must be made on both, or the server will push a
// board the client would have filtered differently.
const PLATFORM_FIXTURES = [
    { lineId: 'victoria', platformName: 'Northbound - Platform 3', direction: null, expected: 'Northbound' },
    { lineId: 'victoria', platformName: 'Southbound - Platform 4', direction: null, expected: 'Southbound' },
    { lineId: 'central', platformName: 'Eastbound - Platform 2', direction: null, expected: 'Eastbound' },
    { lineId: 'central', platformName: 'Westbound - Platform 1', direction: null, expected: 'Westbound' },
    { lineId: 'elizabeth', platformName: null, direction: 'inbound', expected: 'Eastbound' },
    { lineId: 'elizabeth', platformName: null, direction: 'outbound', expected: 'Westbound' },
    { lineId: 'circle', platformName: null, direction: 'inbound', expected: 'Inbound' },
    { lineId: 'dlr', platformName: null, direction: null, expected: 'All directions' }
];

test('direction labels match the Swift fixtures exactly', () => {
    for (const fixture of PLATFORM_FIXTURES) {
        assert.equal(
            directionLabel(arrival(fixture)),
            fixture.expected,
            `${fixture.platformName ?? fixture.direction ?? 'nil'}`
        );
    }
});

test('an unlabelled platform belongs to no specific direction', () => {
    const label = directionLabel(arrival({ lineId: 'dlr', platformName: null, direction: null }));
    assert.equal(label, 'All directions');
    // `any` still matches it — that is what the client falls back to.
    assert.equal(matchesDirection(label, 'any'), true);
    assert.equal(matchesDirection(label, 'northbound'), false);
});

test('the board keeps the soonest four in the chosen direction', () => {
    const arrivals = [
        arrival({ id: 'late', vehicleId: 'vlate', seconds: 900 }),
        arrival({ id: 'soon', vehicleId: 'vsoon', seconds: 60 }),
        arrival({ id: 'mid', vehicleId: 'vmid', seconds: 300 }),
        arrival({ id: 'extra', vehicleId: 'vextra', seconds: 1_200 }),
        arrival({ id: 'overflow', vehicleId: 'voverflow', seconds: 1_500 }),
        arrival({
            id: 'other',
            vehicleId: 'vother',
            platformName: 'Westbound - Platform 1',
            seconds: 30
        })
    ];
    const board = projectBoard({
        arrivals,
        stopIds: ['940GZZLUOXC'],
        lineId: 'central',
        direction: 'eastbound'
    });
    assert.deepEqual(board.map((row) => row.id), ['vsoon', 'vmid', 'vlate', 'vextra']);
    assert.equal(board[0].expectedAtEpoch, Math.round(BASE_MS / 1_000) + 60);
});

test('a direction of any keeps both directions, newest first', () => {
    const arrivals = [
        arrival({ id: 'east', seconds: 300 }),
        arrival({ id: 'west', platformName: 'Westbound - Platform 1', seconds: 60 })
    ];
    const board = projectBoard({ arrivals, lineId: 'central', direction: 'any' });
    assert.deepEqual(board.map((row) => row.id), ['west', 'east']);
});

test('a board is confined to the stops of the tracked hub', () => {
    const arrivals = [
        arrival({ id: 'here', seconds: 60 }),
        arrival({ id: 'elsewhere', stopId: '940GZZLUBND', seconds: 30 })
    ];
    const board = projectBoard({
        arrivals,
        stopIds: ['940GZZLUOXC'],
        lineId: 'central',
        direction: 'any'
    });
    assert.deepEqual(board.map((row) => row.id), ['here']);
});

test('predictions with no expected time cannot reach a countdown', () => {
    const withoutTime = { ...arrival({ id: 'unknown' }), expectedArrival: null };
    const board = projectBoard({
        arrivals: [withoutTime, arrival({ id: 'known', seconds: 120 })],
        lineId: 'central',
        direction: 'any'
    });
    assert.deepEqual(board.map((row) => row.id), ['known']);
});

test('a push merges alternative platforms for one terminating train', () => {
    const common = {
        stopId: '940GZZLUBPS',
        stationName: 'Battersea Power Station Underground Station',
        lineId: 'northern',
        destinationStopId: '940GZZLUBPS',
        destinationName: 'Battersea Power Station Underground Station'
    };
    const board = projectBoard({
        arrivals: [
            arrival({ ...common, id: 'first-platform', vehicleId: 'train-1',
                platformName: 'Northbound - Platform 1', seconds: 180 }),
            arrival({ ...common, id: 'second-platform', vehicleId: 'train-1',
                platformName: 'Northbound - Platform 2', seconds: 181 }),
            arrival({ ...common, id: 'next-train', vehicleId: 'train-2',
                platformName: 'Northbound - Platform 1', seconds: 225 })
        ],
        lineId: 'northern',
        direction: 'northbound'
    });
    assert.deepEqual(board.map((row) => row.id), ['train-1', 'train-2']);
    assert.equal(board[0].platform, null);
});

test('same-looking minute labels do not merge different trains', () => {
    const board = projectBoard({
        arrivals: [
            arrival({ id: 'one', vehicleId: 'train-1', seconds: 181 }),
            arrival({ id: 'two', vehicleId: 'train-2', seconds: 220 })
        ],
        lineId: 'central',
        direction: 'eastbound'
    });
    assert.deepEqual(board.map((row) => row.id), ['train-1', 'train-2']);
});

test('identical predictions only occupy one Live Activity row', () => {
    const prediction = arrival({ id: 'repeated', seconds: 120 });
    const board = projectBoard({
        arrivals: [prediction, { ...prediction }, arrival({ id: 'next', seconds: 180 })],
        lineId: 'central',
        direction: 'eastbound'
    });
    assert.deepEqual(board.map((row) => row.id), ['repeated', 'next']);
});

test('platform labels drop the direction the heading already carries', () => {
    assert.equal(compactPlatformLabel(arrival({ platformName: 'Eastbound - Platform 2' })), 'Platform 2');
    assert.equal(compactPlatformLabel(arrival({ platformName: 'Platform 8' })), 'Platform 8');
    // A bare direction names no platform at all.
    assert.equal(compactPlatformLabel(arrival({ platformName: 'Northbound' })), null);
    assert.equal(compactPlatformLabel(arrival({ platformName: null })), null);
    assert.equal(
        compactPlatformLabel(arrival({ lineId: 'elizabeth', platformName: 'b' })),
        'Platform B'
    );
});

test('a train terminating where the passenger stands says so', () => {
    assert.equal(
        destinationLabel(arrival({ destinationStopId: '940GZZLUOXC' })),
        'Check front of train'
    );
    assert.equal(
        destinationLabel(arrival({ destinationName: 'Oxford Circus Underground Station' })),
        'Check front of train'
    );
    assert.equal(
        destinationLabel(arrival({ destinationName: null, towards: 'Epping' })),
        'Epping'
    );
    assert.equal(destinationLabel(arrival({})), 'Hainault');
});

test('long names are truncated to the same limits the client encodes', () => {
    const board = projectBoard({
        arrivals: [
            arrival({
                destinationName: 'Wimbledon '.repeat(12),
                platformName: `Platform ${'12 '.repeat(8)}`
            })
        ],
        lineId: 'central',
        direction: 'any'
    });
    assert.equal(board[0].destination.length, 28);
    assert.equal(board[0].platform.length, 14);
});
