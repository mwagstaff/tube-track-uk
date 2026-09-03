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

    constructor({ staleAfterMs = 90_000, clock = Date.now } = {}) {
        this.staleAfterMs = staleAfterMs;
        this.clock = clock;
    }

    replace(arrivals, { startedAt, completedAt, modeCounts }) {
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
        this.#snapshot = Object.freeze({
            generation: completedAtMs,
            startedAt: new Date(startedAt).toISOString(),
            updatedAt: new Date(completedAt).toISOString(),
            updatedAtMs: completedAtMs,
            arrivals: orderedArrivals,
            arrivalsByStop,
            trainsByVehicleId,
            modeCounts: Object.freeze({ ...modeCounts }),
            etag: `W/\"${completedAtMs}-${orderedArrivals.length}\"`
        });

        return this.read();
    }

    read() {
        if (!this.#snapshot) {
            return null;
        }
        const ageMs = Math.max(0, this.clock() - this.#snapshot.updatedAtMs);
        return {
            snapshot: this.#snapshot,
            ageMs,
            ageSeconds: Math.floor(ageMs / 1_000),
            stale: ageMs > this.staleAfterMs
        };
    }
}
