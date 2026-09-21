export const LIVE_MODES = Object.freeze([
    'tube',
    'dlr',
    'overground',
    'tram',
    'elizabeth-line'
]);

const DEFAULTS = Object.freeze({
    port: 3018,
    host: '0.0.0.0',
    pollIntervalMs: 30_000,
    requestStaggerMs: 1_000,
    requestTimeoutMs: 10_000,
    maxConcurrentRequests: 8,
    staleAfterMs: 90_000,
    refreshTimeoutMs: 120_000
});

function positiveInteger(value, fallback, name, { maximum = Number.MAX_SAFE_INTEGER } = {}) {
    if (value === undefined || value === '') {
        return fallback;
    }

    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > maximum) {
        throw new Error(`${name} must be a positive integer no greater than ${maximum}`);
    }
    return parsed;
}

export function loadConfig(env = process.env) {
    const apiKey = env.TUBETRACK_UK_TFL_UNIFIED_API_KEY?.trim();
    if (!apiKey) {
        throw new Error('TUBETRACK_UK_TFL_UNIFIED_API_KEY is required');
    }

    const port = positiveInteger(env.PORT, DEFAULTS.port, 'PORT', { maximum: 65_535 });
    const pollIntervalMs = positiveInteger(
        env.TUBETRACK_UK_LIVE_POLL_INTERVAL_MS,
        DEFAULTS.pollIntervalMs,
        'TUBETRACK_UK_LIVE_POLL_INTERVAL_MS'
    );
    const requestStaggerMs = positiveInteger(
        env.TUBETRACK_UK_REQUEST_STAGGER_MS,
        DEFAULTS.requestStaggerMs,
        'TUBETRACK_UK_REQUEST_STAGGER_MS'
    );
    const requestTimeoutMs = positiveInteger(
        env.TUBETRACK_UK_TFL_TIMEOUT_MS,
        DEFAULTS.requestTimeoutMs,
        'TUBETRACK_UK_TFL_TIMEOUT_MS'
    );
    const maxConcurrentRequests = positiveInteger(
        env.TUBETRACK_UK_TFL_MAX_CONCURRENT_REQUESTS,
        DEFAULTS.maxConcurrentRequests,
        'TUBETRACK_UK_TFL_MAX_CONCURRENT_REQUESTS',
        { maximum: 100 }
    );
    const staleAfterMs = positiveInteger(
        env.TUBETRACK_UK_LIVE_STALE_AFTER_MS,
        DEFAULTS.staleAfterMs,
        'TUBETRACK_UK_LIVE_STALE_AFTER_MS'
    );

    const refreshTimeoutMs = positiveInteger(
        env.TUBETRACK_UK_LIVE_REFRESH_TIMEOUT_MS,
        DEFAULTS.refreshTimeoutMs,
        'TUBETRACK_UK_LIVE_REFRESH_TIMEOUT_MS'
    );

    if (requestStaggerMs * (LIVE_MODES.length - 1) >= pollIntervalMs) {
        throw new Error('TfL request staggering must fit inside the live polling interval');
    }
    if (staleAfterMs < pollIntervalMs) {
        throw new Error('Live cache stale threshold must not be shorter than the polling interval');
    }
    if (refreshTimeoutMs <= requestTimeoutMs) {
        throw new Error('Live refresh timeout must be longer than a single TfL request timeout');
    }

    return Object.freeze({
        apiKey,
        port,
        host: env.HOST?.trim() || DEFAULTS.host,
        pollIntervalMs,
        requestStaggerMs,
        requestTimeoutMs,
        maxConcurrentRequests,
        staleAfterMs,
        refreshTimeoutMs
    });
}
