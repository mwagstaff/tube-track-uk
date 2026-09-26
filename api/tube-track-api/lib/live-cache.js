function arrivalOrder(left, right) {
    if (left.stopId !== right.stopId) {
        return left.stopId.localeCompare(right.stopId);
    }
    const leftSeconds = left.timeToStation ?? Number.MAX_SAFE_INTEGER;
    const rightSeconds = right.timeToStation ?? Number.MAX_SAFE_INTEGER;
    if (leftSeconds !== rightSeconds) {
        return leftSeconds - rightSeconds;
    }
    return left.id.localeCompare(right.id);
}

export class LiveCache {
    #snapshot = null;
    #modeSnapshots = new Map();
    #expectedModes = [];

    constructor({ staleAfterMs = 90_000, clock = Date.now } = {}) {
        this.staleAfterMs = staleAfterMs;
        this.clock = clock;
    }

    replace(arrivals, { startedAt, completedAt, modeCounts }) {
        // Keep the original whole-snapshot entry point for callers that seed a
        // cache. Polling updates individual modes through replaceModes().
        const completedAtMs = new Date(completedAt).getTime();
        const expectedModes = Object.keys(modeCounts);
        const modeSnapshots = new Map(expectedModes.map((mode) => [mode, {
            arrivals: Object.freeze(arrivals.filter((arrival) => arrival.mode === mode)),
            updatedAtMs: completedAtMs
        }]));
        return this.#publish(arrivals, { startedAt, completedAt, modeCounts }, modeSnapshots, expectedModes);
    }

    replaceModes(arrivalsByMode, { modes, startedAt, completedAt }) {
        const completedAtMs = new Date(completedAt).getTime();
        const next = new Map(this.#modeSnapshots);
        for (const [mode, arrivals] of arrivalsByMode) {
            if (!modes.includes(mode)) {
                throw new Error(`Unexpected live arrivals mode: ${mode}`);
            }
            next.set(mode, {
                arrivals: Object.freeze([...arrivals]),
                updatedAtMs: completedAtMs
            });
        }
        const arrivals = [];
        const modeCounts = {};
        for (const mode of modes) {
            const entries = next.get(mode)?.arrivals ?? [];
            arrivals.push(...entries);
            modeCounts[mode] = entries.length;
        }
        return this.#publish(arrivals, { startedAt, completedAt, modeCounts }, next, [...modes]);
    }

    #publish(arrivals, { startedAt, completedAt, modeCounts }, modeSnapshots, expectedModes) {
        const orderedArrivals = Object.freeze([...arrivals].sort(arrivalOrder));
        const arrivalsByStop = new Map();
        const trainsByVehicleId = new Map();

        for (const arrival of orderedArrivals) {
            const stationArrivals = arrivalsByStop.get(arrival.stopId);
            if (stationArrivals) {
                stationArrivals.push(arrival);
            } else {
                arrivalsByStop.set(arrival.stopId, [arrival]);
            }

            if (!arrival.vehicleId) {
                continue;
            }
            const key = `${arrival.lineId}:${arrival.vehicleId}`;
            const existing = trainsByVehicleId.get(key);
            if (
                !existing
                || (arrival.timeToStation ?? Number.MAX_SAFE_INTEGER)
                    < (existing.timeToStation ?? Number.MAX_SAFE_INTEGER)
            ) {
                trainsByVehicleId.set(key, arrival);
            }
        }

        for (const [stopId, values] of arrivalsByStop) {
            arrivalsByStop.set(stopId, Object.freeze(values));
        }

        const completedAtMs = new Date(completedAt).getTime();
        const modeUpdatedAt = Object.fromEntries(expectedModes.map((mode) => [
            mode,
            modeSnapshots.has(mode)
                ? new Date(modeSnapshots.get(mode).updatedAtMs).toISOString()
                : null
        ]));
        const oldestModeUpdateMs = Math.min(
            ...expectedModes
                .map((mode) => modeSnapshots.get(mode)?.updatedAtMs)
                .filter((value) => value !== undefined)
        );
        const updatedAtMs = Number.isFinite(oldestModeUpdateMs)
            ? oldestModeUpdateMs
            : completedAtMs;
        const generation = Math.max(completedAtMs, (this.#snapshot?.generation ?? 0) + 1);
        const snapshot = Object.freeze({
            generation,
            startedAt: new Date(startedAt).toISOString(),
            updatedAt: new Date(updatedAtMs).toISOString(),
            updatedAtMs,
            arrivals: orderedArrivals,
            arrivalsByStop,
            trainsByVehicleId,
            modeCounts: Object.freeze({ ...modeCounts }),
            modeUpdatedAt: Object.freeze(modeUpdatedAt),
            etag: `W/\"${generation}-${orderedArrivals.length}\"`
        });
        this.#modeSnapshots = modeSnapshots;
        this.#expectedModes = expectedModes;
        this.#snapshot = snapshot;

        return this.read();
    }

    read() {
        if (!this.#snapshot) {
            return null;
        }
        const ageMs = Math.max(0, this.clock() - this.#snapshot.updatedAtMs);
        const modeAgeSeconds = {};
        const staleModes = [];
        for (const mode of this.#expectedModes) {
            const entry = this.#modeSnapshots.get(mode);
            const modeAgeMs = entry ? Math.max(0, this.clock() - entry.updatedAtMs) : null;
            modeAgeSeconds[mode] = modeAgeMs === null ? null : Math.floor(modeAgeMs / 1_000);
            if (modeAgeMs === null || modeAgeMs > this.staleAfterMs) {
                staleModes.push(mode);
            }
        }
        return {
            snapshot: this.#snapshot,
            ageMs,
            ageSeconds: Math.floor(ageMs / 1_000),
            modeAgeSeconds,
            staleModes,
            stale: ageMs > this.staleAfterMs || staleModes.length > 0
        };
    }
}
