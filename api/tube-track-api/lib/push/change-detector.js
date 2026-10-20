// Decides whether a board is worth a push.
//
// Routine updates use APNs priority 5, which Apple excludes from the Live
// Activity push budget. Refresh on the 30-second poll cadence;
// priority 10 is reserved for material changes and the initial board.
// https://sosumi.ai/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
//
// Pure. Previous board in, next board out, a verdict back.

// Below this, a departure has merely jittered. TfL's predictions move by a few
// seconds constantly, and a countdown that is 30 seconds out is not wrong
// enough to be worth a push the passenger cannot see.
export const LEAD_DEPARTURE_THRESHOLD_SECONDS = 60;

// Keep recent delivery history bounded; this is not an APNs budget.
export const PUSH_HISTORY_WINDOW_MS = 60 * 60 * 1_000;
export const HEARTBEAT_MS = 30 * 1_000;
export const RELAXED_HEARTBEAT_MS = 60 * 1_000;
export const PUSH_STALE_WINDOW_MS = 3 * 60 * 1_000;
export const RELAXED_STALE_WINDOW_MS = 7 * 60 * 1_000;
// Polls start every 30 seconds but finish at slightly different times. A small
// allowance avoids skipping an entire poll because it finished a fraction early.
const HEARTBEAT_TOLERANCE_MS = 2_000;

export const REASONS = Object.freeze({
    firstPush: 'first_push',
    leadDeparture: 'lead_departure',
    followingDeparture: 'following_departure',
    boardMembership: 'board_membership',
    platform: 'platform',
    destination: 'destination',
    serviceStatus: 'service_status',
    severity: 'severity',
    boardEmptied: 'board_emptied',
    heartbeat: 'heartbeat'
});

// Material changes affect which train a passenger takes or where they wait.
// Small prediction jitter and the passage of time only need routine refreshes.
const MATERIAL_REASONS = new Set([
    REASONS.boardEmptied,
    REASONS.boardMembership,
    REASONS.platform,
    REASONS.destination,
    REASONS.serviceStatus,
    REASONS.severity,
    REASONS.leadDeparture,
    REASONS.followingDeparture
]);

function ids(board) {
    return board.map((row) => row.id).join('|');
}

function leadDelta(previous, next) {
    if (previous.length === 0 || next.length === 0) return null;
    return Math.abs(next[0].expectedAtEpoch - previous[0].expectedAtEpoch);
}

export function staleWindowMs(frequentPushesEnabled) {
    return frequentPushesEnabled ? PUSH_STALE_WINDOW_MS : RELAXED_STALE_WINDOW_MS;
}

/**
 * @param {object} args
 * @param {Array|null} args.previous  the board last pushed, or null if none
 * @param {Array} args.next           the board just computed
 * @param {number|null} args.previousSeverityRank
 * @param {number|null} args.nextSeverityRank  lower rank means worse service
 * @param {number|null} args.lastPushedAtMs
 * @param {boolean} args.frequentPushesEnabled
 * @param {number} args.nowMs
 */
export function detectChange({
    previous,
    next = [],
    previousSeverityRank = null,
    nextSeverityRank = null,
    lastPushedAtMs = null,
    frequentPushesEnabled = true,
    nowMs = Date.now()
}) {
    return decideOnMerit({
        previous, next, previousSeverityRank, nextSeverityRank,
        lastPushedAtMs, frequentPushesEnabled, nowMs
    });
}

function decideOnMerit({
    previous,
    next,
    previousSeverityRank,
    nextSeverityRank,
    lastPushedAtMs,
    frequentPushesEnabled,
    nowMs
}) {
    if (!previous || lastPushedAtMs === null) {
        return { shouldPush: true, priority: 10, reason: REASONS.firstPush };
    }

    const verdict = (reason) => ({
        shouldPush: true,
        priority: MATERIAL_REASONS.has(reason) ? 10 : 5,
        reason
    });

    if (previous.length > 0 && next.length === 0) {
        return verdict(REASONS.boardEmptied);
    }

    // Both disruption and recovery change the passenger’s travel options.
    if (
        typeof nextSeverityRank === 'number'
        && typeof previousSeverityRank === 'number'
        && nextSeverityRank !== previousSeverityRank
    ) {
        return verdict(REASONS.severity);
    }

    if (ids(previous) !== ids(next)) {
        return verdict(REASONS.boardMembership);
    }

    const delta = leadDelta(previous, next);
    if (delta !== null && delta >= LEAD_DEPARTURE_THRESHOLD_SECONDS) {
        return verdict(REASONS.leadDeparture);
    }

    for (let index = 0; index < next.length; index += 1) {
        if (next[index].platform !== previous[index]?.platform) {
            return verdict(REASONS.platform);
        }
        if (next[index].destination !== previous[index]?.destination) {
            return verdict(REASONS.destination);
        }
        // A National Rail train that is cancelled or delayed changes the plan.
        if ((next[index].status ?? null) !== (previous[index]?.status ?? null)
            || (next[index].hasExpectedTime ?? true) !== (previous[index]?.hasExpectedTime ?? true)) {
            return verdict(REASONS.serviceStatus);
        }
    }

    // Following trains also matter when a passenger is choosing a later service.
    if (next.some((departure, index) => index > 0
        && Math.abs(departure.expectedAtEpoch - previous[index].expectedAtEpoch)
            >= LEAD_DEPARTURE_THRESHOLD_SECONDS)) {
        return verdict(REASONS.followingDeparture);
    }

    const heartbeat = frequentPushesEnabled ? HEARTBEAT_MS : RELAXED_HEARTBEAT_MS;
    if (nowMs - lastPushedAtMs >= heartbeat - HEARTBEAT_TOLERANCE_MS) {
        return { shouldPush: true, priority: 5, reason: REASONS.heartbeat };
    }

    return { shouldPush: false, priority: 5, reason: null };
}
