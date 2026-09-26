import express from 'express';
import { DIRECTION_FILTERS } from './push/departure-projection.js';
import { isRiverBusLine } from './river.js';
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
//
// These are the only thing standing between the token store and abuse, so they
// are set tighter than a credentialed endpoint would need. A passenger starts
// one activity at a time and re-registers only when a token rotates, so even
// heavy real use sits far below these.
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX_REQUESTS = 10;
const RATE_LIMIT_MAX_KEYS = 10_000;

// An install id is self-asserted, so anyone willing to rotate it can walk past
// the per-install bucket. The global ceiling is what actually bounds that: real
// traffic is a handful of registrations a minute across all users, so this
// leaves orders of magnitude of headroom and still caps a flood.
const GLOBAL_RATE_LIMIT_MAX_REQUESTS = 300;

function badRequest(res, code, message) {
    res.status(400).json({ error: { code, message } });
}

export function createRateLimiter({
    windowMs = RATE_LIMIT_WINDOW_MS,
    maxRequests = RATE_LIMIT_MAX_REQUESTS,
    globalMaxRequests = GLOBAL_RATE_LIMIT_MAX_REQUESTS,
    maxKeys = RATE_LIMIT_MAX_KEYS,
    clock = Date.now
} = {}) {
    const buckets = new Map();
    let global = { startedAtMs: 0, count: 0 };

    function spend(bucket, now, limit) {
        if (now - bucket.startedAtMs >= windowMs) {
            bucket.startedAtMs = now;
            bucket.count = 1;
            return true;
        }
        bucket.count += 1;
        return bucket.count <= limit;
    }

    return function allow(key) {
        const now = clock();

        if (!spend(global, now, globalMaxRequests)) return false;

        let bucket = buckets.get(key);
        if (!bucket) {
            bucket = { startedAtMs: 0, count: 0 };
        } else {
            // Re-inserting keeps the map in least-recently-seen order, so the
            // eviction below drops idle installs rather than busy ones.
            buckets.delete(key);
        }
        buckets.set(key, bucket);
        while (buckets.size > maxKeys) {
            buckets.delete(buckets.keys().next().value);
        }
        return spend(bucket, now, maxRequests);
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
 * Deliberately unauthenticated, matching TrainTrack UK and Top Scores. A secret
 * shipped inside the app is readable by anyone who unpacks it, so it would have
 * been obfuscation rather than authentication, at the cost of a secret to
 * manage in two places.
 *
 * What bounds the damage instead:
 *   - the rate limiter above, per install and globally;
 *   - the entry cap and TTL in the token store;
 *   - the fact that a subscription can only ever cause a push to the device
 *     token its registrant supplied, so this cannot be pointed at anyone else;
 *   - APNs itself, which answers BadDeviceToken for a fabricated token, and the
 *     notifier then retires the row — so junk does not accumulate.
 *
 * The residual risk is someone rotating install ids to fill the store and evict
 * real subscriptions. App Attest is the fix if that ever happens.
 */
export function createPushRoutes({
    store,
    isKnownStop = () => true,
    riverNetwork = async () => ({ piers: [] }),
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
        const installId = req.get('x-tubetrack-install');
        if (!installId || !ID_PATTERN.test(installId)) {
            badRequest(res, 'INVALID_INSTALL_ID', 'x-tubetrack-install must identify the app install');
            return;
        }
        if (!rateLimiter(installId)) {
            metrics?.recordPushRateLimited?.();
            res.status(429).json({
                error: { code: 'RATE_LIMITED', message: 'Too many registration requests' }
            });
            return;
        }
        req.installId = installId;
        next();
    });

    router.post('/live-activities', async (req, res) => {
        const body = req.body ?? {};
        const { activityId, token, lineId, direction, hubId } = body;

        if (!ID_PATTERN.test(String(activityId ?? ''))) {
            return badRequest(res, 'INVALID_ACTIVITY_ID', 'activityId is required');
        }
        if (!TOKEN_PATTERN.test(String(token ?? ''))) {
            return badRequest(res, 'INVALID_TOKEN', 'token must be a hex APNs token');
        }
        const isRiver = isRiverBusLine(lineId);
        if (!LINE_IDS.has(String(lineId)) && !isRiver) {
            return badRequest(res, 'INVALID_LINE', 'lineId must be a line TubeTrack serves');
        }
        if (!DIRECTION_FILTERS.includes(String(direction ?? 'any'))) {
            return badRequest(res, 'INVALID_DIRECTION', 'direction must be a known filter');
        }
        let pier = null;
        if (isRiver) {
            let network;
            try { network = await riverNetwork(); }
            catch {
                return res.status(503).json({ error: { code: 'RIVER_UNAVAILABLE', message: 'River Bus data is temporarily unavailable' } });
            }
            pier = network.piers.find((item) => item.id === hubId && item.lineIds.includes(lineId));
            if (!pier || (direction ?? 'any') !== 'any') {
                return badRequest(res, 'INVALID_PIER', 'River tracking requires a known pier and service');
            }
        }
        // River subscriptions name exactly one canonical pier. Its berths are
        // resolved server-side, so callers cannot subscribe to unrelated stops.
        const stopIds = isRiver
            ? (Array.isArray(body.stopIds) && body.stopIds.length === 1 && body.stopIds[0] === pier.id ? [pier.id] : null)
            : readStopIds(body.stopIds, isKnownStop);
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
