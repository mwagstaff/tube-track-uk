import assert from 'node:assert/strict';
import test from 'node:test';
import {
    BUDGET_WINDOW_MS,
    detectChange,
    HEARTBEAT_MS,
    LEAD_DEPARTURE_THRESHOLD_SECONDS,
    MAX_PUSHES_PER_HOUR,
    RELAXED_HEARTBEAT_MS,
    REASONS,
    staleWindowMs
} from '../lib/push/change-detector.js';

const NOW_MS = 1_800_000_000_000;
const NOW_SECONDS = NOW_MS / 1_000;

function row({ id = 'v1', destination = 'Hainault', platform = 'Platform 2', seconds = 300 } = {}) {
    return { id, destination, platform, expectedAtEpoch: NOW_SECONDS + seconds };
}

function decide(overrides = {}) {
    return detectChange({
        previous: [row()],
        next: [row()],
        previousSeverityRank: 4,
        nextSeverityRank: 4,
        lastPushedAtMs: NOW_MS - 30_000,
        frequentPushesEnabled: true,
        nowMs: NOW_MS,
        ...overrides
    });
}

test('the first board for a subscription always pushes', () => {
    assert.deepEqual(decide({ previous: null, lastPushedAtMs: null }), {
        shouldPush: true,
        priority: 10,
        reason: REASONS.firstPush
    });
});

test('an unchanged board does not spend a push', () => {
    const verdict = decide();
    assert.equal(verdict.shouldPush, false);
    assert.equal(verdict.reason, null);
});

test('jitter below the threshold is not a change', () => {
    const verdict = decide({ next: [row({ seconds: 300 + LEAD_DEPARTURE_THRESHOLD_SECONDS - 1 })] });
    assert.equal(verdict.shouldPush, false);
});

test('the lead departure moving a minute is worth telling the passenger', () => {
    const verdict = decide({ next: [row({ seconds: 300 + LEAD_DEPARTURE_THRESHOLD_SECONDS })] });
    assert.equal(verdict.shouldPush, true);
    assert.equal(verdict.reason, REASONS.leadDeparture);
    // Later, not sooner — a plan change, not an emergency.
    assert.equal(verdict.priority, 5);
});

test('a train pulled forward into Due wakes the device', () => {
    const verdict = decide({
        previous: [row({ seconds: 300 })],
        next: [row({ seconds: 20 })]
    });
    assert.equal(verdict.reason, REASONS.leadDeparture);
    assert.equal(verdict.priority, 10);
});

test('a train pulled forward but still minutes away rides at normal priority', () => {
    const verdict = decide({
        previous: [row({ seconds: 600 })],
        next: [row({ seconds: 300 })]
    });
    assert.equal(verdict.reason, REASONS.leadDeparture);
    assert.equal(verdict.priority, 5);
});

test('a cancelled train — the board emptying — is urgent', () => {
    const verdict = decide({ next: [] });
    assert.equal(verdict.reason, REASONS.boardEmptied);
    assert.equal(verdict.priority, 10);
});

test('an already-empty board that stays empty does not push', () => {
    const verdict = decide({ previous: [], next: [] });
    assert.equal(verdict.shouldPush, false);
});

test('a different train at the front changes the board', () => {
    const verdict = decide({ next: [row({ id: 'v2' })] });
    assert.equal(verdict.reason, REASONS.boardMembership);
    assert.equal(verdict.priority, 10);
});

test('a platform change is urgent; the passenger is standing on the wrong one', () => {
    const verdict = decide({ next: [row({ platform: 'Platform 4' })] });
    assert.equal(verdict.reason, REASONS.platform);
    assert.equal(verdict.priority, 10);
});

test('a destination change is urgent', () => {
    const verdict = decide({ next: [row({ destination: 'Epping' })] });
    assert.equal(verdict.reason, REASONS.destination);
    assert.equal(verdict.priority, 10);
});

test('service getting worse wakes the device, recovering does not', () => {
    const worse = decide({ previousSeverityRank: 4, nextSeverityRank: 1 });
    assert.equal(worse.reason, REASONS.severity);
    assert.equal(worse.priority, 10);

    const better = decide({ previousSeverityRank: 1, nextSeverityRank: 4 });
    assert.equal(better.reason, REASONS.severity);
    assert.equal(better.priority, 5);
});

test('an unknown severity on either side is not treated as a change', () => {
    assert.equal(decide({ previousSeverityRank: null, nextSeverityRank: 1 }).shouldPush, false);
    assert.equal(decide({ previousSeverityRank: 1, nextSeverityRank: null }).shouldPush, false);
});

test('a silent board is refreshed before its stale window closes', () => {
    const justBefore = decide({ lastPushedAtMs: NOW_MS - HEARTBEAT_MS + 1_000 });
    assert.equal(justBefore.shouldPush, false);

    const due = decide({ lastPushedAtMs: NOW_MS - HEARTBEAT_MS });
    assert.equal(due.reason, REASONS.heartbeat);
    assert.equal(due.priority, 5);
});

test('the heartbeat widens when the passenger has turned frequent updates off', () => {
    const options = { lastPushedAtMs: NOW_MS - HEARTBEAT_MS - 1_000, frequentPushesEnabled: false };
    assert.equal(decide(options).shouldPush, false);

    assert.equal(
        decide({ ...options, lastPushedAtMs: NOW_MS - RELAXED_HEARTBEAT_MS }).reason,
        REASONS.heartbeat
    );
});

/** Replays a whole hour of 30-second polls and counts what got sent. */
function simulateAnHour({ boardAt, frequentPushesEnabled = true }) {
    let lastPushedAtMs = NOW_MS;
    let previous = boardAt(0);
    const recentPushMs = [NOW_MS];

    for (let elapsed = 30_000; elapsed <= 60 * 60 * 1_000; elapsed += 30_000) {
        const nowMs = NOW_MS + elapsed;
        const next = boardAt(elapsed);
        const verdict = detectChange({
            previous,
            next,
            previousSeverityRank: 4,
            nextSeverityRank: 4,
            lastPushedAtMs,
            recentPushMs,
            frequentPushesEnabled,
            nowMs
        });
        if (verdict.shouldPush) {
            recentPushMs.push(nowMs);
            lastPushedAtMs = nowMs;
            previous = next;
        }
    }
    return recentPushMs.length - 1;
}

test('an hour of a quiet board stays inside the push budget', () => {
    const board = [row()];
    const pushes = simulateAnHour({ boardAt: () => board });

    assert.ok(pushes <= MAX_PUSHES_PER_HOUR, `a quiet hour spent ${pushes} pushes`);
    // But it must still heartbeat, or the board dims for no reason.
    assert.ok(pushes >= 6, `a quiet hour must keep the activity fresh, got ${pushes}`);
});

test('an hour of a board that changes every poll is capped, not throttled by iOS', () => {
    // The pathological case: predictions flapping on every single poll.
    const pushes = simulateAnHour({
        boardAt: (elapsed) => [row({ seconds: 300 + elapsed / 1_000 })]
    });
    assert.ok(
        pushes <= MAX_PUSHES_PER_HOUR,
        `a flapping board spent ${pushes} pushes, which iOS would have thrown away`
    );
});

test('once the budget is spent, only what the passenger would act on gets through', () => {
    const spent = Array.from({ length: MAX_PUSHES_PER_HOUR }, (_, index) => NOW_MS - index * 60_000);

    // A heartbeat is dropped: the board dims, which is honest.
    const heartbeat = decide({ recentPushMs: spent, lastPushedAtMs: NOW_MS - HEARTBEAT_MS });
    assert.equal(heartbeat.shouldPush, false);
    assert.equal(heartbeat.suppressed, REASONS.heartbeat);

    // A cancellation is not: dropping it costs them the train.
    const cancelled = decide({ recentPushMs: spent, next: [] });
    assert.equal(cancelled.shouldPush, true);
    assert.equal(cancelled.reason, REASONS.boardEmptied);
});

test('the budget window rolls, so an old burst stops counting', () => {
    const longAgo = Array.from(
        { length: MAX_PUSHES_PER_HOUR },
        (_, index) => NOW_MS - BUDGET_WINDOW_MS - index * 1_000
    );
    const verdict = decide({ recentPushMs: longAgo, lastPushedAtMs: NOW_MS - HEARTBEAT_MS });
    assert.equal(verdict.shouldPush, true);
    assert.equal(verdict.reason, REASONS.heartbeat);
});

test('the stale window is wider than the heartbeat that has to land inside it', () => {
    assert.ok(staleWindowMs(true) > HEARTBEAT_MS, 'one dropped heartbeat must not dim the board');
    assert.ok(staleWindowMs(false) > RELAXED_HEARTBEAT_MS);
});
