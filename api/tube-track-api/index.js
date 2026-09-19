import { createApp } from './lib/app.js';
import { loadConfig, LIVE_MODES } from './lib/config.js';
import { LiveCache } from './lib/live-cache.js';
import { LivePoller } from './lib/live-poller.js';
import { createLogger } from './lib/logger.js';
import { createMetrics } from './lib/metrics.js';
import { PlannedTrackClosuresSource } from './lib/planned-works.js';
import { ResourceCache } from './lib/resource-cache.js';
import { TfLClient } from './lib/tfl-client.js';

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
    const poller = new LivePoller({
        modes: LIVE_MODES,
        client,
        cache,
        metrics,
        logger,
        pollIntervalMs: config.pollIntervalMs,
        requestStaggerMs: config.requestStaggerMs
    });
    const app = createApp({
        cache,
        poller,
        metrics,
        logger,
        client,
        resourceCache,
        plannedTrackClosuresSource
    });

    const server = app.listen(config.port, config.host, () => {
        logger.info('server_started', {
            host: config.host,
            port: config.port,
            modes: LIVE_MODES,
            pollIntervalMs: config.pollIntervalMs,
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
