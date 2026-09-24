// Decides whether a board is worth a push.
//
// Budget is the whole problem: iOS allows roughly 8 Live Activity pushes an
// hour while the device is locked, and spends them silently. A push for every
// 30-second poll would burn an hour's allowance in four minutes and then the
// board would stop updating precisely when it matters. So: push when something
// a passenger would act on has changed, and otherwise let the client's own
// relative-time countdown carry the display forward for free.
//
// Pure. Previous board in, next board out, a verdict back.

// Below this, a departure has merely jittered. TfL's predictions move by a few
// seconds constantly, and a countdown that is 30 seconds out is not wrong
// enough to be worth a push the passenger cannot see.
export const LEAD_DEPARTURE_THRESHOLD_SECONDS = 60;

// What iOS actually allows while the device is locked. Undocumented and
// opportunistic, so treat it as a ceiling to stay under rather than a quota to
// spend: everything here still has to be correct when a push is dropped.
export const MAX_PUSHES_PER_HOUR = 8;
export const BUDGET_WINDOW_MS = 60 * 60 * 1_000;

// Heartbeats exist to keep the activity inside its stale window, and they are
// the only pushes that fire on a board where nothing is happening — so their
// rate sets the floor of the budget. 7 minutes is ~8.5/hour before the cap,
// which the cap then trims; 4 minutes would have been 15/hour and throttled.
// The server's stale-date (9 minutes) is set wider so one dropped heartbeat
// does not dim a board that is perfectly correct.
export const HEARTBEAT_MS = 7 * 60 * 1_000;
export const RELAXED_HEARTBEAT_MS = 20 * 60 * 1_000;
export const PUSH_STALE_WINDOW_MS = 9 * 60 * 1_000;
export const RELAXED_STALE_WINDOW_MS = 25 * 60 * 1_000;

export const REASONS = Object.freeze({
    firstPush: 'first_push',
    leadDeparture: 'lead_departure',
    boardMembership: 'board_membership',
    platform: 'platform',
    destination: 'destination',
    severity: 'severity',
    boardEmptied: 'board_emptied',
    heartbeat: 'heartbeat'
});

// Priority 10 wakes a locked device immediately and costs battery; it is for
// things a passenger would otherwise act on wrongly — a train that vanished, a
// platform that moved, a train they are about to miss. These are also the only
// reasons allowed to spend the last of an exhausted budget.
const URGENT_REASONS = new Set([
    REASONS.boardEmptied,
    REASONS.boardMembership,
    REASONS.platform,
    REASONS.destination,
    REASONS.severity
]);

// "Due" in the app is anything under 45 seconds; a train pulled forward into
// that window is the moment a passenger needs to start moving.
const DUE_SECONDS = 45;

function ids(board) {
    return board.map((row) => row.id).join('|');
}

function leadDelta(previous, next) {
    if (previous.length === 0 || next.length === 0) return null;
    return Math.abs(next[0].expectedAtEpoch - previous[0].expectedAtEpoch);
}

function becameUrgent(previous, next, nowMs) {
    if (previous.length === 0 || next.length === 0) return false;
    const pulledForward = next[0].expectedAtEpoch < previous[0].expectedAtEpoch;
    const secondsAway = next[0].expectedAtEpoch - Math.floor(nowMs / 1_000);
    return pulledForward && secondsAway <= DUE_SECONDS;
}

/** How many of the recent pushes still count against the hourly budget. */
export function pushesInWindow(recentPushMs = [], nowMs = Date.now()) {
    return recentPushMs.filter((at) => nowMs - at < BUDGET_WINDOW_MS).length;
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
 * @param {number[]} args.recentPushMs  timestamps of pushes already sent
 * @param {boolean} args.frequentPushesEnabled
 * @param {number} args.nowMs
 */
export function detectChange({
    previous,
    next = [],
    previousSeverityRank = null,
    nextSeverityRank = null,
    lastPushedAtMs = null,
    recentPushMs = [],
    frequentPushesEnabled = true,
    nowMs = Date.now()
}) {
    const decision = decideOnMerit({
        previous,
        next,
        previousSeverityRank,
        nextSeverityRank,
        lastPushedAtMs,
        frequentPushesEnabled,
        nowMs
    });
    if (!decision.shouldPush) return decision;

    // Over budget, only the things a passenger would act on wrongly get through.
    // Dropping a heartbeat costs a dimmed board; dropping a cancellation costs
    // them the train.
    const spent = pushesInWindow(recentPushMs, nowMs);
    if (spent >= MAX_PUSHES_PER_HOUR && decision.priority < 10) {
        return { shouldPush: false, priority: decision.priority, reason: null, suppressed: decision.reason };
    }
    return decision;
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
        priority: URGENT_REASONS.has(reason) ? 10 : 5,
        reason
    });

    if (previous.length > 0 && next.length === 0) {
        return verdict(REASONS.boardEmptied);
    }

    // Severity getting worse is worth waking the device for; recovering is not.
    if (
        typeof nextSeverityRank === 'number'
        && typeof previousSeverityRank === 'number'
        && nextSeverityRank !== previousSeverityRank
    ) {
        return nextSeverityRank < previousSeverityRank
            ? verdict(REASONS.severity)
            : { shouldPush: true, priority: 5, reason: REASONS.severity };
    }

    if (ids(previous) !== ids(next)) {
        return verdict(REASONS.boardMembership);
    }

    const delta = leadDelta(previous, next);
    if (delta !== null && delta >= LEAD_DEPARTURE_THRESHOLD_SECONDS) {
        return {
            shouldPush: true,
            // A train that got later is a plan change; one pulled forward into
            // "Due" is someone about to miss it.
            priority: becameUrgent(previous, next, nowMs) ? 10 : 5,
            reason: REASONS.leadDeparture
        };
    }

    for (let index = 0; index < next.length; index += 1) {
        if (next[index].platform !== previous[index]?.platform) {
            return verdict(REASONS.platform);
        }
        if (next[index].destination !== previous[index]?.destination) {
            return verdict(REASONS.destination);
        }
    }

    const heartbeat = frequentPushesEnabled ? HEARTBEAT_MS : RELAXED_HEARTBEAT_MS;
    if (nowMs - lastPushedAtMs >= heartbeat) {
        return { shouldPush: true, priority: 5, reason: REASONS.heartbeat };
    }

    return { shouldPush: false, priority: 5, reason: null };
}
