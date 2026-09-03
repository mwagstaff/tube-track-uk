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
