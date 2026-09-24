import crypto from 'node:crypto';
import express from 'express';
import { DIRECTION_FILTERS } from './push/departure-projection.js';
import { LINE_COLOURS } from './line-colours.js';

const LINE_IDS = new Set(LINE_COLOURS.map((line) => line.id));

// These are the service's first write endpoints, so they carry their own
// limits rather than inheriting anything permissive from the read side.
const BODY_LIMIT = '4kb';
const MAX_STOP_IDS = 12;
const TOKEN_PATTERN = /^[0-9a-fA-F]{64,200}$/;
const ID_PATTERN = /^[0-9A-Za-z-]{8,64}$/;

// Per install, not per IP: every request arrives through the same Cloudflare
// tunnel, so an IP bucket would either throttle everybody at once or nobody.
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX_REQUESTS = 30;
const RATE_LIMIT_MAX_KEYS = 10_000;

function badRequest(res, code, message) {
    res.status(400).json({ error: { code, message } });
}

/** Constant-time compare that cannot leak the secret's length either. */
export function secretMatches(provided, expected) {
    if (typeof provided !== 'string' || typeof expected !== 'string' || expected.length === 0) {
        return false;
    }
    const providedHash = crypto.createHash('sha256').update(provided).digest();
    const expectedHash = crypto.createHash('sha256').update(expected).digest();
    return crypto.timingSafeEqual(providedHash, expectedHash);
}

export function createRateLimiter({
    windowMs = RATE_LIMIT_WINDOW_MS,
    maxRequests = RATE_LIMIT_MAX_REQUESTS,
    maxKeys = RATE_LIMIT_MAX_KEYS,
    clock = Date.now
} = {}) {
    const buckets = new Map();

    return function allow(key) {
        const now = clock();
        const bucket = buckets.get(key);
        if (!bucket || now - bucket.startedAtMs >= windowMs) {
            buckets.delete(key);
            buckets.set(key, { startedAtMs: now, count: 1 });
            while (buckets.size > maxKeys) {
                buckets.delete(buckets.keys().next().value);
            }
            return true;
        }
        bucket.count += 1;
        return bucket.count <= maxRequests;
    };
}

function readStopIds(value, isKnownStop) {
    if (!Array.isArray(value) || value.length === 0 || value.length > MAX_STOP_IDS) {
        return null;
    }
    const stopIds = [...new Set(value.map((id) => String(id)))];
    return stopIds.every(isKnownStop) ? stopIds : null;
}

/**
 * Registration endpoints for push subscriptions.
 *
 * The shared secret here is obfuscation, not authentication: it ships inside
 * the app, so anyone who unpacks the binary has it. It raises the cost of
 * casual abuse and nothing more — what actually bounds the damage is the rate
 * limiter, the entry cap in the token store, and the fact that a subscription
 * can only ever cause a push to a device token its owner supplied. App Attest
 * is the real fix and belongs in its own change.
 */
export function createPushRoutes({
    store,
    clientSecret,
    isKnownStop = () => true,
    logger,
    metrics,
    clock = Date.now,
    rateLimiter = createRateLimiter({ clock })
}) {
    const router = express.Router();

    router.use(express.json({ limit: BODY_LIMIT }));

    router.use((error, req, res, next) => {
        if (error?.type === 'entity.too.large') {
            badRequest(res, 'PAYLOAD_TOO_LARGE', 'Request body is too large');
            return;
        }
        if (error instanceof SyntaxError) {
            badRequest(res, 'INVALID_JSON', 'Request body must be JSON');
            return;
        }
        next(error);
    });

    router.use((req, res, next) => {
        const header = req.get('authorization') ?? '';
        const provided = header.startsWith('Bearer ') ? header.slice(7) : req.get('x-tubetrack-key');
        if (!secretMatches(provided, clientSecret)) {
            metrics?.recordPushAuthFailure?.();
            res.status(401).json({
                error: { code: 'UNAUTHORIZED', message: 'A valid client key is required' }
            });
            return;
        }
        next();
    });

    router.use((req, res, next) => {
        const installId = req.get('x-tubetrack-install');
        if (!installId || !ID_PATTERN.test(installId)) {
            badRequest(res, 'INVALID_INSTALL_ID', 'x-tubetrack-install must identify the app install');
            return;
        }
        if (!rateLimiter(installId)) {
            res.status(429).json({
                error: { code: 'RATE_LIMITED', message: 'Too many registration requests' }
            });
            return;
        }
        req.installId = installId;
        next();
    });

    router.post('/live-activities', (req, res) => {
        const body = req.body ?? {};
        const { activityId, token, lineId, direction, hubId } = body;

        if (!ID_PATTERN.test(String(activityId ?? ''))) {
            return badRequest(res, 'INVALID_ACTIVITY_ID', 'activityId is required');
        }
        if (!TOKEN_PATTERN.test(String(token ?? ''))) {
            return badRequest(res, 'INVALID_TOKEN', 'token must be a hex APNs token');
        }
        if (!LINE_IDS.has(String(lineId))) {
            return badRequest(res, 'INVALID_LINE', 'lineId must be a line TubeTrack serves');
        }
        if (!DIRECTION_FILTERS.includes(String(direction ?? 'any'))) {
            return badRequest(res, 'INVALID_DIRECTION', 'direction must be a known filter');
        }
        const stopIds = readStopIds(body.stopIds, isKnownStop);
        if (!stopIds) {
            return badRequest(res, 'INVALID_STOP_IDS', 'stopIds must name stops TubeTrack knows');
        }

        // Namespaced by install, so one app cannot overwrite another's
        // subscription by guessing an activity id.
        const id = `${req.installId}:${activityId}`;
        store.upsert({
            id,
            type: 'liveActivity',
            token: String(token).toLowerCase(),
            installId: req.installId,
            activityId: String(activityId),
            hubId: hubId === undefined ? null : String(hubId).slice(0, 64),
            stopIds,
            lineId: String(lineId),
            direction: String(direction ?? 'any'),
            frequentPushesEnabled: body.frequentPushesEnabled !== false,
            startedAtMs: clock()
        });
        logger?.info('push_subscription_registered', { id, lineId, direction });
        metrics?.setPushTokens?.(store.countByType());

        return res.status(201).json({ data: { id } });
    });

    router.patch('/live-activities/:activityId', (req, res) => {
        const id = `${req.installId}:${req.params.activityId}`;
        if (!store.get(id)) {
            return res.status(404).json({
                error: { code: 'NOT_FOUND', message: 'No such subscription' }
            });
        }

        const patch = {};
        if (req.body?.token !== undefined) {
            if (!TOKEN_PATTERN.test(String(req.body.token))) {
                return badRequest(res, 'INVALID_TOKEN', 'token must be a hex APNs token');
            }
            patch.token = String(req.body.token).toLowerCase();
        }
        if (req.body?.frequentPushesEnabled !== undefined) {
            patch.frequentPushesEnabled = req.body.frequentPushesEnabled !== false;
        }

        store.touch(id, patch);
        return res.status(204).end();
    });

    router.delete('/live-activities/:activityId', (req, res) => {
        const id = `${req.installId}:${req.params.activityId}`;
        store.delete(id);
        metrics?.setPushTokens?.(store.countByType());
        // Idempotent: ending an activity twice is normal, not an error.
        return res.status(204).end();
    });

    router.post('/widgets', (req, res) => {
        const { token } = req.body ?? {};
        if (!TOKEN_PATTERN.test(String(token ?? ''))) {
            return badRequest(res, 'INVALID_TOKEN', 'token must be a hex APNs token');
        }
        const subscriptions = Array.isArray(req.body?.subscriptions) ? req.body.subscriptions : [];
        if (subscriptions.length > MAX_STOP_IDS) {
            return badRequest(res, 'TOO_MANY_SUBSCRIPTIONS', 'Too many widget subscriptions');
        }

        const id = `${req.installId}:widgets`;
        store.upsert({
            id,
            type: 'widget',
            token: String(token).toLowerCase(),
            installId: req.installId,
            subscriptions: subscriptions.slice(0, MAX_STOP_IDS)
        });
        metrics?.setPushTokens?.(store.countByType());
        return res.status(201).json({ data: { id } });
    });

    router.delete('/widgets', (req, res) => {
        store.delete(`${req.installId}:widgets`);
        metrics?.setPushTokens?.(store.countByType());
        return res.status(204).end();
    });

    return router;
}
