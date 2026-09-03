import {
    Counter,
    Gauge,
    Histogram,
    Registry,
    collectDefaultMetrics
} from 'prom-client';

const TFL_RECENT_WINDOW_MS = 6 * 60 * 60 * 1_000;
const TFL_RECENT_REQUEST_LIMIT = 100_000;
const TFL_TOP_URL_LIMIT = 100;
const TFL_TOP_MAX_LIMIT = 20;

function percentile(sortedValues, quantile) {
    if (sortedValues.length === 0) return 0;
    const index = Math.min(
        sortedValues.length - 1,
        Math.max(0, Math.ceil(quantile * sortedValues.length) - 1)
    );
    return sortedValues[index];
}

function createRecentTflRequests({ clock = Date.now } = {}) {
    let observations = [];
    let cachedRows = null;
    let cachedAtMs = 0;

    function prune(nowMs = clock()) {
        const cutoffMs = nowMs - TFL_RECENT_WINDOW_MS;
        let firstCurrentIndex = 0;
        while (
            firstCurrentIndex < observations.length
            && observations[firstCurrentIndex].timestampMs < cutoffMs
        ) {
            firstCurrentIndex += 1;
        }
        if (firstCurrentIndex > 0) {
            observations = observations.slice(firstCurrentIndex);
        }
        if (observations.length > TFL_RECENT_REQUEST_LIMIT) {
            observations = observations.slice(-TFL_RECENT_REQUEST_LIMIT);
        }
    }

    return {
        add(observation) {
            observations.push(observation);
            cachedRows = null;
            prune(observation.timestampMs);
        },
        rows(nowMs = clock()) {
            if (cachedRows && nowMs - cachedAtMs < 1_000) {
                return cachedRows.slice();
            }
            prune(nowMs);
            const grouped = new Map();
            for (const observation of observations) {
                const labels = {
                    source: observation.source,
                    status: observation.status,
                    url: observation.url
                };
                const key = JSON.stringify(labels);
                let row = grouped.get(key);
                if (!row) {
                    row = {
                        labels,
                        count: 0,
                        timeoutCount: 0,
                        durations: [],
                        responseBytes: [],
                        maxDurationSeconds: 0,
                        maxDurationTimestampSeconds: 0,
                        maxResponseBytes: 0,
                        maxResponseTimestampSeconds: 0
                    };
                    grouped.set(key, row);
                }
                row.count += 1;
                if (observation.status === 'timeout') row.timeoutCount += 1;
                row.durations.push(observation.durationSeconds);
                if (observation.responseBytes > 0) {
                    row.responseBytes.push(observation.responseBytes);
                }
                if (observation.durationSeconds >= row.maxDurationSeconds) {
                    row.maxDurationSeconds = observation.durationSeconds;
                    row.maxDurationTimestampSeconds = observation.timestampMs / 1_000;
                }
                if (observation.responseBytes >= row.maxResponseBytes) {
                    row.maxResponseBytes = observation.responseBytes;
                    row.maxResponseTimestampSeconds = observation.timestampMs / 1_000;
                }
            }

            cachedRows = [...grouped.values()].map((row) => {
                row.durations.sort((left, right) => left - right);
                row.responseBytes.sort((left, right) => left - right);
                return {
                    ...row,
                    p95DurationSeconds: percentile(row.durations, 0.95),
                    p95ResponseBytes: percentile(row.responseBytes, 0.95)
                };
            });
            cachedAtMs = nowMs;
            return cachedRows.slice();
        }
    };
}

function rollingGauge({ register, name, help, labelNames, rows }) {
    return new Gauge({
        name,
        help,
        labelNames,
        collect() {
            this.reset();
            for (const row of rows()) {
                this.set(row.labels, row.value);
            }
        },
        registers: [register]
    });
}

function requestRoute(req) {
    if (req.path === '/api/v1/live') return '/api/v1/live';
    if (req.path === '/api/v1/status') return '/api/v1/status';
    if (req.path === '/api/v1/planned-works') return '/api/v1/planned-works';
    if (req.path === '/api/v1/arrivals') return '/api/v1/arrivals';
    if (req.path.startsWith('/api/v1/arrivals/')) return '/api/v1/arrivals/:stopId';
    if (req.path.startsWith('/api/v1/arrival-departures/')) {
        return '/api/v1/arrival-departures/:stopId';
    }
    if (req.path.startsWith('/api/v1/timetables/')) {
        return '/api/v1/timetables/:lineId/:stopId';
    }
    if (req.path === '/healthcheck') return '/healthcheck';
    if (req.path === '/metrics') return '/metrics';
    return 'unmatched';
}

export function createMetrics({
    cache,
    collectProcessMetrics = true,
    clock = Date.now
} = {}) {
    const register = new Registry();
    register.setDefaultLabels({ service_name: 'tube-track-api' });
    if (collectProcessMetrics) {
        collectDefaultMetrics({
            register,
            prefix: 'tube_track_'
        });
    }

    const inboundRequests = new Counter({
        name: 'tube_track_http_requests_total',
        help: 'Inbound HTTP requests handled by TubeTrack API',
        labelNames: ['method', 'route', 'status'],
        registers: [register]
    });
    const inboundDuration = new Histogram({
        name: 'tube_track_http_request_duration_seconds',
        help: 'Inbound HTTP request duration',
        labelNames: ['method', 'route', 'status'],
        buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
        registers: [register]
    });
    const tflRequests = new Counter({
        name: 'tube_track_tfl_requests_total',
        help: 'TfL upstream requests',
        labelNames: ['source', 'status'],
        registers: [register]
    });
    const tflDuration = new Histogram({
        name: 'tube_track_tfl_request_duration_seconds',
        help: 'TfL upstream request duration',
        labelNames: ['source', 'status'],
        buckets: [0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30],
        registers: [register]
    });
    const tflResponseBytes = new Histogram({
        name: 'tube_track_tfl_response_bytes',
        help: 'Uncompressed TfL response size',
        labelNames: ['source', 'status'],
        buckets: [1e3, 5e3, 1e4, 5e4, 1e5, 2.5e5, 5e5, 1e6, 2.5e6, 5e6, 10e6],
        registers: [register]
    });
    const tflTimeouts = new Counter({
        name: 'tube_track_tfl_timeouts_total',
        help: 'TfL upstream requests that timed out',
        labelNames: ['source'],
        registers: [register]
    });
    const tflRequestQueueDepth = new Gauge({
        name: 'tube_track_tfl_request_queue_depth',
        help: 'TfL requests waiting for an HTTP concurrency slot',
        registers: [register]
    });
    const tflRequestsInFlight = new Gauge({
        name: 'tube_track_tfl_requests_in_flight',
        help: 'TfL requests currently occupying an HTTP concurrency slot',
        registers: [register]
    });
    const tflLastSuccess = new Gauge({
        name: 'tube_track_tfl_last_success_timestamp_seconds',
        help: 'Unix timestamp of the most recent successful TfL request',
        registers: [register]
    });
    const recentTflRequests = createRecentTflRequests({ clock });

    const topUrlLabels = ['source', 'status', 'url'];
    rollingGauge({
        register,
        name: 'tube_track_tfl_top_url_requests',
        help: 'Requests observed for top TfL URL rows over the six-hour process rolling window',
        labelNames: topUrlLabels,
        rows: () => recentTflRequests.rows()
            .sort((left, right) => right.count - left.count)
            .slice(0, TFL_TOP_URL_LIMIT)
            .map((row) => ({ labels: row.labels, value: row.count }))
    });
    rollingGauge({
        register,
        name: 'tube_track_tfl_timeout_url_requests',
        help: 'Timeouts observed for top TfL URL rows over the six-hour process rolling window',
        labelNames: topUrlLabels,
        rows: () => recentTflRequests.rows()
            .filter((row) => row.timeoutCount > 0)
            .sort((left, right) => right.timeoutCount - left.timeoutCount)
            .slice(0, TFL_TOP_URL_LIMIT)
            .map((row) => ({ labels: row.labels, value: row.timeoutCount }))
    });
    rollingGauge({
        register,
        name: 'tube_track_tfl_slow_url_p95_seconds',
        help: 'TfL URL p95 durations over the six-hour process rolling window',
        labelNames: topUrlLabels,
        rows: () => recentTflRequests.rows()
            .sort((left, right) => right.p95DurationSeconds - left.p95DurationSeconds)
            .slice(0, TFL_TOP_URL_LIMIT)
            .map((row) => ({ labels: row.labels, value: row.p95DurationSeconds }))
    });
    rollingGauge({
        register,
        name: 'tube_track_tfl_slow_url_max_seconds',
        help: 'TfL URL maximum durations over the six-hour process rolling window',
        labelNames: topUrlLabels,
        rows: () => recentTflRequests.rows()
            .sort((left, right) => right.maxDurationSeconds - left.maxDurationSeconds)
            .slice(0, TFL_TOP_MAX_LIMIT)
            .map((row) => ({ labels: row.labels, value: row.maxDurationSeconds }))
    });
    rollingGauge({
        register,
        name: 'tube_track_tfl_slow_url_max_timestamp_seconds',
        help: 'Timestamp of the maximum duration for top TfL URL rows',
        labelNames: topUrlLabels,
        rows: () => recentTflRequests.rows()
            .sort((left, right) => right.maxDurationSeconds - left.maxDurationSeconds)
            .slice(0, TFL_TOP_MAX_LIMIT)
            .map((row) => ({ labels: row.labels, value: row.maxDurationTimestampSeconds }))
    });
    rollingGauge({
        register,
        name: 'tube_track_tfl_large_url_p95_response_bytes',
        help: 'TfL URL p95 response payload bytes over the six-hour process rolling window',
        labelNames: topUrlLabels,
        rows: () => recentTflRequests.rows()
            .filter((row) => row.responseBytes.length > 0)
            .sort((left, right) => right.p95ResponseBytes - left.p95ResponseBytes)
            .slice(0, TFL_TOP_URL_LIMIT)
            .map((row) => ({ labels: row.labels, value: row.p95ResponseBytes }))
    });
    rollingGauge({
        register,
        name: 'tube_track_tfl_large_url_max_response_bytes',
        help: 'TfL URL maximum response payload bytes over the six-hour process rolling window',
        labelNames: topUrlLabels,
        rows: () => recentTflRequests.rows()
            .filter((row) => row.responseBytes.length > 0)
            .sort((left, right) => right.maxResponseBytes - left.maxResponseBytes)
            .slice(0, TFL_TOP_MAX_LIMIT)
            .map((row) => ({ labels: row.labels, value: row.maxResponseBytes }))
    });
    rollingGauge({
        register,
        name: 'tube_track_tfl_large_url_max_response_timestamp_seconds',
        help: 'Timestamp of the maximum response payload for top TfL URL rows',
        labelNames: topUrlLabels,
        rows: () => recentTflRequests.rows()
            .filter((row) => row.responseBytes.length > 0)
            .sort((left, right) => right.maxResponseBytes - left.maxResponseBytes)
            .slice(0, TFL_TOP_MAX_LIMIT)
            .map((row) => ({ labels: row.labels, value: row.maxResponseTimestampSeconds }))
    });
    const refreshes = new Counter({
        name: 'tube_track_live_refreshes_total',
        help: 'Live cache refresh attempts',
        labelNames: ['status'],
        registers: [register]
    });
    const refreshDuration = new Histogram({
        name: 'tube_track_live_refresh_duration_seconds',
        help: 'Duration of a complete live cache refresh',
        labelNames: ['status'],
        buckets: [0.5, 1, 2.5, 5, 10, 20, 30, 60],
        registers: [register]
    });
    const cacheItems = new Gauge({
        name: 'tube_track_live_cache_items',
        help: 'Number of normalised arrivals in the current cache',
        registers: [register]
    });
    const cacheUpdated = new Gauge({
        name: 'tube_track_live_cache_updated_timestamp_seconds',
        help: 'Unix timestamp of the most recent successful live cache refresh',
        registers: [register]
    });
    const cacheAge = new Gauge({
        name: 'tube_track_live_cache_age_seconds',
        help: 'Age of the current live cache',
        collect() {
            const state = cache?.read();
            this.set(state ? state.ageMs / 1_000 : 0);
        },
        registers: [register]
    });

    return Object.freeze({
        middleware() {
            return (req, res, next) => {
                const startedAt = performance.now();
                res.on('finish', () => {
                    const labels = {
                        method: req.method,
                        route: requestRoute(req),
                        status: String(res.statusCode)
                    };
                    inboundRequests.inc(labels);
                    inboundDuration.observe(labels, (performance.now() - startedAt) / 1_000);
                });
                next();
            };
        },
        observeTflRequest({ source, mode, status, durationSeconds, responseBytes, url }) {
            const normalizedSource = String(source ?? mode ?? 'other');
            const labels = { source: normalizedSource, status: String(status) };
            tflRequests.inc(labels);
            tflDuration.observe(labels, durationSeconds);
            if (responseBytes > 0) {
                tflResponseBytes.observe(labels, responseBytes);
            }
            if (status === 'timeout') {
                tflTimeouts.inc({ source: normalizedSource });
            }
            if (/^[1-3][0-9][0-9]$/.test(String(status))) {
                tflLastSuccess.set(clock() / 1_000);
            }
            if (url) {
                recentTflRequests.add({
                    source: normalizedSource,
                    status: String(status),
                    url: String(url),
                    durationSeconds,
                    responseBytes,
                    timestampMs: clock()
                });
            }
        },
        setTflRequestQueueDepth(value) {
            tflRequestQueueDepth.set(value);
        },
        setTflRequestsInFlight(value) {
            tflRequestsInFlight.set(value);
        },
        observeRefresh({ status, durationSeconds }) {
            refreshes.inc({ status });
            refreshDuration.observe({ status }, durationSeconds);
        },
        setCache({ itemCount, updatedAtMs }) {
            cacheItems.set(itemCount);
            cacheUpdated.set(updatedAtMs / 1_000);
        },
        get contentType() {
            return register.contentType;
        },
        render: () => register.metrics(),
        register,
        cacheAge
    });
}
