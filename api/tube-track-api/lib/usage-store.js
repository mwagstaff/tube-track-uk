import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { defaultDataDirectory } from './push/token-store.js';

const RETAIN_DAYS = 45;
const SURFACES = ['ios_app', 'widget', 'watch'];
const londonDate = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit'
});

export function usageDay(timestampMs) {
    const parts = Object.fromEntries(londonDate.formatToParts(new Date(timestampMs))
        .map(({ type, value }) => [type, value]));
    return `${parts.year}-${parts.month}-${parts.day}`;
}

function priorDay(day, offset) {
    const date = new Date(`${day}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() - offset);
    return date.toISOString().slice(0, 10);
}

/** Only deduplicated, salted install hashes are persisted; request details are not. */
export class UsageStore {
    #days = new Map();
    #salt = randomBytes(32).toString('hex');
    #dirty = false;
    #persistDisabled = false;
    #timer = null;
    #flushing = null;

    constructor({
        filePath = path.join(defaultDataDirectory(), 'usage-installs.json'),
        clock = Date.now,
        flushDebounceMs = 5_000,
        logger
    } = {}) {
        this.filePath = filePath;
        this.clock = clock;
        this.flushDebounceMs = flushDebounceMs;
        this.logger = logger;
        this.writeFailures = 0;
        this.writeOk = true;
    }

    async load() {
        try {
            const parsed = JSON.parse(await fsp.readFile(this.filePath, 'utf8'));
            if (parsed.version !== 1 || !/^[a-f0-9]{64}$/.test(parsed.salt)) {
                throw new Error('invalid usage store format');
            }
            this.#salt = parsed.salt;
            for (const [day, surfaces] of Object.entries(parsed.days ?? {})) {
                if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) continue;
                const rows = new Map();
                for (const surface of SURFACES) {
                    rows.set(surface, new Set((surfaces[surface] ?? [])
                        .filter((hash) => /^[a-f0-9]{64}$/.test(hash))));
                }
                this.#days.set(day, rows);
            }
            this.#prune();
        } catch (error) {
            if (error.code !== 'ENOENT') {
                this.writeOk = false;
                this.#persistDisabled = true;
                this.logger?.warn('usage_store_unreadable', { error: error.message });
            }
        }
        return this;
    }

    record(installId, surface) {
        if (!SURFACES.includes(surface)) return false;
        const day = usageDay(this.clock());
        let rows = this.#days.get(day);
        if (!rows) {
            rows = new Map(SURFACES.map((name) => [name, new Set()]));
            this.#days.set(day, rows);
        }
        const hash = createHash('sha256').update(this.#salt).update(':').update(installId)
            .digest('hex');
        const set = rows.get(surface);
        if (set.has(hash)) return false;
        set.add(hash);
        this.#prune();
        this.#markDirty();
        return true;
    }

    counts() {
        const today = usageDay(this.clock());
        const result = {};
        for (const surface of SURFACES) {
            result[surface] = {};
            for (const [window, length] of [['1d', 1], ['7d', 7], ['30d', 30]]) {
                const unique = new Set();
                for (let offset = 0; offset < length; offset += 1) {
                    for (const hash of this.#days.get(priorDay(today, offset))?.get(surface) ?? []) {
                        unique.add(hash);
                    }
                }
                result[surface][window] = unique.size;
            }
        }
        return result;
    }

    #prune() {
        const oldest = priorDay(usageDay(this.clock()), RETAIN_DAYS - 1);
        for (const day of this.#days.keys()) {
            if (day < oldest) {
                this.#days.delete(day);
                this.#markDirty();
            }
        }
    }

    #markDirty() {
        this.#dirty = true;
        if (this.#persistDisabled) return;
        if (this.#timer) return;
        this.#timer = setTimeout(() => {
            this.#timer = null;
            this.flush().catch(() => {});
        }, this.flushDebounceMs);
        this.#timer.unref?.();
    }

    #snapshot() {
        const days = {};
        for (const [day, surfaces] of this.#days) {
            days[day] = Object.fromEntries(SURFACES.map((surface) => [
                surface, [...surfaces.get(surface)]
            ]));
        }
        return JSON.stringify({ version: 1, salt: this.#salt, days });
    }

    async flush() {
        if (this.#persistDisabled) return false;
        if (this.#flushing) return this.#flushing;
        if (!this.#dirty) return false;
        this.#dirty = false;
        const snapshot = this.#snapshot();
        const temporary = `${this.filePath}.${process.pid}.tmp`;
        this.#flushing = (async () => {
            try {
                await fsp.mkdir(path.dirname(this.filePath), { recursive: true });
                await fsp.writeFile(temporary, snapshot, { mode: 0o600 });
                await fsp.rename(temporary, this.filePath);
                this.writeOk = true;
                return true;
            } catch (error) {
                this.writeFailures += 1;
                this.writeOk = false;
                this.#dirty = true;
                this.logger?.error('usage_store_write_failed', { error: error.message });
                await fsp.rm(temporary, { force: true }).catch(() => {});
                return false;
            } finally {
                this.#flushing = null;
                if (this.#dirty) this.#markDirty();
            }
        })();
        return this.#flushing;
    }

    stop() {
        if (this.#timer) clearTimeout(this.#timer);
        this.#timer = null;
    }

    flushSync() {
        if (this.#persistDisabled) return false;
        if (!this.#dirty) return false;
        const temporary = `${this.filePath}.${process.pid}.tmp`;
        try {
            fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
            fs.writeFileSync(temporary, this.#snapshot(), { mode: 0o600 });
            fs.renameSync(temporary, this.filePath);
            this.#dirty = false;
            this.writeOk = true;
            return true;
        } catch (error) {
            this.writeFailures += 1;
            this.writeOk = false;
            this.logger?.error('usage_store_write_failed', { error: error.message });
            return false;
        }
    }
}
