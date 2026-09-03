export class ResourceCache {
    #entries = new Map();
    #inFlight = new Map();

    constructor({ clock = Date.now, maximumEntries = 128 } = {}) {
        this.clock = clock;
        this.maximumEntries = maximumEntries;
    }

    async get(key, { freshForMs, load }) {
        const now = this.clock();
        const cached = this.#entries.get(key);
        if (cached && now - cached.updatedAtMs < freshForMs) {
            return this.#result(cached, { cached: true, stale: false });
        }

        let request = this.#inFlight.get(key);
        if (!request) {
            request = Promise.resolve().then(load);
            this.#inFlight.set(key, request);
        }

        try {
            const data = await request;
            const updatedAtMs = this.clock();
            const entry = { data, updatedAtMs };
            this.#entries.delete(key);
            this.#entries.set(key, entry);
            this.#prune();
            return this.#result(entry, { cached: false, stale: false });
        } catch (error) {
            if (cached) {
                return this.#result(cached, { cached: true, stale: true });
            }
            throw error;
        } finally {
            if (this.#inFlight.get(key) === request) {
                this.#inFlight.delete(key);
            }
        }
    }

    #result(entry, { cached, stale }) {
        return {
            data: entry.data,
            meta: {
                updatedAt: new Date(entry.updatedAtMs).toISOString(),
                cached,
                stale
            }
        };
    }

    #prune() {
        while (this.#entries.size > this.maximumEntries) {
            this.#entries.delete(this.#entries.keys().next().value);
        }
    }
}
