import {
    PUSH_HISTORY_WINDOW_MS,
    detectChange,
    staleWindowMs
} from './change-detector.js';
import { conditionsByLine } from './line-condition.js';
import { liveActivityPayload } from './apns.js';
import { MAXIMUM_DEPARTURES, projectBoard } from './departure-projection.js';
import { LINE_COLOURS } from '../line-colours.js';

const ACTIVITY_MAX_DURATION_MS = 90 * 60 * 1_000;
const MODE_BY_LINE_ID = new Map(LINE_COLOURS.map((line) => [line.id, line.mode]));

/**
 * Turns each live snapshot into pushes for the boards people are tracking.
 *
 * Hooked into the poll loop, so the first rule is that it can never break it:
 * `notify` resolves rather than rejects, whatever happens underneath. A push
 * subsystem that takes the arrivals cache down with it is worse than no push
 * subsystem at all.
 */
export class LiveActivityNotifier {
    #inFlight = null;

    constructor({
        store,
        client,
        topic,
        logger,
        metrics,
        statuses = async () => [],
        clock = Date.now,
        maxDurationMs = ACTIVITY_MAX_DURATION_MS
    }) {
        this.store = store;
        this.client = client;
        this.topic = topic;
        this.logger = logger;
        this.metrics = metrics;
        this.statuses = statuses;
        this.clock = clock;
        this.maxDurationMs = maxDurationMs;
    }

    /**
     * Called after every successful cache replace. Never throws, and never runs
     * two passes at once — a slow APNs round trip must not let polls pile up.
     */
    async notify(snapshot, { staleModes = [] } = {}) {
        if (this.#inFlight) return { skipped: true, reason: 'in_flight' };
        this.#inFlight = this.#run(snapshot, new Set(staleModes))
            .catch((error) => {
                this.metrics?.recordPushFailure?.({ stage: 'notify' });
                this.logger?.error('push_notify_failed', { error: error?.message ?? String(error) });
                return { skipped: true, reason: 'error' };
            })
            .finally(() => {
                this.#inFlight = null;
            });
        return this.#inFlight;
    }

    async #run(snapshot, staleModes) {
        const rows = this.store.all({ type: 'liveActivity' });
        if (rows.length === 0) return { sent: 0, considered: 0 };

        const conditions = conditionsByLine(await this.#safeStatuses());
        const nowMs = this.clock();
        let sent = 0;

        for (const row of rows) {
            if (staleModes.has(MODE_BY_LINE_ID.get(row.lineId))) continue;
            // eslint-disable-next-line no-await-in-loop
            const outcome = await this.#considerRow({ row, snapshot, conditions, nowMs });
            if (outcome === 'sent') sent += 1;
        }

        this.metrics?.setPushTokens?.(this.store.countByType());
        return { sent, considered: rows.length };
    }

    async #safeStatuses() {
        try {
            return await this.statuses();
        } catch (error) {
            // Losing line status costs a headline, not a board.
            this.logger?.warn('push_statuses_unavailable', { error: error.message });
            return [];
        }
    }

    async #considerRow({ row, snapshot, conditions, nowMs }) {
        if (row.startedAtMs && nowMs - row.startedAtMs > this.maxDurationMs) {
            // The client caps activities at 90 minutes and ends them itself;
            // this is the server letting go of one whose app never came back.
            this.store.delete(row.id);
            this.logger?.info('push_subscription_expired', { id: row.id });
            return 'expired';
        }

        const board = projectBoard({
            arrivals: snapshot.arrivals,
            stopIds: row.stopIds,
            lineId: row.lineId,
            direction: row.direction,
            limit: MAXIMUM_DEPARTURES
        });
        const condition = conditions.get(row.lineId) ?? null;

        const verdict = detectChange({
            previous: row.lastBoard ?? null,
            next: board,
            previousSeverityRank: row.lastSeverityRank ?? null,
            nextSeverityRank: condition?.rank ?? null,
            lastPushedAtMs: row.lastPushedAtMs ?? null,
            frequentPushesEnabled: row.frequentPushesEnabled !== false,
            nowMs
        });

        if (!verdict.shouldPush) {
            if (verdict.suppressed) {
                this.metrics?.recordPushSuppressed?.({ reason: verdict.suppressed });
            }
            return 'unchanged';
        }

        this.metrics?.recordChangeDetected?.({ reason: verdict.reason });
        return this.#send({ row, board, condition, verdict, nowMs });
    }

    async #send({ row, board, condition, verdict, nowMs }) {
        const frequent = row.frequentPushesEnabled !== false;
        const updatedAtSeconds = Math.floor(nowMs / 1_000);
        const sequence = (row.sequence ?? 0) + 1;

        const contentState = {
            departures: board,
            updatedAtEpoch: updatedAtSeconds,
            conditionRank: condition?.rank ?? 3,
            conditionHeadline: condition?.headline ?? null,
            sequence
        };

        const payload = liveActivityPayload({
            event: 'update',
            contentState,
            timestampSeconds: updatedAtSeconds,
            staleDateSeconds: updatedAtSeconds + Math.floor(staleWindowMs(frequent) / 1_000),
            relevanceScore: relevanceScore(board, nowMs)
        });

        const startedAt = new Date(nowMs);
        let result;
        let environment = row.apnsEnvironment ?? this.client.environment ?? 'production';
        try {
            const request = {
                token: row.token,
                topic: this.topic,
                pushType: 'liveactivity',
                priority: verdict.priority,
                // No point delivering a departure board after the train has gone.
                expiration: updatedAtSeconds + 10 * 60,
                payload
            };
            result = await this.client.send({ ...request, environment });
            // Development and distributed builds mint tokens in different APNs
            // environments. Older clients don't report which one they use.
            // BadDeviceToken can mean the environment is wrong, not that the
            // activity ended. Try the other Apple endpoint once, then remember
            // the endpoint that accepted it. Never retry genuinely ended tokens.
            if (result.status === 400 && result.reason === 'BadDeviceToken') {
                environment = environment === 'production' ? 'sandbox' : 'production';
                result = await this.client.send({ ...request, environment });
            }
        } catch (error) {
            this.metrics?.recordPushSent?.({ type: 'liveActivity', result: 'error' });
            this.logger?.warn('push_send_failed', { id: row.id, error: error.message });
            return 'failed';
        } finally {
            this.metrics?.observePushDuration?.({
                type: 'liveActivity',
                durationSeconds: (this.clock() - startedAt.getTime()) / 1_000
            });
        }

        if (result.dead) {
            this.metrics?.recordPushSent?.({ type: 'liveActivity', result: 'dead' });
            this.store.delete(row.id);
            this.logger?.info('push_token_retired', { id: row.id, reason: result.reason });
            return 'dead';
        }

        if (!result.ok) {
            this.metrics?.recordPushSent?.({
                type: 'liveActivity',
                result: result.retryable ? 'retryable' : 'rejected'
            });
            this.logger?.warn('push_rejected', {
                id: row.id,
                status: result.status,
                reason: result.reason
            });
            return 'rejected';
        }

        this.metrics?.recordPushSent?.({ type: 'liveActivity', result: 'ok' });
        this.store.touch(row.id, {
            apnsEnvironment: environment,
            lastBoard: board,
            lastSeverityRank: condition?.rank ?? null,
            lastPushedAtMs: nowMs,
            sequence,
            recentPushMs: [...(row.recentPushMs ?? []), nowMs]
                .filter((at) => nowMs - at < PUSH_HISTORY_WINDOW_MS)
        });
        return 'sent';
    }
}

/** Mirrors `DepartureActivityPolicy.relevanceScore`. */
function relevanceScore(board, nowMs) {
    const next = board[0];
    if (!next) return 0;
    const minutes = Math.max(0, (next.expectedAtEpoch - nowMs / 1_000) / 60);
    return Math.max(0, 100 - minutes);
}
