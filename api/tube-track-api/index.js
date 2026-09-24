import { createApp } from './lib/app.js';
import { loadConfig, LIVE_MODES } from './lib/config.js';
import { LiveCache } from './lib/live-cache.js';
import { LivePoller } from './lib/live-poller.js';
import { createLogger } from './lib/logger.js';
import { createMetrics } from './lib/metrics.js';
import { PlannedTrackClosuresSource } from './lib/planned-works.js';
import { ApnsClient, ApnsTokenSigner } from './lib/push/apns.js';
import { LiveActivityNotifier } from './lib/push/notifier.js';
import { PushTokenStore } from './lib/push/token-store.js';
import { ResourceCache } from './lib/resource-cache.js';
import { TfLClient } from './lib/tfl-client.js';

const STATUS_MODES = 'tube,dlr,elizabeth-line,overground,tram';

/**
 * Builds the push stack, or nothing at all when APNs is not configured.
 *
 * Anything that goes wrong here is logged and swallowed: an API that refuses to
 * start because a key file moved would take live departures down with it, which
 * is a far worse outcome than Live Activities going quiet.
 */
async function createPushStack({ config, logger, metrics, resourceCache, client }) {
    if (!config.push.enabled) {
        logger.info('push_disabled', { reason: 'apns_not_configured' });
        return { store: null, notifier: null, apns: null };
    }

    try {
        const store = await new PushTokenStore({
            ...(config.push.dataDir ? { dataDir: config.push.dataDir } : {}),
            logger
        }).load();

        const signer = config.push.keyPath
            ? ApnsTokenSigner.fromKeyPath({
                keyPath: config.push.keyPath,
                keyId: config.push.keyId,
                teamId: config.push.teamId
            })
            : new ApnsTokenSigner({
                privateKey: config.push.inlineKey,
                keyId: config.push.keyId,
                teamId: config.push.teamId
            });

        const apns = new ApnsClient({
            signer,
            environment: config.push.environment,
            requestTimeoutMs: config.push.requestTimeoutMs,
            logger,
            metrics
        });

        const notifier = new LiveActivityNotifier({
            store,
            client: apns,
            topic: config.push.liveActivityTopic,
            logger,
            metrics,
            // Reuses the cache behind /api/v1/status, so a tracked board's
            // headline costs no extra TfL request in the common case.
            statuses: async () => {
                const result = await resourceCache.get('status', {
                    freshForMs: 60_000,
                    load: () => client.fetchJSON(`/Line/Mode/${STATUS_MODES}/Status`, {
                        query: { detail: 'true' },
                        metricLabel: 'status'
                    })
                });
                return result.data;
            }
        });

        metrics.setPushTokens(store.countByType());
        logger.info('push_enabled', {
            environment: config.push.environment,
            topic: config.push.liveActivityTopic,
            store: store.filePath,
            tokens: store.countByType()
        });
        return { store, notifier, apns };
    } catch (error) {
        logger.error('push_setup_failed', { error });
        return { store: null, notifier: null, apns: null };
    }
}

async function main() {
    const logger = createLogger();
    let config;
    try {
        config = loadConfig();
    } catch (error) {
        logger.error('configuration_invalid', { error });
        process.exitCode = 1;
        return;
    }

    const cache = new LiveCache({ staleAfterMs: config.staleAfterMs });
    const metrics = createMetrics({ cache });
    const client = new TfLClient({
        apiKey: config.apiKey,
        timeoutMs: config.requestTimeoutMs,
        maxConcurrentRequests: config.maxConcurrentRequests,
        metrics
    });
    const resourceCache = new ResourceCache();
    const plannedTrackClosuresSource = new PlannedTrackClosuresSource();
    const push = await createPushStack({ config, logger, metrics, resourceCache, client });
    const poller = new LivePoller({
        modes: LIVE_MODES,
        client,
        cache,
        metrics,
        logger,
        notifier: push.notifier,
        pollIntervalMs: config.pollIntervalMs,
        requestStaggerMs: config.requestStaggerMs,
        refreshTimeoutMs: config.refreshTimeoutMs
    });
    const app = createApp({
        cache,
        poller,
        metrics,
        logger,
        client,
        resourceCache,
        plannedTrackClosuresSource,
        pushTokenStore: push.store,
        pushClientSecret: config.push.clientSecret
    });

    const server = app.listen(config.port, config.host, () => {
        logger.info('server_started', {
            host: config.host,
            port: config.port,
            modes: LIVE_MODES,
            pollIntervalMs: config.pollIntervalMs,
            refreshTimeoutMs: config.refreshTimeoutMs,
            staleAfterMs: config.staleAfterMs,
            maxConcurrentRequests: config.maxConcurrentRequests
        });
        poller.start();
    });
    server.keepAliveTimeout = 65_000;
    server.headersTimeout = 70_000;

    let shuttingDown = false;
    async function shutdown(signal) {
        if (shuttingDown) return;
        shuttingDown = true;
        logger.info('shutdown_started', { signal });

        const forcedExit = setTimeout(() => {
            logger.error('shutdown_forced', { signal });
            process.exit(1);
        }, 10_000);
        forcedExit.unref();

        await poller.stop();
        // Tokens registered since the last debounced write would otherwise be
        // lost, and a lost token is an activity that silently stops updating.
        push.store?.stop();
        push.store?.flushSync();
        push.apns?.close();
        await new Promise((resolve) => server.close(resolve));
        clearTimeout(forcedExit);
        logger.info('shutdown_completed', { signal });
    }

    process.once('SIGTERM', () => {
        shutdown('SIGTERM').catch((error) => {
            logger.error('shutdown_failed', { error });
            process.exit(1);
        });
    });
    process.once('SIGINT', () => {
        shutdown('SIGINT').catch((error) => {
            logger.error('shutdown_failed', { error });
            process.exit(1);
        });
    });
}

main().catch((error) => {
    createLogger().error('startup_failed', { error });
    process.exit(1);
});
