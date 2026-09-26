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
    refreshTimeoutMs: 120_000,
    apnsEnvironment: 'production',
    apnsRequestTimeoutMs: 10_000
});

const APNS_ENVIRONMENTS = Object.freeze(['sandbox', 'production']);

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
        push: loadPushConfig(env),
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

/**
 * Push is optional: the API has to run perfectly well without APNs credentials,
 * because it did for months and a missing secret must not take the arrivals
 * cache down with it. `enabled` is false unless everything needed is present.
 *
 * Env names are the estate's existing ones (APNS_KEY_ID, APNS_TEAM_ID and the
 * shared key at ~/.certs), so tube-track-api reads the same Bitwarden item
 * shape as TrainTrack UK and Top Scores.
 */
export function loadPushConfig(env = process.env) {
    const keyId = env.APNS_KEY_ID?.trim();
    const teamId = env.APNS_TEAM_ID?.trim();
    const keyPath = env.APNS_AUTH_KEY_PATH?.trim();
    const inlineKey = env.APNS_AUTH_KEY?.trim();
    const bundleId = env.TUBETRACK_UK_APNS_BUNDLE_ID?.trim() || 'dev.skynolimit.TubeTrackUK';

    const environment = env.APNS_USE_SANDBOX === 'true'
        ? 'sandbox'
        : (env.APNS_ENVIRONMENT?.trim() || DEFAULTS.apnsEnvironment);
    if (!APNS_ENVIRONMENTS.includes(environment)) {
        throw new Error(`APNS_ENVIRONMENT must be one of ${APNS_ENVIRONMENTS.join(', ')}`);
    }

    const requestTimeoutMs = positiveInteger(
        env.TUBETRACK_UK_APNS_TIMEOUT_MS,
        DEFAULTS.apnsRequestTimeoutMs,
        'TUBETRACK_UK_APNS_TIMEOUT_MS'
    );

    // A half-configured push setup is a configuration error, not a reason to
    // silently do nothing: someone meant to turn this on.
    const supplied = [keyId, teamId, keyPath || inlineKey].filter(Boolean).length;
    if (supplied > 0 && supplied < 3) {
        throw new Error(
            'Push needs all of APNS_KEY_ID, APNS_TEAM_ID and APNS_AUTH_KEY_PATH '
            + '(or APNS_AUTH_KEY), or none of them'
        );
    }

    return Object.freeze({
        enabled: supplied === 3,
        keyId: keyId ?? null,
        teamId: teamId ?? null,
        keyPath: keyPath ?? null,
        inlineKey: inlineKey ?? null,
        bundleId,
        liveActivityTopic: env.APNS_LIVE_ACTIVITY_TOPIC?.trim()
            || `${bundleId}.push-type.liveactivity`,
        environment,
        requestTimeoutMs,
        dataDir: env.TUBETRACK_UK_DATA_DIR?.trim() || null
    });
}
