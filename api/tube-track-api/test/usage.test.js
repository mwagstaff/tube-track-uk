import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { createApp } from '../lib/app.js';
import { createMetrics } from '../lib/metrics.js';
import { UsageStore, usageDay } from '../lib/usage-store.js';

test('deduplicates installations, preserves counts over restart, and does not persist raw IDs', async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'tube-usage-'));
    const filePath = path.join(directory, 'usage.json');
    let now = Date.parse('2026-09-26T12:00:00Z');
    try {
        const store = await new UsageStore({ filePath, clock: () => now }).load();
        assert.equal(store.record('install-12345678', 'ios_app'), true);
        assert.equal(store.record('install-12345678', 'ios_app'), false);
        assert.equal(store.record('install-87654321', 'widget'), true);
        assert.deepEqual(store.counts().ios_app, { '1d': 1, '7d': 1, '30d': 1 });
        await store.flush();
        store.stop();

        const persisted = await readFile(filePath, 'utf8');
        assert.doesNotMatch(persisted, /install-12345678|install-87654321/);
        const restored = await new UsageStore({ filePath, clock: () => now }).load();
        assert.equal(restored.record('install-12345678', 'ios_app'), false);
        now = Date.parse('2026-09-27T12:00:00Z');
        assert.equal(restored.record('install-12345678', 'ios_app'), true);
        assert.deepEqual(restored.counts().ios_app, { '1d': 1, '7d': 1, '30d': 1 });
        now = Date.parse('2026-10-04T12:00:00Z');
        assert.deepEqual(restored.counts().ios_app, { '1d': 0, '7d': 0, '30d': 1 });
        restored.stop();
    } finally {
        await rm(directory, { recursive: true, force: true });
    }
});

test('uses London calendar days across the autumn clock change', () => {
    assert.equal(usageDay(Date.parse('2026-10-24T22:30:00Z')), '2026-10-24');
    assert.equal(usageDay(Date.parse('2026-10-24T23:30:00Z')), '2026-10-25');
    assert.equal(usageDay(Date.parse('2026-10-25T01:30:00Z')), '2026-10-25');
});

test('preserves an unreadable store for recovery and reports unhealthy persistence', async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'tube-usage-corrupt-'));
    const filePath = path.join(directory, 'usage.json');
    try {
        await writeFile(filePath, '{broken');
        const store = await new UsageStore({ filePath }).load();
        assert.equal(store.writeOk, false);
        store.record('install-12345678', 'ios_app');
        assert.equal(await store.flush(), false);
        assert.equal(await readFile(filePath, 'utf8'), '{broken');
    } finally {
        await rm(directory, { recursive: true, force: true });
    }
});

test('accepts app opens while keeping widget requests in a separate audience', async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'tube-usage-http-'));
    const usageStore = await new UsageStore({ filePath: path.join(directory, 'usage.json') }).load();
    const metrics = createMetrics({ usageStore, collectProcessMetrics: false });
    const app = createApp({
        cache: { read: () => null },
        poller: { status: () => ({ running: true }) },
        metrics,
        usageStore,
        client: { fetchJSON: async () => [] },
        resourceCache: { get: async () => ({ data: [] }) }
    });
    const server = await new Promise((resolve) => {
        const listening = app.listen(0, '127.0.0.1', () => resolve(listening));
    });
    const base = `http://127.0.0.1:${server.address().port}`;
    const headers = {
        'content-type': 'application/json',
        'x-tubetrack-install': 'install-12345678',
        'x-tubetrack-surface': 'ios_app',
        'x-tubetrack-app-version': '1.2.3'
    };
    try {
        for (let index = 0; index < 2; index += 1) {
            const response = await fetch(`${base}/api/v1/usage`, {
                method: 'POST', headers,
                body: JSON.stringify({ event: 'app_open', feature: 'map' })
            });
            assert.equal(response.status, 204);
        }
        const invalid = await fetch(`${base}/api/v1/usage`, {
            method: 'POST', headers: { ...headers, 'x-tubetrack-surface': 'watch' },
            body: JSON.stringify({ event: 'app_open', feature: 'map' })
        });
        assert.equal(invalid.status, 400);
        const malformed = await fetch(`${base}/api/v1/usage`, {
            method: 'POST', headers, body: '{bad json'
        });
        assert.equal(malformed.status, 400);
        const widget = await fetch(`${base}/api/v1/line-colours`, {
            headers: { ...headers, 'x-tubetrack-surface': 'widget' }
        });
        assert.equal(widget.status, 200);
        assert.equal(usageStore.counts().ios_app['1d'], 1);
        assert.equal(usageStore.counts().widget['1d'], 1);
        const rendered = await metrics.render();
        assert.match(rendered, /tube_track_usage_events_total\{[^}]*event="app_open"[^}]*\} 2/);
        assert.match(rendered, /tube_track_client_requests_total\{[^}]*surface="widget"[^}]*\} 1/);
        assert.match(rendered, /tube_track_client_versions_total\{[^}]*version="1.2"[^}]*\} 1/);
        assert.match(rendered, /tube_track_active_installs\{[^}]*surface="ios_app"[^}]*window="1d"[^}]*\} 1/);
    } finally {
        await new Promise((resolve) => server.close(resolve));
        usageStore.stop();
        await rm(directory, { recursive: true, force: true });
    }
});
