import crypto from 'node:crypto';
import fs from 'node:fs';
import http2 from 'node:http2';

// Apple re-mints provider tokens no more often than every 20 minutes and
// rejects any older than 60. 55 leaves room for a slow request.
const TOKEN_LIFETIME_MS = 55 * 60 * 1_000;
const HOSTS = Object.freeze({
    sandbox: 'https://api.sandbox.push.apple.com:443',
    production: 'https://api.push.apple.com:443'
});

// Reasons that mean the token is gone for good. Retrying any of these wastes a
// request and keeps a dead row in the store forever.
const DEAD_TOKEN_REASONS = new Set([
    'BadDeviceToken',
    'Unregistered',
    'DeviceTokenNotForTopic',
    'ExpiredToken'
]);

export class ApnsError extends Error {
    constructor(message, { status, reason, retryable, dead } = {}) {
        super(message);
        this.name = 'ApnsError';
        this.status = status ?? null;
        this.reason = reason ?? null;
        this.retryable = retryable === true;
        this.dead = dead === true;
    }
}

export function isDeadTokenResponse({ status, reason }) {
    return status === 410 || DEAD_TOKEN_REASONS.has(String(reason));
}

function base64url(input) {
    return Buffer.from(input)
        .toString('base64')
        .replace(/=/g, '')
        .replace(/\+/g, '-')
        .replace(/\//g, '_');
}

/**
 * ES256 provider tokens, signed the way RFC 7515 specifies.
 *
 * `crypto.sign` defaults to ASN.1 DER for EC keys; JOSE wants the raw r||s pair
 * (64 bytes for P-256), which is what `dsaEncoding: 'ieee-p1363'` produces.
 * APNs sandbox was measured accepting both — a DER-signed token comes back
 * BadDeviceToken rather than InvalidProviderToken — but only one of them is
 * what the spec asks for, and relying on a lenient parser is not a plan.
 */
export class ApnsTokenSigner {
    #privateKey;
    #cached = null;

    constructor({ keyId, teamId, privateKey, clock = Date.now }) {
        if (!keyId) throw new Error('APNs key id is required');
        if (!teamId) throw new Error('APNs team id is required');
        if (!privateKey) throw new Error('APNs private key is required');
        this.keyId = keyId;
        this.teamId = teamId;
        this.#privateKey = privateKey;
        this.clock = clock;
    }

    static fromKeyPath({ keyPath, ...rest }) {
        return new ApnsTokenSigner({ privateKey: fs.readFileSync(keyPath, 'utf8'), ...rest });
    }

    token() {
        const now = this.clock();
        if (this.#cached && now - this.#cached.issuedAtMs < TOKEN_LIFETIME_MS) {
            return this.#cached.value;
        }

        const header = base64url(
            JSON.stringify({ alg: 'ES256', kid: this.keyId, typ: 'JWT' })
        );
        const payload = base64url(
            JSON.stringify({ iss: this.teamId, iat: Math.floor(now / 1_000) })
        );
        const signingInput = `${header}.${payload}`;
        const signature = crypto.sign('sha256', Buffer.from(signingInput), {
            key: this.#privateKey,
            dsaEncoding: 'ieee-p1363'
        });

        const value = `${signingInput}.${base64url(signature)}`;
        this.#cached = { value, issuedAtMs: now };
        return value;
    }
}

/**
 * One HTTP/2 session per APNs host, reused across sends.
 *
 * A new TLS session per push is the single most expensive thing a naive APNs
 * client does. The session is re-established lazily whenever it goes away, so
 * callers never have to think about connection state.
 */
export class ApnsClient {
    #sessions = new Map();

    constructor({
        signer,
        environment = 'production',
        requestTimeoutMs = 10_000,
        logger,
        metrics,
        connect = http2.connect
    }) {
        this.signer = signer;
        this.environment = environment;
        this.requestTimeoutMs = requestTimeoutMs;
        this.logger = logger;
        this.metrics = metrics;
        this.connect = connect;
    }

    get host() {
        return HOSTS[this.environment] ?? HOSTS.production;
    }

    #session(environment) {
        const host = HOSTS[environment];
        if (!host) throw new Error('Unknown APNs environment');
        const existing = this.#sessions.get(host);
        if (existing && !existing.closed && !existing.destroyed) {
            return existing;
        }

        const session = this.connect(host);
        session.setTimeout?.(5 * 60 * 1_000, () => session.close());
        session.on('error', (error) => {
            this.logger?.warn('apns_session_error', { error: error.message, host });
            if (this.#sessions.get(host) === session) this.#sessions.delete(host);
        });
        session.on('close', () => {
            if (this.#sessions.get(host) === session) {
                this.#sessions.delete(host);
            }
        });
        session.unref?.();
        this.#sessions.set(host, session);
        return session;
    }

    /**
     * Sends one notification. Resolves `{ status, reason, apnsId, dead }` for
     * anything APNs answered, and rejects only when the request never completed.
     */
    send({ token, topic, pushType, priority = 5, expiration, payload, collapseId, environment = this.environment }) {
        if (!token) throw new Error('A device token is required');
        if (!topic) throw new Error('An APNs topic is required');

        const body = Buffer.from(JSON.stringify(payload));
        const headers = {
            ':method': 'POST',
            ':path': `/3/device/${token}`,
            authorization: `bearer ${this.signer.token()}`,
            'apns-topic': topic,
            'apns-push-type': pushType,
            'apns-priority': String(priority),
            'content-length': String(body.byteLength)
        };
        if (expiration !== undefined) headers['apns-expiration'] = String(expiration);
        if (collapseId) headers['apns-collapse-id'] = collapseId;

        return new Promise((resolve, reject) => {
            let request;
            try {
                request = this.#session(environment).request(headers);
            } catch (error) {
                reject(new ApnsError(error.message, { retryable: true }));
                return;
            }

            let status = null;
            let apnsId = null;
            let raw = '';
            let settled = false;
            const settle = (fn, value) => {
                if (settled) return;
                settled = true;
                fn(value);
            };

            request.on('response', (responseHeaders) => {
                status = responseHeaders[':status'];
                apnsId = responseHeaders['apns-id'] ?? null;
            });
            request.setEncoding('utf8');
            request.on('data', (chunk) => {
                raw += chunk;
            });
            request.on('error', (error) => {
                settle(reject, new ApnsError(error.message, { retryable: true }));
            });
            request.setTimeout(this.requestTimeoutMs, () => {
                request.close(http2.constants.NGHTTP2_CANCEL);
                settle(reject, new ApnsError('APNs request timed out', { retryable: true }));
            });
            request.on('end', () => {
                let reason = null;
                if (raw) {
                    try {
                        reason = JSON.parse(raw).reason ?? null;
                    } catch {
                        reason = raw.slice(0, 200);
                    }
                }
                settle(resolve, {
                    status,
                    reason,
                    apnsId,
                    ok: status === 200,
                    dead: isDeadTokenResponse({ status, reason }),
                    // 429 and 5xx are Apple asking for patience, not a verdict.
                    retryable: status === 429 || (typeof status === 'number' && status >= 500)
                });
            });

            request.end(body);
        });
    }

    close() {
        for (const session of this.#sessions.values()) {
            session.close?.();
        }
        this.#sessions.clear();
    }
}

/**
 * The Live Activity payload APNs expects.
 *
 * `content-state` lives *inside* `aps`, and `timestamp`/`stale-date` are epoch
 * seconds — both are easy to get wrong and both fail silently, leaving an
 * activity that never updates and no error to explain why.
 */
export function liveActivityPayload({
    event = 'update',
    contentState,
    timestampSeconds,
    staleDateSeconds,
    dismissalDateSeconds,
    relevanceScore
}) {
    const aps = {
        timestamp: timestampSeconds,
        event,
        'content-state': contentState
    };
    if (staleDateSeconds !== undefined) aps['stale-date'] = staleDateSeconds;
    if (dismissalDateSeconds !== undefined) aps['dismissal-date'] = dismissalDateSeconds;
    if (relevanceScore !== undefined) aps['relevance-score'] = relevanceScore;
    return { aps };
}
