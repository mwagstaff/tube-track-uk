const SECOND = 1_000;
const FRESHNESS = 90 * SECOND;
const MODEL_LIFETIME = 24 * 60 * 60 * SECOND;
const time = (value) => Date.parse(value);
const identity = (p) => p.vehicleId
    ? [p.lineId, p.vehicleId, p.tripId || '', p.direction || '', p.destinationId || ''].join(':') : null;
// Pier timestamps in one TfL batch can differ by a few milliseconds.
const followsObservation = (next, prior) => time(next.observedAt) >= time(prior.observedAt)
    - (next.pierId === prior.pierId ? 0 : SECOND);
const modelKey = (p, from, to) => JSON.stringify([p.lineId, p.direction, from, to]);
const durationOK = (duration) => duration >= 30 * SECOND && duration <= 30 * 60 * SECOND;
const current = (p, now) => time(p.expectedArrival) > now && time(p.observedAt) >= now - FRESHNESS
    && time(p.observedAt) <= now + 30 * SECOND && (!p.expiresAt || time(p.expiresAt) > now);

// One instance per API process, shared by every phone. Models learn from the
// same journey's ordered pier ETAs, not from an assumed constant boat speed.
export class RiverBoatEstimator {
    history = new Map();
    segments = new Map();
    timings = new Map();
    networkKey = null;

    current(now) {
        for (const [key, boat] of this.segments) {
            if (!current(boat, now)) this.segments.delete(key);
        }
        return [...this.segments.values()].sort((a, b) => a.id.localeCompare(b.id));
    }

    update(predictions, network, now = Date.now()) {
        const networkKey = JSON.stringify(network.routes);
        if (this.networkKey !== networkKey) {
            this.history.clear(); this.segments.clear(); this.timings.clear();
            this.networkKey = networkKey;
        }
        this.current(now);
        for (const [key, value] of this.history) {
            if (time(value.target.observedAt) < now - FRESHNESS) this.history.delete(key);
        }
        for (const [key, values] of this.timings) {
            const recent = values.filter((v) => v.observedAt >= now - MODEL_LIFETIME);
            if (recent.length) this.timings.set(key, recent); else this.timings.delete(key);
        }
        const groups = new Map();
        for (const p of predictions) {
            const key = identity(p);
            if (!key || !current(p, now)) continue;
            if (!groups.has(key)) groups.set(key, []);
            groups.get(key).push(p);
        }
        const identitiesByVehicle = new Map();
        for (const [key, rows] of groups) {
            const vehicle = JSON.stringify([rows[0].lineId, rows[0].vehicleId]);
            // A late response for a previous trip must not evict a newer trip.
            const newest = Math.max(...rows.map((row) => time(row.observedAt)));
            const superseded = [...this.history].some(([priorKey, prior]) => priorKey !== key
                && prior.target.lineId === rows[0].lineId && prior.target.vehicleId === rows[0].vehicleId
                && time(prior.target.observedAt) > newest + SECOND);
            if (superseded) { groups.delete(key); continue; }
            if (!identitiesByVehicle.has(vehicle)) identitiesByVehicle.set(vehicle, new Set());
            identitiesByVehicle.get(vehicle).add(key);
        }
        for (const [key, prior] of this.history) {
            const currentKeys = identitiesByVehicle.get(JSON.stringify([prior.target.lineId, prior.target.vehicleId]));
            if (currentKeys && (currentKeys.size !== 1 || !currentKeys.has(key))) {
                this.segments.delete(key); this.history.delete(key);
            }
        }
        for (const keys of identitiesByVehicle.values()) {
            if (keys.size > 1) for (const key of keys) groups.delete(key);
        }
        const journeys = [];
        for (const [key, rows] of groups) {
            const values = [...rows].sort((a, b) => time(a.expectedArrival) - time(b.expectedArrival));
            // A duplicated berth is harmless; conflicting same-time piers are not.
            const unique = values.filter((p, index) => values.findIndex((q) => q.pierId === p.pierId) === index);
            const conflicting = unique.some((p, i) => i > 0
                && time(p.expectedArrival) - time(unique[i - 1].expectedArrival) < 10 * SECOND);
            const target = unique[0];
            const priorObservation = this.history.get(key)?.target;
            if (priorObservation && !followsObservation(target, priorObservation)) continue;
            const routes = network.routes.filter((route) => {
                if (route.lineId !== target.lineId || (target.direction && route.direction !== target.direction)) return false;
                const indices = unique.map((p) => route.stopIds.indexOf(p.pierId));
                if (indices.some((index, i) => index < 0 || (i > 0 && index <= indices[i - 1]))) return false;
                return !target.destinationId || route.stopIds.slice(indices.at(-1)).includes(target.destinationId);
            });
            if (conflicting || !routes.length) {
                this.segments.delete(key); this.history.delete(key); continue;
            }
            journeys.push({ key, values: unique, target, routes });
            // Every journey contributes one sample per directed calling pair.
            // Repeated cached responses must not give that trip extra weight.
            for (let i = 1; i < unique.length; i++) {
                const a = unique[i - 1], b = unique[i];
                const duration = time(b.expectedArrival) - time(a.expectedArrival);
                if (!durationOK(duration)) continue;
                const pair = modelKey(target, a.pierId, b.pierId);
                const observedAt = Math.min(time(a.observedAt), time(b.observedAt));
                const samples = this.timings.get(pair) || [];
                const prior = samples.find((sample) => sample.journey === key);
                if (prior && prior.observedAt >= observedAt) continue;
                this.timings.set(pair, [...samples.filter((sample) => sample.journey !== key),
                    { journey: key, duration, observedAt }].slice(-9));
            }
        }
        for (const { key, values, target, routes } of journeys) {
            const previous = this.history.get(key);
            const segment = this.segments.get(key);
            let from, startedAt, basis;
            if (segment?.nextPierId === target.pierId && time(target.observedAt) >= time(segment.observedAt)) {
                from = segment.previousPierId; startedAt = time(segment.segmentStartedAt); basis = segment.basis;
            } else if (previous && previous.target.pierId !== target.pierId
                && followsObservation(target, previous.target)
                && time(previous.target.expectedArrival) <= now
                && time(previous.target.expectedArrival) >= now - FRESHNESS) {
                // A cached snapshot can lose an expired nearest pier without a
                // new source timestamp. It still witnesses the same calling pair.
                const candidate = previous.target.pierId;
                if (routes.some((route) => {
                    const a = route.stopIds.indexOf(candidate), b = route.stopIds.indexOf(target.pierId);
                    return a >= 0 && b > a && (b === a + 1 || previous.following === target.pierId);
                })) {
                    from = candidate; startedAt = time(previous.target.expectedArrival); basis = 'observedTransition';
                }
            } else if (!previous || previous.target.pierId === target.pierId) {
                // Do not put a future origin departure on an incoming leg, or
                // choose arbitrarily between branch predecessors.
                const predecessors = new Set(routes.map((route) => {
                    const index = route.stopIds.indexOf(target.pierId);
                    return index > 0 ? route.stopIds[index - 1] : null;
                }));
                if (predecessors.size === 1 && !predecessors.has(null)) {
                    const candidate = [...predecessors][0];
                    let samples = this.timings.get(modelKey(target, candidate, target.pierId)) || [];
                    let timingBasis = 'predictedTravelTime';
                    // A newly started server may see only one boat approaching
                    // this pier. The same service's return journey can still
                    // teach this leg's approximate duration. Prefer the actual
                    // direction whenever available; never borrow another leg,
                    // service or an ambiguous branch's predecessor.
                    if (!samples.length) {
                        const reverseDirections = new Set(network.routes.filter((route) => {
                            const index = route.stopIds.indexOf(target.pierId);
                            return route.lineId === target.lineId && index >= 0
                                && route.stopIds[index + 1] === candidate
                                && (!target.direction || route.direction !== target.direction);
                        }).map((route) => route.direction));
                        samples = [...reverseDirections].flatMap((direction) =>
                            this.timings.get(modelKey({ ...target, direction }, target.pierId, candidate)) || []);
                        timingBasis = 'reverseTravelTime';
                    }
                    const durations = samples.map((sample) => sample.duration).sort((a, b) => a - b);
                    if (durations.length) {
                        const duration = durations[Math.floor(durations.length / 2)];
                        const start = time(target.expectedArrival) - duration;
                        if (start <= now) { from = candidate; startedAt = start; basis = timingBasis; }
                    }
                }
            }
            if (from && durationOK(time(target.expectedArrival) - startedAt) && startedAt <= now) {
                this.segments.set(key, {
                    id: key, lineId: target.lineId, previousPierId: from, nextPierId: target.pierId,
                    destination: target.destinationName, segmentStartedAt: new Date(startedAt).toISOString(),
                    expectedArrival: target.expectedArrival, observedAt: target.observedAt,
                    // The upstream cache TTL can end between 30-second polls.
                    // Our derived position keeps its own fixed 90-second bound;
                    // holding it never renews the original observation time.
                    expiresAt: new Date(Math.min(time(target.expectedArrival), time(target.observedAt) + FRESHNESS)).toISOString(), basis
                });
            } else {
                // Positive but incompatible evidence supersedes a held marker.
                this.segments.delete(key);
            }
            if (!previous || followsObservation(target, previous.target)) {
                this.history.set(key, { target, following: values[1]?.pierId });
            }
        }
        // Bound memory independently of feed identity churn and route discovery.
        for (const map of [this.history, this.segments, this.timings]) {
            while (map.size > 512) map.delete(map.keys().next().value);
        }
        return this.current(now);
    }
}
