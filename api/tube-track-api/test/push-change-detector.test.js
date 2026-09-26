import assert from 'node:assert/strict';
import test from 'node:test';
import {
    detectChange,
    HEARTBEAT_MS,
    LEAD_DEPARTURE_THRESHOLD_SECONDS,
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
        lastPushedAtMs: NOW_MS - 20_000,
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
    const justBefore = decide({ lastPushedAtMs: NOW_MS - HEARTBEAT_MS + 3_000 });
    assert.equal(justBefore.shouldPush, false);

    const due = decide({ lastPushedAtMs: NOW_MS - HEARTBEAT_MS });
    assert.equal(due.reason, REASONS.heartbeat);
    assert.equal(due.priority, 5);
});

test('small differences in poll completion time do not skip a refresh', () => {
    for (const frequentPushesEnabled of [true, false]) {
        const interval = frequentPushesEnabled ? 30_000 : 60_000;
        assert.equal(decide({
            frequentPushesEnabled, lastPushedAtMs: NOW_MS - interval + 750
        }).reason, REASONS.heartbeat);
    }
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

test('a quiet board gets a low-priority snapshot every thirty seconds for the full hour', () => {
    assert.equal(simulateAnHour({ boardAt: () => [row()] }), 120);
});

test('a board that changes every poll still receives thirty-second updates', () => {
    assert.equal(simulateAnHour({
        boardAt: (elapsed) => [row({ seconds: 300 + elapsed / 1_000 })]
    }), 120);
});

test('a passenger disabling frequent updates gets the relaxed cadence', () => {
    assert.equal(simulateAnHour({ boardAt: () => [row()], frequentPushesEnabled: false }), 60);
});

test('low-priority heartbeats remain deliverable after many prior updates', () => {
    const recentPushMs = Array.from({ length: 100 }, (_, index) => NOW_MS - index * 30_000);
    const heartbeat = decide({ recentPushMs, lastPushedAtMs: NOW_MS - HEARTBEAT_MS });
    assert.equal(heartbeat.shouldPush, true);
    assert.equal(heartbeat.priority, 5);
    assert.equal(heartbeat.reason, REASONS.heartbeat);
    assert.equal(decide({ recentPushMs, next: [] }).priority, 10);
});

test('crossing into Due gets a new snapshot even when the arrival timestamp is unchanged', () => {
    const board = [row({ seconds: 35 })];
    const verdict = decide({ previous: board, next: board, lastPushedAtMs: NOW_MS - 30_000 });
    assert.equal(verdict.shouldPush, true);
    assert.equal(verdict.priority, 5);
    assert.equal(verdict.reason, REASONS.heartbeat);
});

test('minute changes in following rows also refresh the board', () => {
    const board = [row({ seconds: 300 }), row({ id: 'v2', seconds: 395 })];
    assert.equal(decide({ previous: board, next: board, lastPushedAtMs: NOW_MS - 30_000 }).reason, REASONS.heartbeat);
});

test('routine countdown transitions are coalesced within thirty seconds', () => {
    const board = [row({ seconds: 50 })];
    assert.equal(decide({
        previous: board, next: board, lastPushedAtMs: NOW_MS - 20_000
    }).shouldPush, false);
});

test('the stale window is wider than the heartbeat that has to land inside it', () => {
    assert.ok(staleWindowMs(true) > HEARTBEAT_MS, 'one dropped heartbeat must not dim the board');
    assert.ok(staleWindowMs(false) > RELAXED_HEARTBEAT_MS);
});
