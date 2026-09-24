import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

// Live Activities cap at 90 minutes; 8 hours covers a forgotten one plus clock
// skew. Widget tokens are long-lived, but a widget nobody has looked at in a
// month is not worth pushing to.
export const LIVE_ACTIVITY_TTL_MS = 8 * 60 * 60 * 1_000;
export const WIDGET_TTL_MS = 30 * 24 * 60 * 60 * 1_000;

const DEFAULT_MAX_ENTRIES = 5_000;
const FLUSH_DEBOUNCE_MS = 5_000;

/**
 * Where durable state lives.
 *
 * Deliberately *not* under the project directory: `deploy/node_project.zsh`
 * runs `rsync --delete`, so anything inside `api/tube-track-api/` is destroyed
 * on every deploy — which would silently drop every registered token and leave
 * Live Activities frozen with no error anywhere.
 */
export function defaultDataDirectory(env = process.env) {
    const configured = env.TUBETRACK_UK_DATA_DIR?.trim();
    if (configured) return configured;
    // HOME first: under systemd the unit's HOME is the authority, and
    // os.homedir() reads the passwd entry, which can differ.
    const home = env.HOME?.trim() || os.homedir();
    const base = env.XDG_DATA_HOME?.trim() || path.join(home, '.local', 'share');
    return path.join(base, 'tube-track-api');
}

/**
 * Registered push tokens, held in memory and mirrored to one JSON file.
 *
 * A file rather than a database because this service has four dependencies and
 * no datastore, and the working set is tens to hundreds of rows. The interface
 * is shaped so a real store can replace it without callers changing.
 */
export class PushTokenStore {
    #rows = new Map();
    #flushTimer = null;
    #flushing = null;
    #dirty = false;

    constructor({
        filePath,
        dataDir = defaultDataDirectory(),
        fileName = 'push-tokens.json',
        maxEntries = DEFAULT_MAX_ENTRIES,
        flushDebounceMs = FLUSH_DEBOUNCE_MS,
        clock = Date.now,
        logger
    } = {}) {
        this.filePath = filePath ?? path.join(dataDir, fileName);
        this.maxEntries = maxEntries;
        this.flushDebounceMs = flushDebounceMs;
        this.clock = clock;
        this.logger = logger;
        this.writeFailures = 0;
    }

    /** Reads what the last run left behind. Never throws: an unreadable store
     *  costs pushes, but refusing to start costs the whole API. */
    async load() {
        try {
            const raw = await fsp.readFile(this.filePath, 'utf8');
            const parsed = JSON.parse(raw);
            const rows = Array.isArray(parsed?.rows) ? parsed.rows : [];
            for (const row of rows) {
                if (!row?.id || !row?.token) continue;
                this.#rows.set(row.id, row);
            }
            this.#evict();
        } catch (error) {
            if (error.code !== 'ENOENT') {
                this.logger?.warn('push_token_store_unreadable', { error: error.message });
            }
        }
        return this;
    }

    get size() {
        return this.#rows.size;
    }

    countByType() {
        const counts = { liveActivity: 0, widget: 0 };
        for (const row of this.#rows.values()) {
            if (row.type === 'widget') counts.widget += 1;
            else counts.liveActivity += 1;
        }
        return counts;
    }

    get(id) {
        const row = this.#rows.get(id);
        if (!row) return null;
        return this.#isExpired(row) ? null : row;
    }

    /** Every live row, expired ones filtered out. */
    all({ type } = {}) {
        const rows = [];
        for (const row of this.#rows.values()) {
            if (this.#isExpired(row)) continue;
            if (type && row.type !== type) continue;
            rows.push(row);
        }
        return rows;
    }

    upsert(row) {
        if (!row?.id || !row?.token) {
            throw new Error('A push token row needs an id and a token');
        }
        const now = this.clock();
        const existing = this.#rows.get(row.id);
        const merged = {
            ...existing,
            ...row,
            createdAtMs: existing?.createdAtMs ?? now,
            updatedAtMs: now
        };
        // Re-inserting moves the row to the end, so eviction drops the least
        // recently touched rather than the oldest-created.
        this.#rows.delete(row.id);
        this.#rows.set(row.id, merged);
        this.#evict();
        this.#markDirty();
        return merged;
    }

    /** Records a successful or failed send without rewriting the whole row. */
    touch(id, patch = {}) {
        const existing = this.#rows.get(id);
        if (!existing) return null;
        const updated = { ...existing, ...patch, updatedAtMs: this.clock() };
        this.#rows.set(id, updated);
        this.#markDirty();
        return updated;
    }

    delete(id) {
        const removed = this.#rows.delete(id);
        if (removed) this.#markDirty();
        return removed;
    }

    /** Drops expired rows. Returns how many went. */
    prune() {
        let removed = 0;
        for (const [id, row] of this.#rows) {
            if (this.#isExpired(row)) {
                this.#rows.delete(id);
                removed += 1;
            }
        }
        if (removed > 0) this.#markDirty();
        return removed;
    }

    #isExpired(row) {
        const ttl = row.type === 'widget' ? WIDGET_TTL_MS : LIVE_ACTIVITY_TTL_MS;
        return this.clock() - (row.updatedAtMs ?? 0) > ttl;
    }

    #evict() {
        while (this.#rows.size > this.maxEntries) {
            const oldest = this.#rows.keys().next().value;
            this.#rows.delete(oldest);
        }
    }

    #markDirty() {
        this.#dirty = true;
        if (this.#flushTimer) return;
        this.#flushTimer = setTimeout(() => {
            this.#flushTimer = null;
            this.flush().catch(() => {});
        }, this.flushDebounceMs);
        this.#flushTimer.unref?.();
    }

    /**
     * Writes the store out. Write-and-rename, so a crash mid-write leaves the
     * previous file intact rather than a truncated one that loses every token.
     */
    async flush() {
        if (!this.#dirty) return false;
        if (this.#flushing) return this.#flushing;

        this.#dirty = false;
        const rows = [...this.#rows.values()];
        const temporaryPath = `${this.filePath}.${process.pid}.tmp`;

        this.#flushing = (async () => {
            try {
                await fsp.mkdir(path.dirname(this.filePath), { recursive: true });
                await fsp.writeFile(
                    temporaryPath,
                    JSON.stringify({ version: 1, rows }),
                    { mode: 0o600 }
                );
                await fsp.rename(temporaryPath, this.filePath);
                return true;
            } catch (error) {
                this.writeFailures += 1;
                this.#dirty = true;
                this.logger?.error('push_token_store_write_failed', { error: error.message });
                await fsp.rm(temporaryPath, { force: true }).catch(() => {});
                return false;
            } finally {
                this.#flushing = null;
            }
        })();

        return this.#flushing;
    }

    /** Flushes synchronously — for shutdown, where the event loop is going away. */
    flushSync() {
        if (!this.#dirty) return false;
        const temporaryPath = `${this.filePath}.${process.pid}.tmp`;
        try {
            fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
            fs.writeFileSync(
                temporaryPath,
                JSON.stringify({ version: 1, rows: [...this.#rows.values()] }),
                { mode: 0o600 }
            );
            fs.renameSync(temporaryPath, this.filePath);
            this.#dirty = false;
            return true;
        } catch (error) {
            this.writeFailures += 1;
            this.logger?.error('push_token_store_write_failed', { error: error.message });
            return false;
        }
    }

    stop() {
        if (this.#flushTimer) {
            clearTimeout(this.#flushTimer);
            this.#flushTimer = null;
        }
    }
}
