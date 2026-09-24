import assert from 'node:assert/strict';
import test from 'node:test';

import { createMetrics } from '../lib/metrics.js';

test('exports TfL request, timeout, queue, age, latency, URL, and payload metrics', async () => {
    let nowMs = 1_800_000_000_000;
    const metrics = createMetrics({
        collectProcessMetrics: false,
        clock: () => nowMs
    });

    metrics.setTflRequestQueueDepth(2);
    metrics.setTflRequestsInFlight(3);
    metrics.observeTflRequest({
        source: 'status',
        status: '200',
        durationSeconds: 0.25,
        responseBytes: 12_345,
        url: 'https://api.tfl.gov.uk/Line/Mode/tube/Status?detail=true'
    });
    nowMs += 1_000;
    metrics.observeTflRequest({
        source: 'arrivals:tube',
        status: 'timeout',
        durationSeconds: 10,
        responseBytes: 0,
        url: 'https://api.tfl.gov.uk/Mode/tube/Arrivals?count=-1'
    });

    const output = await metrics.render();

    assert.match(output, /tube_track_tfl_requests_total\{[^}]*source="status"[^}]*status="200"[^}]*\} 1/);
    assert.match(output, /tube_track_tfl_timeouts_total\{[^}]*source="arrivals:tube"[^}]*\} 1/);
    assert.match(output, /tube_track_tfl_request_queue_depth\{service_name="tube-track-api"\} 2/);
    assert.match(output, /tube_track_tfl_requests_in_flight\{service_name="tube-track-api"\} 3/);
    assert.match(output, /tube_track_tfl_last_success_timestamp_seconds\{service_name="tube-track-api"\} 1800000000/);
    assert.match(output, /tube_track_tfl_top_url_requests\{[^}]*url="https:\/\/api\.tfl\.gov\.uk\/Line\/Mode\/tube\/Status\?detail=true"[^}]*\} 1/);
    assert.match(output, /tube_track_tfl_timeout_url_requests\{[^}]*status="timeout"[^}]*\} 1/);
    assert.match(output, /tube_track_tfl_slow_url_p95_seconds\{/);
    assert.match(output, /tube_track_tfl_large_url_p95_response_bytes\{/);
    assert.doesNotMatch(output, /app_key/);
});

test('a routed request keeps its own label instead of becoming unmatched', async () => {
    const metrics = createMetrics({ collectProcessMetrics: false });
    const middleware = metrics.middleware();

    // Express rewrites req.url relative to a router's mount point while the
    // request is in flight, so the label has to be taken on the way in.
    const req = { method: 'POST', path: '/api/v1/push/live-activities' };
    const listeners = [];
    const res = { statusCode: 201, on: (event, handler) => listeners.push([event, handler]) };

    middleware(req, res, () => {});
    req.path = '/live-activities';
    for (const [event, handler] of listeners) {
        if (event === 'finish') handler();
    }

    const rendered = await metrics.render();
    assert.match(rendered, /route="\/api\/v1\/push\/live-activities"/);
    assert.doesNotMatch(rendered, /route="unmatched"/);
});

test('push metrics cover sends, changes, suppressions and token counts', async () => {
    const metrics = createMetrics({ collectProcessMetrics: false });

    metrics.recordPushSent({ type: 'liveActivity', result: 'ok' });
    metrics.recordPushSent({ type: 'liveActivity', result: 'dead' });
    metrics.observePushDuration({ type: 'liveActivity', durationSeconds: 0.12 });
    metrics.setPushTokens({ liveActivity: 3, widget: 2 });
    metrics.recordChangeDetected({ reason: 'lead_departure' });
    metrics.recordPushSuppressed({ reason: 'heartbeat' });
    metrics.recordPushAuthFailure();
    metrics.recordPushStoreWriteFailure();

    const rendered = await metrics.render();
    assert.match(rendered, /tube_track_push_sent_total\{[^}]*result="ok"[^}]*\} 1/);
    assert.match(rendered, /tube_track_push_sent_total\{[^}]*result="dead"[^}]*\} 1/);
    assert.match(rendered, /tube_track_push_tokens\{[^}]*type="liveActivity"[^}]*\} 3/);
    assert.match(rendered, /tube_track_push_tokens\{[^}]*type="widget"[^}]*\} 2/);
    assert.match(rendered, /tube_track_push_changes_detected_total\{[^}]*reason="lead_departure"[^}]*\} 1/);
    assert.match(rendered, /tube_track_push_suppressed_total\{[^}]*reason="heartbeat"[^}]*\} 1/);
    assert.match(rendered, /tube_track_push_auth_failures_total\{[^}]*\} 1/);
    assert.match(rendered, /tube_track_push_store_write_failures_total\{[^}]*\} 1/);
});

test('every alert rule names a metric the service actually exports', async () => {
    const { readFile } = await import('node:fs/promises');
    const rules = await readFile(
        new URL('../observability/prometheus/rules.yml', import.meta.url),
        'utf8'
    );
    const metrics = createMetrics({ collectProcessMetrics: false });
    metrics.recordPushSent({ type: 'liveActivity', result: 'ok' });
    metrics.recordPushSuppressed({ reason: 'heartbeat' });
    metrics.recordPushStoreWriteFailure();
    const rendered = await metrics.render();

    const referenced = new Set(rules.match(/tube_track_[a-z_]+/g) ?? []);
    for (const name of referenced) {
        assert.ok(
            rendered.includes(name),
            `${name} is alerted on but never exported — the alert can never fire`
        );
    }
});
