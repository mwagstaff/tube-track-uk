// The board a tracked Live Activity shows, computed server-side.
//
// This is a deliberate duplicate of TubeTrackCore's `DepartureActivityBoard`,
// `StationDepartureGroup` and `StationDepartureMetadata`. The app produces a
// board from its own poll; the server pushes one between polls. If the two
// disagree, the passenger watches the board change for no reason when they open
// the app — so every rule here mirrors the Swift, and the fixtures in
// test/push-departure-projection.test.js are shared with the Swift tests.
//
// Pure: no clock, no I/O. Callers pass a snapshot and get a board back.

const CARDINAL_DIRECTIONS = ['northbound', 'southbound', 'eastbound', 'westbound'];
const STOP_NAME_SUFFIXES = [
    ' underground station',
    ' dlr station',
    ' tram stop',
    ' rail station'
];

export const DIRECTION_FILTERS = Object.freeze([
    'any',
    'northbound',
    'southbound',
    'eastbound',
    'westbound',
    'inbound',
    'outbound'
]);

export const MAXIMUM_DEPARTURES = 3;

// Mirrors the truncation in ContentState.Departure so a board built here cannot
// encode larger than the one the app built.
const DESTINATION_LIMIT = 28;
const PLATFORM_LIMIT = 14;

function trimmed(value) {
    if (typeof value !== 'string') return null;
    const result = value.trim();
    return result.length > 0 ? result : null;
}

function capitalised(value) {
    // Swift's `String.capitalized` upper-cases the first letter of every word.
    return value.replace(/\b\p{L}[\p{L}\p{M}'’]*/gu, (word) =>
        word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()
    );
}

function passengerFacingStopName(rawName) {
    const lowercased = rawName.toLowerCase();
    for (const suffix of STOP_NAME_SUFFIXES) {
        if (lowercased.endsWith(suffix)) {
            return rawName.slice(0, rawName.length - suffix.length);
        }
    }
    return rawName;
}

function normalisedStopName(value) {
    const name = trimmed(value);
    return name === null ? null : passengerFacingStopName(name).toLowerCase();
}

function referencesStation(value, normalizedStationName) {
    const candidate = normalisedStopName(value) ?? '';
    return candidate === normalizedStationName
        || candidate.startsWith(`${normalizedStationName} via `);
}

export function directionLabel(arrival) {
    const platformName = trimmed(arrival.platformName)?.toLowerCase();
    if (platformName) {
        const cardinal = CARDINAL_DIRECTIONS.find((value) => platformName.includes(value));
        if (cardinal) {
            return capitalised(cardinal);
        }
    }

    const direction = trimmed(arrival.direction);
    if (direction) {
        if (arrival.lineId === 'elizabeth') {
            if (direction.toLowerCase() === 'inbound') return 'Eastbound';
            if (direction.toLowerCase() === 'outbound') return 'Westbound';
        }
        return capitalised(direction);
    }
    return 'All directions';
}

export function platformLabel(arrival) {
    const platform = trimmed(arrival.platformName);
    if (platform === null) return null;

    const lowercased = platform.toLowerCase();
    // "Northbound" on its own names a direction, not a platform, and the
    // heading already says it.
    if (CARDINAL_DIRECTIONS.some((value) => lowercased.includes(value))
        && !lowercased.includes('platform')) {
        return null;
    }

    if (arrival.lineId === 'elizabeth' && /^\p{L}$/u.test(platform)) {
        return `Platform ${platform.toUpperCase()}`;
    }
    return platform;
}

export function compactPlatformLabel(arrival) {
    const label = platformLabel(arrival);
    if (label === null) return null;

    const platformIndex = label.toLowerCase().indexOf('platform');
    if (platformIndex >= 0) {
        return label.slice(platformIndex).trim();
    }
    const separatorIndex = label.indexOf(' - ');
    if (separatorIndex >= 0) {
        return label.slice(separatorIndex + 3).trim();
    }
    return label;
}

export function destinationLabel(arrival) {
    const stopId = trimmed(arrival.stopId)?.toUpperCase() ?? null;
    const destinationStopId = trimmed(arrival.destinationStopId)?.toUpperCase() ?? null;
    // A train terminating where the passenger is standing tells them nothing.
    if (stopId !== null && destinationStopId === stopId) {
        return 'Check front of train';
    }

    const stationName = normalisedStopName(arrival.stationName);
    for (const candidate of [arrival.destinationName, arrival.towards]) {
        const value = trimmed(candidate);
        if (value === null) continue;
        if (stationName !== null && referencesStation(value, stationName)) continue;
        return passengerFacingStopName(value);
    }
    return 'Check front of train';
}

export function matchesDirection(label, filter) {
    if (!filter || filter === 'any') return true;
    return String(label).toLowerCase() === String(filter).toLowerCase();
}

function expectedAtMs(arrival) {
    const parsed = Date.parse(arrival.expectedArrival ?? '');
    return Number.isFinite(parsed) ? parsed : null;
}

/**
 * The top departures for one tracked board.
 *
 * `direction` is the canonical filter the client stored (`directionFilterRaw`),
 * never the display label — a station that labels its platforms some other way
 * resolves to `any` on the client, and this has to agree.
 */
export function projectBoard({
    arrivals = [],
    stopIds = [],
    lineId,
    direction = 'any',
    limit = MAXIMUM_DEPARTURES
} = {}) {
    const stops = new Set(stopIds.map((id) => String(id).toUpperCase()));

    const matching = arrivals.filter((arrival) => {
        if (arrival.lineId !== lineId) return false;
        if (stops.size > 0 && !stops.has(String(arrival.stopId).toUpperCase())) return false;
        return matchesDirection(directionLabel(arrival), direction);
    });

    return matching
        .filter((arrival) => expectedAtMs(arrival) !== null)
        .sort((left, right) => {
            const difference = expectedAtMs(left) - expectedAtMs(right);
            if (difference !== 0) return difference;
            return String(left.id).localeCompare(String(right.id));
        })
        .slice(0, limit)
        .map((arrival) => ({
            id: arrival.vehicleId ?? arrival.id,
            destination: destinationLabel(arrival).slice(0, DESTINATION_LIMIT),
            platform: compactPlatformLabel(arrival)?.slice(0, PLATFORM_LIMIT) ?? null,
            expectedAtEpoch: Math.round(expectedAtMs(arrival) / 1_000)
        }));
}
