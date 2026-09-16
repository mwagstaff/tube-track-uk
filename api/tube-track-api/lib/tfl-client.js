export class TfLRequestError extends Error {
    constructor(message, { code = 'TFL_REQUEST_FAILED', status, cause } = {}) {
        super(message, { cause });
        this.name = 'TfLRequestError';
        this.code = code;
        this.status = status;
    }
}

export class TfLClient {
    constructor({
        apiKey,
        fetchImpl = globalThis.fetch,
        baseUrl = 'https://api.tfl.gov.uk',
        timeoutMs = 10_000,
        maxConcurrentRequests = 8,
        metrics
    }) {
        if (!apiKey) {
            throw new Error('A TfL API key is required');
        }
        if (typeof fetchImpl !== 'function') {
            throw new Error('A fetch implementation is required');
        }
        if (!Number.isSafeInteger(maxConcurrentRequests) || maxConcurrentRequests <= 0) {
            throw new Error('maxConcurrentRequests must be a positive integer');
        }

        this.apiKey = apiKey;
        this.fetchImpl = fetchImpl;
        this.baseUrl = baseUrl;
        this.timeoutMs = timeoutMs;
        this.maxConcurrentRequests = maxConcurrentRequests;
        this.metrics = metrics;
        this.activeRequests = 0;
        this.requestQueue = [];
        this.#reportConcurrency();
    }

    async fetchArrivals(mode, { signal } = {}) {
        const result = await this.fetchJSON(
            `/Mode/${encodeURIComponent(mode)}/Arrivals`,
            {
                query: { count: '-1' },
                metricLabel: `arrivals:${mode}`,
                signal
            }
        );
        if (!Array.isArray(result)) {
            throw new TfLRequestError(
                `TfL arrivals response for ${mode} was not an array`,
                { code: 'TFL_INVALID_RESPONSE' }
            );
        }
        return result;
    }

    async fetchJSON(path, { query = {}, metricLabel = 'other', metricUrl: safeMetricUrl, signal, timeoutMs = this.timeoutMs } = {}) {
        const requestUrl = new URL(path, this.baseUrl);
        for (const [name, value] of Object.entries(query)) {
            if (value !== undefined && value !== null && value !== '') {
                requestUrl.searchParams.set(name, String(value));
            }
        }
        const metricUrl = safeMetricUrl ?? requestUrl.toString();
        requestUrl.searchParams.set('app_key', this.apiKey);

        const release = await this.#acquire(signal);

        const controller = new AbortController();
        let timedOut = false;
        const abortFromCaller = () => controller.abort(signal.reason);
        if (signal?.aborted) {
            abortFromCaller();
        } else {
            signal?.addEventListener('abort', abortFromCaller, { once: true });
        }
        const timeout = setTimeout(() => {
            timedOut = true;
            controller.abort();
        }, timeoutMs);
        timeout.unref?.();

        const startedAt = performance.now();
        let status = 'network_error';
        let responseBytes = 0;

        try {
            const response = await this.fetchImpl(requestUrl, {
                signal: controller.signal,
                headers: {
                    accept: 'application/json',
                    'user-agent': 'tube-track-api/0.1'
                }
            });
            status = String(response.status);
            const body = await response.text();
            responseBytes = Buffer.byteLength(body);

            if (!response.ok) {
                throw new TfLRequestError(
                    `TfL request returned HTTP ${response.status}`,
                    { code: 'TFL_HTTP_ERROR', status: response.status }
                );
            }

            let parsed;
            try {
                parsed = JSON.parse(body);
            } catch (error) {
                throw new TfLRequestError(
                    'TfL response was not valid JSON',
                    { code: 'TFL_INVALID_JSON', status: response.status, cause: error }
                );
            }
            return parsed;
        } catch (error) {
            if (signal?.aborted) {
                status = 'cancelled';
                throw error;
            }
            if (timedOut) {
                status = 'timeout';
                throw new TfLRequestError(
                    'TfL request timed out',
                    { code: 'TFL_TIMEOUT', cause: error }
                );
            }
            if (error instanceof TfLRequestError) {
                throw error;
            }
            throw new TfLRequestError(
                'TfL request failed',
                { cause: error }
            );
        } finally {
            clearTimeout(timeout);
            signal?.removeEventListener('abort', abortFromCaller);
            release();
            try {
                this.metrics?.observeTflRequest?.({
                    source: metricLabel,
                    status,
                    durationSeconds: (performance.now() - startedAt) / 1_000,
                    responseBytes,
                    url: metricUrl
                });
            } catch {
                // Telemetry must never change the outcome of an upstream request.
            }
        }
    }

    #acquire(signal) {
        if (signal?.aborted) {
            return Promise.reject(signal.reason ?? new Error('TfL request cancelled'));
        }
        if (this.activeRequests < this.maxConcurrentRequests) {
            this.activeRequests += 1;
            this.#reportConcurrency();
            return Promise.resolve(this.#releaseFunction());
        }

        return new Promise((resolve, reject) => {
            const entry = { resolve, reject, signal, abort: null };
            entry.abort = () => {
                const index = this.requestQueue.indexOf(entry);
                if (index >= 0) {
                    this.requestQueue.splice(index, 1);
                    this.#reportConcurrency();
                }
                reject(signal.reason ?? new Error('TfL request cancelled'));
            };
            signal?.addEventListener('abort', entry.abort, { once: true });
            this.requestQueue.push(entry);
            this.#reportConcurrency();
        });
    }

    #releaseFunction() {
        let released = false;
        return () => {
            if (released) return;
            released = true;
            this.activeRequests -= 1;

            while (this.requestQueue.length > 0) {
                const entry = this.requestQueue.shift();
                entry.signal?.removeEventListener('abort', entry.abort);
                if (entry.signal?.aborted) {
                    entry.reject(entry.signal.reason ?? new Error('TfL request cancelled'));
                    continue;
                }
                this.activeRequests += 1;
                entry.resolve(this.#releaseFunction());
                break;
            }
            this.#reportConcurrency();
        };
    }

    #reportConcurrency() {
        try {
            this.metrics?.setTflRequestQueueDepth?.(this.requestQueue.length);
            this.metrics?.setTflRequestsInFlight?.(this.activeRequests);
        } catch {
            // Telemetry must never prevent requests from entering or leaving the gate.
        }
    }
}
