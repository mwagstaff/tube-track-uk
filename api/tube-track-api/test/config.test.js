import assert from 'node:assert/strict';
import test from 'node:test';

import { LIVE_MODES, loadConfig, loadPushConfig } from '../lib/config.js';

test('requires the server-side TfL key', () => {
    assert.throws(
        () => loadConfig({}),
        /TUBETRACK_UK_TFL_UNIFIED_API_KEY is required/
    );
});

test('loads safe defaults and all supported modes', () => {
    const config = loadConfig({
        TUBETRACK_UK_TFL_UNIFIED_API_KEY: 'test-key'
    });

    assert.equal(config.port, 3018);
    assert.equal(config.pollIntervalMs, 30_000);
    assert.equal(config.maxConcurrentRequests, 8);
    assert.equal(config.refreshTimeoutMs, 120_000);
    assert.equal(
        loadConfig({ ...{ TUBETRACK_UK_TFL_UNIFIED_API_KEY: 'test-key' }, TUBETRACK_UK_LIVE_REFRESH_TIMEOUT_MS: '45000' }).refreshTimeoutMs,
        45_000
    );
    assert.deepEqual(LIVE_MODES, [
        'tube',
        'dlr',
        'overground',
        'tram',
        'elizabeth-line'
    ]);
});

test('rejects invalid timing and port configuration', () => {
    const base = { TUBETRACK_UK_TFL_UNIFIED_API_KEY: 'test-key' };
    assert.throws(() => loadConfig({ ...base, PORT: '70000' }), /PORT/);
    assert.throws(
        () => loadConfig({
            ...base,
            TUBETRACK_UK_LIVE_POLL_INTERVAL_MS: '30000',
            TUBETRACK_UK_REQUEST_STAGGER_MS: '8000'
        }),
        /staggering/
    );
    assert.throws(
        () => loadConfig({
            ...base,
            TUBETRACK_UK_LIVE_STALE_AFTER_MS: '1000'
        }),
        /stale threshold/
    );
    assert.throws(
        () => loadConfig({
            ...base,
            TUBETRACK_UK_TFL_MAX_CONCURRENT_REQUESTS: '0'
        }),
        /MAX_CONCURRENT_REQUESTS/
    );
    assert.throws(
        () => loadConfig({
            ...base,
            TUBETRACK_UK_TFL_TIMEOUT_MS: '10000',
            TUBETRACK_UK_LIVE_REFRESH_TIMEOUT_MS: '10000'
        }),
        /refresh timeout/
    );
});

test('push stays off, and harmless, when APNs is not configured', () => {
    const push = loadPushConfig({});
    assert.equal(push.enabled, false);
    assert.equal(push.liveActivityTopic, 'dev.skynolimit.TubeTrackUK.push-type.liveactivity');
});

test('a half-configured push setup is an error, not a silent no-op', () => {
    assert.throws(
        () => loadPushConfig({ APNS_KEY_ID: 'K', APNS_TEAM_ID: 'T' }),
        /Push needs all of/
    );
});

test('push turns on once every credential is present', () => {
    const push = loadPushConfig({
        APNS_KEY_ID: 'KEY123456',
        APNS_TEAM_ID: 'SJ8X4DLAN9',
        APNS_AUTH_KEY_PATH: '/home/someone/.certs/AuthKey.p8'
    });
    assert.equal(push.enabled, true);
    assert.equal(push.environment, 'production');
    assert.equal(push.keyPath, '/home/someone/.certs/AuthKey.p8');
});

test('the sandbox is opt-in and validated', () => {
    const credentials = {
        APNS_KEY_ID: 'KEY123456',
        APNS_TEAM_ID: 'SJ8X4DLAN9',
        APNS_AUTH_KEY: '-----BEGIN PRIVATE KEY-----'
    };
    assert.equal(loadPushConfig({ ...credentials, APNS_USE_SANDBOX: 'true' }).environment, 'sandbox');
    assert.equal(loadPushConfig({ ...credentials, APNS_ENVIRONMENT: 'sandbox' }).environment, 'sandbox');
    assert.throws(
        () => loadPushConfig({ ...credentials, APNS_ENVIRONMENT: 'staging' }),
        /APNS_ENVIRONMENT must be one of/
    );
});
