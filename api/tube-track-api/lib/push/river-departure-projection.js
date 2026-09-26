import { MAXIMUM_DEPARTURES } from './departure-projection.js';

/** Mirrors RiverDepartureBoard: normalized departures only, never terminating boats. */
export function projectRiverBoard({ predictions, pierId, lineId, nowMs }) {
    return predictions.filter((item) => item.pierId === pierId && item.lineId === lineId
        && !item.terminatesHere && Date.parse(item.expectedArrival) >= nowMs
        && Date.parse(item.observedAt) >= nowMs - 90_000
        && Date.parse(item.observedAt) <= nowMs + 30_000
        && (!item.expiresAt || Date.parse(item.expiresAt) >= nowMs))
        .sort((a, b) => Date.parse(a.expectedArrival) - Date.parse(b.expectedArrival)
            || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        .slice(0, MAXIMUM_DEPARTURES)
        .map((item) => ({
            id: item.id,
            destination: [...(item.destinationName || 'Destination unavailable')].slice(0, 28).join(''),
            platform: null,
            expectedAtEpoch: Math.round(Date.parse(item.expectedArrival) / 1_000)
        }));
}

export function riverCondition(status) {
    const entries = status?.entries ?? [];
    const issue = entries.find((entry) => ![10, 18, 9].includes(entry.severity))
        ?? entries.find((entry) => entry.severity === 9);
    return {
        rank: issue ? (issue.severity === 9 ? 1 : 0) : entries.length ? 4 : 3,
        headline: issue?.description ?? null
    };
}
