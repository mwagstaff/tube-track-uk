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

export class LiveRefreshTimeoutError extends Error {
    constructor(refreshTimeoutMs) {
        super(`Live refresh exceeded ${refreshTimeoutMs}ms`);
        this.name = 'LiveRefreshTimeoutError';
        this.code = 'LIVE_REFRESH_TIMEOUT';
    }
}

export class LivePoller {
    constructor({
        modes,
        client,
        cache,
        metrics,
        logger,
        notifier = null,
        pollIntervalMs = 30_000,
        requestStaggerMs = 1_000,
        refreshTimeoutMs = 120_000,
        watchdogIntervalMs = pollIntervalMs,
        clock = Date.now
    }) {
        this.modes = [...modes];
        this.client = client;
        this.cache = cache;
        this.metrics = metrics;
        this.logger = logger;
        this.notifier = notifier;
        this.pollIntervalMs = pollIntervalMs;
        this.requestStaggerMs = requestStaggerMs;
        this.refreshTimeoutMs = refreshTimeoutMs;
        this.watchdogIntervalMs = watchdogIntervalMs;
        this.clock = clock;

        this.running = false;
        this.refreshing = false;
        this.controller = null;
        this.loopPromise = null;
        this.watchdogTimer = null;
        this.startedAt = null;
        this.lastAttemptAt = null;
        this.lastSuccessAt = null;
        this.lastError = null;
        this.staleSince = null;
    }

    #notify(snapshot) {
        if (!this.notifier) return;
        try {
            Promise.resolve(this.notifier.notify(snapshot)).catch((error) => {
                this.logger?.error('push_notify_failed', { error: error?.message ?? String(error) });
            });
        } catch (error) {
            this.logger?.error('push_notify_failed', { error: error?.message ?? String(error) });
        }
    }

    status() {
        return {
            running: this.running,
            refreshing: this.refreshing,
            lastAttemptAt: this.lastAttemptAt,
            lastSuccessAt: this.lastSuccessAt,
            lastError: this.lastError,
            staleSince: this.staleSince
        };
    }

    start() {
        if (this.running) {
            return;
        }
        this.running = true;
        this.startedAt = this.clock();
        this.controller = new AbortController();
        this.loopPromise = this.#runLoop(this.controller.signal).catch((error) => {
            if (!this.controller.signal.aborted) {
                this.logger?.error('live_poll_loop_stopped', { error });
            }
        });
        this.watchdogTimer = setInterval(() => this.checkHealth(), this.watchdogIntervalMs);
        this.watchdogTimer.unref?.();
    }

    async stop() {
        if (!this.running) {
            return;
        }
        this.running = false;
        clearInterval(this.watchdogTimer);
        this.watchdogTimer = null;
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

        // Every attempt gets its own deadline. Aborting the attempt signal asks
        // the client to give up, but the deadline promise settles this call
        // even if an upstream request never honours the abort; an attempt that
        // outlives its deadline can no longer publish into the cache.
        const attempt = new AbortController();
        const attemptSignal = AbortSignal.any([signal, attempt.signal]);
        const deadline = new Promise((_, reject) => {
            if (attemptSignal.aborted) {
                reject(attemptSignal.reason);
                return;
            }
            attemptSignal.addEventListener('abort', () => reject(attemptSignal.reason), { once: true });
        });
        deadline.catch(() => {});
        const deadlineTimer = setTimeout(
            () => attempt.abort(new LiveRefreshTimeoutError(this.refreshTimeoutMs)),
            this.refreshTimeoutMs
        );
        deadlineTimer.unref?.();

        try {
            const { allArrivals, modeCounts } = await Promise.race([
                this.#collect(attemptSignal),
                deadline
            ]);
            if (attemptSignal.aborted) {
                throw attemptSignal.reason;
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
            // Push is a consumer of the snapshot, never a participant in
            // producing it: a notifier that hangs or throws must not delay or
            // fail a refresh that has already succeeded.
            this.#notify(state.snapshot);
            return { skipped: false, state };
        } catch (error) {
            const completedAtMs = this.clock();
            const cancelled = signal.aborted;
            const timedOut = !cancelled && error instanceof LiveRefreshTimeoutError;
            const durationSeconds = Math.max(0, completedAtMs - startedAtMs) / 1_000;
            this.lastError = cancelled
                ? null
                : {
                    at: new Date(completedAtMs).toISOString(),
                    code: error.code ?? 'LIVE_REFRESH_FAILED',
                    message: error.message
                };
            this.metrics?.observeRefresh({
                status: cancelled ? 'cancelled' : timedOut ? 'timeout' : 'failure',
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
            clearTimeout(deadlineTimer);
            this.refreshing = false;
        }
    }

    async #collect(signal) {
        const allArrivals = [];
        const modeCounts = {};
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
        return { allArrivals, modeCounts };
    }

    // Watchdog: runs on its own timer, independent of the polling loop, so a
    // wedged refresh still produces a log line and the healthcheck/metrics
    // reflect the stale cache. It is also the recovery path if the loop somehow
    // stopped without being asked to.
    checkHealth() {
        const nowMs = this.clock();
        const state = this.cache.read();
        const stale = !state || state.stale;

        if (!stale) {
            if (this.staleSince) {
                this.logger?.info('live_cache_recovered', {
                    staleForSeconds: Math.floor((nowMs - this.staleSince) / 1_000),
                    ageSeconds: state.ageSeconds
                });
                this.staleSince = null;
            }
            return { stale: false };
        }

        const startedAt = this.startedAt ?? nowMs;
        if (!state && nowMs - startedAt <= this.cache.staleAfterMs) {
            // Still starting up: nothing to report yet.
            return { stale: false };
        }

        this.staleSince ??= (state ? state.snapshot.updatedAtMs : startedAt) + this.cache.staleAfterMs;
        const details = {
            ageSeconds: state ? state.ageSeconds : null,
            staleForSeconds: Math.floor((nowMs - this.staleSince) / 1_000),
            staleAfterSeconds: Math.floor(this.cache.staleAfterMs / 1_000),
            refreshing: this.refreshing,
            lastAttemptAt: this.lastAttemptAt,
            lastSuccessAt: this.lastSuccessAt,
            lastError: this.lastError
        };
        this.logger?.warn('live_cache_stale', details);

        if (this.running && !this.loopPromise) {
            this.logger?.error('live_poll_loop_restarted', details);
            this.controller = new AbortController();
            this.loopPromise = this.#runLoop(this.controller.signal).catch(() => {});
        }
        return { stale: true, ...details };
    }

    async #runLoop(signal) {
        try {
            while (!signal.aborted) {
                const cycleStartedAt = this.clock();
                try {
                    await this.refreshOnce({ signal });
                } catch {
                    // refreshOnce already recorded the failure; the loop must
                    // outlive any single attempt, whatever went wrong in it.
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
        } finally {
            this.loopPromise = null;
        }
    }
}
