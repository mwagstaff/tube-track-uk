import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
    defaultDataDirectory,
    LIVE_ACTIVITY_TTL_MS,
    PushTokenStore,
    WIDGET_TTL_MS
} from '../lib/push/token-store.js';

async function temporaryStore(options = {}) {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tube-track-push-'));
    const store = new PushTokenStore({
        filePath: path.join(dir, 'push-tokens.json'),
        flushDebounceMs: 5,
        ...options
    });
    return { store, dir };
}

test('the store lives outside the project directory that deploys wipe', () => {
    const directory = defaultDataDirectory({ HOME: '/home/someone' });
    assert.equal(directory, '/home/someone/.local/share/tube-track-api');
    assert.equal(directory.includes('tube-track-api/data'), false);

    assert.equal(
        defaultDataDirectory({ TUBETRACK_UK_DATA_DIR: '/var/lib/tube' }),
        '/var/lib/tube'
    );
    assert.equal(
        defaultDataDirectory({ XDG_DATA_HOME: '/xdg', HOME: '/home/someone' }),
        '/xdg/tube-track-api'
    );
});

test('rows survive a restart', async () => {
    const { store, dir } = await temporaryStore();
    store.upsert({ id: 'activity-1', type: 'liveActivity', token: 'aa', hubId: 'HUBOXC' });
    await store.flush();

    const reopened = await new PushTokenStore({
        filePath: path.join(dir, 'push-tokens.json')
    }).load();
    assert.equal(reopened.size, 1);
    assert.equal(reopened.get('activity-1').hubId, 'HUBOXC');
});

test('a missing store starts empty rather than failing the service', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tube-track-push-'));
    const store = await new PushTokenStore({
        filePath: path.join(dir, 'nothing-here.json')
    }).load();
    assert.equal(store.size, 0);
});

test('a corrupted store starts empty rather than failing the service', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'tube-track-push-'));
    const filePath = path.join(dir, 'push-tokens.json');
    await fs.writeFile(filePath, '{ this is not json');

    const warnings = [];
    const store = await new PushTokenStore({
        filePath,
        logger: { warn: (event) => warnings.push(event) }
    }).load();

    assert.equal(store.size, 0);
    assert.deepEqual(warnings, ['push_token_store_unreadable']);
});

test('a crash mid-write cannot truncate the previous store', async () => {
    const { store, dir } = await temporaryStore();
    const filePath = path.join(dir, 'push-tokens.json');

    store.upsert({ id: 'a', type: 'liveActivity', token: 'aa' });
    await store.flush();
    const original = await fs.readFile(filePath, 'utf8');

    // A write that fails at rename time leaves the good file in place.
    store.upsert({ id: 'b', type: 'liveActivity', token: 'bb' });
    const broken = new PushTokenStore({
        filePath: path.join(dir, 'no-such-directory', 'x', 'push-tokens.json'),
        logger: { error: () => {} }
    });
    broken.upsert({ id: 'c', type: 'liveActivity', token: 'cc' });

    assert.equal(await fs.readFile(filePath, 'utf8'), original);
    assert.equal(JSON.parse(original).rows.length, 1);

    // No stray temp files left behind by a failed write.
    const failed = new PushTokenStore({ filePath: '/proc/definitely-not-writable/x.json', logger: { error: () => {} } });
    failed.upsert({ id: 'd', type: 'liveActivity', token: 'dd' });
    assert.equal(await failed.flush(), false);
    assert.equal(failed.writeFailures, 1);
});

test('expired rows stop being visible and are pruned', async () => {
    let now = 1_800_000_000_000;
    const { store } = await temporaryStore({ clock: () => now });

    store.upsert({ id: 'activity', type: 'liveActivity', token: 'aa' });
    store.upsert({ id: 'widget', type: 'widget', token: 'bb' });

    now += LIVE_ACTIVITY_TTL_MS + 1_000;
    assert.equal(store.get('activity'), null, 'an expired activity token is invisible');
    assert.equal(store.get('widget')?.token, 'bb', 'widget tokens live far longer');
    assert.deepEqual(store.all().map((row) => row.id), ['widget']);

    assert.equal(store.prune(), 1);
    assert.equal(store.size, 1);

    now += WIDGET_TTL_MS + 1_000;
    assert.equal(store.prune(), 1);
    assert.equal(store.size, 0);
});

test('the entry cap drops the least recently touched row', async () => {
    let now = 1_800_000_000_000;
    const { store } = await temporaryStore({ maxEntries: 2, clock: () => now });

    store.upsert({ id: 'a', type: 'liveActivity', token: 'aa' });
    store.upsert({ id: 'b', type: 'liveActivity', token: 'bb' });
    now += 1_000;
    store.upsert({ id: 'a', type: 'liveActivity', token: 'aa2' });
    store.upsert({ id: 'c', type: 'liveActivity', token: 'cc' });

    assert.deepEqual(store.all().map((row) => row.id).sort(), ['a', 'c']);
});

test('re-registering keeps the original creation time', async () => {
    let now = 1_800_000_000_000;
    const { store } = await temporaryStore({ clock: () => now });

    store.upsert({ id: 'a', type: 'liveActivity', token: 'aa' });
    now += 60_000;
    const updated = store.upsert({ id: 'a', type: 'liveActivity', token: 'bb' });

    assert.equal(updated.createdAtMs, 1_800_000_000_000);
    assert.equal(updated.updatedAtMs, 1_800_000_060_000);
    assert.equal(updated.token, 'bb');
});

test('writes are debounced rather than one per registration', async () => {
    const { store, dir } = await temporaryStore({ flushDebounceMs: 20 });
    const filePath = path.join(dir, 'push-tokens.json');

    for (let index = 0; index < 20; index += 1) {
        store.upsert({ id: `a${index}`, type: 'liveActivity', token: 'aa' });
    }
    await assert.rejects(fs.access(filePath), 'nothing is written synchronously');

    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(JSON.parse(await fs.readFile(filePath, 'utf8')).rows.length, 20);
    store.stop();
});

test('counts are reported per type for the metrics gauge', async () => {
    const { store } = await temporaryStore();
    store.upsert({ id: 'a', type: 'liveActivity', token: 'aa' });
    store.upsert({ id: 'b', type: 'widget', token: 'bb' });
    store.upsert({ id: 'c', type: 'widget', token: 'cc' });

    assert.deepEqual(store.countByType(), { liveActivity: 1, widget: 2 });
});
