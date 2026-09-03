import { normaliseArrivals } from './normalise-arrival.js';

function wait(ms, signal) {
    if (ms <= 0) {
        return Promise.resolve();
    }
    return new Promise((resolve, reject) => {
        const cleanup = () => signal.removeEventListener('abort', aborted);
        const timer = setTimeout(() => {
            cleanup();
            resolve();
        }, ms);
        timer.unref?.();
        const aborted = () => {
            clearTimeout(timer);
            cleanup();
            reject(signal.reason ?? new Error('Polling stopped'));
        };
        if (signal.aborted) {
            aborted();
            return;
        }
        signal.addEventListener('abort', aborted, { once: true });
    });
}

export class LivePoller {
    constructor({
        modes,
        client,
        cache,
        metrics,
        logger,
        pollIntervalMs = 30_000,
        requestStaggerMs = 1_000,
        clock = Date.now
    }) {
        this.modes = [...modes];
        this.client = client;
        this.cache = cache;
        this.metrics = metrics;
        this.logger = logger;
        this.pollIntervalMs = pollIntervalMs;
        this.requestStaggerMs = requestStaggerMs;
        this.clock = clock;

        this.running = false;
        this.refreshing = false;
        this.controller = null;
        this.loopPromise = null;
        this.lastAttemptAt = null;
        this.lastSuccessAt = null;
        this.lastError = null;
    }

    status() {
        return {
            running: this.running,
            refreshing: this.refreshing,
            lastAttemptAt: this.lastAttemptAt,
            lastSuccessAt: this.lastSuccessAt,
            lastError: this.lastError
        };
    }

    start() {
        if (this.running) {
            return;
        }
        this.running = true;
        this.controller = new AbortController();
        this.loopPromise = this.#runLoop(this.controller.signal).catch((error) => {
            if (!this.controller.signal.aborted) {
                this.logger?.error('live_poll_loop_stopped', { error });
            }
        });
    }

    async stop() {
        if (!this.running) {
            return;
        }
        this.running = false;
        this.controller?.abort(new Error('Service shutting down'));
        await this.loopPromise;
        this.loopPromise = null;
    }

    async refreshOnce({ signal = new AbortController().signal } = {}) {
        if (this.refreshing) {
            this.metrics?.observeRefresh({ status: 'skipped', durationSeconds: 0 });
            return { skipped: true };
        }

        this.refreshing = true;
        const startedAtMs = this.clock();
        this.lastAttemptAt = new Date(startedAtMs).toISOString();
        const allArrivals = [];
        const modeCounts = {};

        try {
            for (let index = 0; index < this.modes.length; index += 1) {
                if (index > 0) {
                    await wait(this.requestStaggerMs, signal);
                }
                const mode = this.modes[index];
                const predictions = await this.client.fetchArrivals(mode, { signal });
                const arrivals = normaliseArrivals(predictions, mode);
                allArrivals.push(...arrivals);
                modeCounts[mode] = arrivals.length;
            }

            const completedAtMs = this.clock();
            const state = this.cache.replace(allArrivals, {
                startedAt: startedAtMs,
                completedAt: completedAtMs,
                modeCounts
            });
            this.lastSuccessAt = state.snapshot.updatedAt;
            this.lastError = null;

            const durationSeconds = Math.max(0, completedAtMs - startedAtMs) / 1_000;
            this.metrics?.observeRefresh({ status: 'success', durationSeconds });
            this.metrics?.setCache({
                itemCount: state.snapshot.arrivals.length,
                updatedAtMs: state.snapshot.updatedAtMs
            });
            this.logger?.info('live_cache_refreshed', {
                durationSeconds,
                itemCount: state.snapshot.arrivals.length,
                modeCounts
            });
            return { skipped: false, state };
        } catch (error) {
            const completedAtMs = this.clock();
            const cancelled = signal.aborted;
            const durationSeconds = Math.max(0, completedAtMs - startedAtMs) / 1_000;
            this.lastError = cancelled
                ? null
                : {
                    at: new Date(completedAtMs).toISOString(),
                    code: error.code ?? 'LIVE_REFRESH_FAILED',
                    message: error.message
                };
            this.metrics?.observeRefresh({
                status: cancelled ? 'cancelled' : 'failure',
                durationSeconds
            });
            if (!cancelled) {
                this.logger?.warn('live_cache_refresh_failed', {
                    durationSeconds,
                    error
                });
            }
            throw error;
        } finally {
            this.refreshing = false;
        }
    }

    async #runLoop(signal) {
        while (!signal.aborted) {
            const cycleStartedAt = this.clock();
            try {
                await this.refreshOnce({ signal });
            } catch {
                if (signal.aborted) {
                    break;
                }
            }

            const elapsed = Math.max(0, this.clock() - cycleStartedAt);
            const delay = Math.max(1_000, this.pollIntervalMs - elapsed);
            try {
                await wait(delay, signal);
            } catch {
                break;
            }
        }
    }
}
