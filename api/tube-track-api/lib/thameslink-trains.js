import { readFileSync } from 'node:fs';

// Where Thameslink trains are, estimated from station departure boards.
//
// TfL publishes no Thameslink vehicle positions and no train identities, only
// each station's list of calls. A train appears on the board of every station
// it has yet to call at, so the board of its *next* stop says when it gets
// there. This finds that next stop, confirms which way the train is going from
// its later calls on neighbouring boards, and walks back along the line by the
// learned run times to place it. Like the River Bus estimator it never guesses
// between two branches: a train that could have come from either side of a
// junction is left off the map rather than drawn on the wrong track.

const SECOND = 1_000;
const MAXIMUM_SEARCH_HOPS = 6;
// Fast trains skip a station or two; a next stop further away than this is too
// uncertain to draw.
const MAXIMUM_WALK_HOPS = 3;
const DEFAULT_SPEED_M_PER_S = 16;
const DEFAULT_DWELL_S = 30;
const RUN_TIME_SAMPLES = 9;
// Calls seen on earlier boards identify which branch a train came from once
// it has left that station and dropped off its board.
const HISTORY_LIFETIME = 30 * 60 * SECOND;

const NETWORK = JSON.parse(readFileSync(new URL('../data/thameslink-network.json', import.meta.url)));
const { coordinates: STOP_COORDINATES } = JSON.parse(
    readFileSync(new URL('../data/thameslink-directions.json', import.meta.url))
);

const time = (value) => {
    const parsed = Date.parse(value ?? '');
    return Number.isFinite(parsed) ? parsed : null;
};

function metres([lat1, lon1], [lat2, lon2]) {
    const radians = Math.PI / 180;
    const h = Math.sin((lat2 - lat1) * radians / 2) ** 2
        + Math.cos(lat1 * radians) * Math.cos(lat2 * radians) * Math.sin((lon2 - lon1) * radians / 2) ** 2;
    return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
}

export class ThameslinkNetwork {
    constructor(network = NETWORK, stopCoordinates = STOP_COORDINATES) {
        this.stations = new Map(network.stations.map((station) => [station.id, station]));
        this.neighbours = new Map([...this.stations.keys()].map((id) => [id, new Set()]));
        this.lengths = new Map();
        for (const segment of network.segments) {
            this.neighbours.get(segment.from).add(segment.to);
            this.neighbours.get(segment.to).add(segment.from);
            this.lengths.set(this.pair(segment.from, segment.to), segment.lengthM);
        }
        // Where the line leaves the map: trains bound beyond it head for the
        // nearest of these.
        this.exits = [...this.neighbours].filter(([, set]) => set.size === 1).map(([id]) => id);
        this.stopCoordinates = stopCoordinates;
        this.patterns = network.patterns ?? [];
        this.patternMemo = new Map();
    }

    /**
     * Which neighbouring track a train at `stationId` bound for
     * `destinationId` takes next (`ahead`) and came in on (`behind`),
     * according to TfL's calling patterns. Each is a set: a single entry is
     * certain; several mean patterns disagree; empty means no pattern knows.
     * `null` in `ahead` means the train leaves the map; in `behind`, that it
     * came onto it here.
     */
    pattern(stationId, destinationId) {
        const key = `${stationId}|${destinationId}`;
        if (this.patternMemo.has(key)) return this.patternMemo.get(key);
        const ahead = new Set();
        const behind = new Set();
        for (const stops of this.patterns) {
            const here = stops.indexOf(stationId);
            const end = stops.indexOf(destinationId, here + 1);
            if (here < 0 || end < 0) continue;
            const next = stops.slice(here + 1, end + 1).find((id) => this.stations.has(id));
            if (next) {
                ahead.add(this.route(this.paths(stationId), next)?.[1] ?? null);
            } else {
                // Leaves the map before its next call: by the edge nearest
                // the next place it stops.
                const exit = this.exitToward(stops[here + 1], stationId);
                ahead.add(exit === stationId ? null : this.route(this.paths(stationId), exit)?.[1] ?? null);
            }
            const previous = stops.slice(0, here).reverse().find((id) => this.stations.has(id));
            behind.add(previous ? this.route(this.paths(previous), stationId)?.at(-2) ?? null : null);
        }
        const result = { ahead, behind };
        this.patternMemo.set(key, result);
        return result;
    }

    exitToward(stopId, fromId) {
        return this.targets(stopId, fromId)[0] ?? null;
    }

    pair(a, b) { return a < b ? `${a}|${b}` : `${b}|${a}`; }

    /**
     * The mapped station a train at `fromId` bound for `destinationId` is
     * heading for: the destination itself, or the map edge that makes the
     * shortest way there (Peterborough leaves by New Barnet, not by Elstree,
     * although Elstree is nearer Peterborough as the crow flies).
     */
    target(destinationId, fromId) {
        return this.targets(destinationId, fromId)[0] ?? null;
    }

    /**
     * Every map edge a train could plausibly leave by, best first: Sevenoaks
     * is reached by way of Swanley or Orpington.
     */
    targets(destinationId, fromId) {
        if (this.stations.has(destinationId)) return [destinationId];
        const destination = this.stopCoordinates[destinationId];
        const from = this.stations.get(fromId);
        if (!destination || !from) return [];
        const ranked = this.exits.map((id) => {
            const exit = this.stations.get(id);
            const point = [exit.latitude, exit.longitude];
            return { id, distance: metres([from.latitude, from.longitude], point) + metres(point, destination) };
        }).sort((a, b) => a.distance - b.distance);
        return ranked.filter((exit) => exit.distance <= ranked[0].distance * 1.35).map((exit) => exit.id);
    }

    /** Hop-by-hop shortest paths from `start`, as a map of predecessors. */
    paths(start, maximumHops = Infinity) {
        const previous = new Map([[start, null]]);
        let frontier = [start];
        for (let hop = 0; hop < maximumHops && frontier.length; hop++) {
            const next = [];
            for (const id of frontier) {
                for (const neighbour of [...this.neighbours.get(id)].sort()) {
                    if (previous.has(neighbour)) continue;
                    previous.set(neighbour, id);
                    next.push(neighbour);
                }
            }
            frontier = next;
        }
        return previous;
    }

    /** Whether `to` can be reached from `from` without passing `avoiding`. */
    reachableWithout(from, to, avoiding) {
        if (from === to) return true;
        const seen = new Set([from, avoiding]);
        const frontier = [from];
        while (frontier.length) {
            for (const neighbour of this.neighbours.get(frontier.pop())) {
                if (neighbour === to) return true;
                if (!seen.has(neighbour)) { seen.add(neighbour); frontier.push(neighbour); }
            }
        }
        return false;
    }

    route(previous, end) {
        const route = [];
        for (let id = end; id !== undefined && id !== null; id = previous.get(id)) route.unshift(id);
        return previous.has(end) ? route : null;
    }
}

function normalisedRows(stopId, raw, now) {
    if (!Array.isArray(raw)) return [];
    return raw.flatMap((row) => {
        if (String(row?.departureStatus ?? '').toLowerCase() === 'cancelled') return [];
        const arrival = time(row.estimatedTimeOfArrival) ?? time(row.scheduledTimeOfArrival);
        const departure = time(row.estimatedTimeOfDeparture) ?? time(row.scheduledTimeOfDeparture);
        const destinationId = typeof row.destinationNaptanId === 'string' ? row.destinationNaptanId : null;
        const at = arrival ?? departure;
        if (!destinationId || at === null || at < now - 60 * SECOND) return [];
        return [{
            stopId, destinationId, arrival, departure, at,
            scheduledArrival: time(row.scheduledTimeOfArrival),
            destinationName: typeof row.destinationName === 'string'
                ? row.destinationName.replace(/ (Rail )?Station$/i, '').replace(/ \((London|Kent|Surrey|Beds|Herts)\)$/i, '')
                : null
        }];
    });
}

export class ThameslinkTrainEstimator {
    runTimes = new Map();
    history = new Map();

    constructor({ network = new ThameslinkNetwork() } = {}) {
        this.network = network;
    }

    /** Seconds between leaving `from` and arriving at `to`, learned or assumed. */
    runTime(from, to) {
        const samples = this.runTimes.get(`${from}>${to}`);
        if (samples?.length) {
            const sorted = [...samples].sort((a, b) => a - b);
            return sorted[Math.floor(sorted.length / 2)];
        }
        const length = this.network.lengths.get(this.network.pair(from, to));
        return length === undefined ? null : length / DEFAULT_SPEED_M_PER_S + DEFAULT_DWELL_S;
    }

    learn(from, to, seconds) {
        if (!(seconds >= 30 && seconds <= 30 * 60)) return;
        const key = `${from}>${to}`;
        this.runTimes.set(key, [...(this.runTimes.get(key) ?? []), seconds].slice(-RUN_TIME_SAMPLES));
    }

    routeSeconds(route) {
        let total = 0;
        for (let index = 1; index < route.length; index++) {
            const seconds = this.runTime(route[index - 1], route[index]);
            if (seconds === null) return null;
            total += seconds;
        }
        return total;
    }

    /**
     * @param boards Map of stop ID to raw TfL ArrivalDepartures rows.
     * @returns Estimated trains: the segment each is on, how far along it and
     *   how long until it reaches that segment's end.
     */
    estimate(boards, now = Date.now()) {
        const rows = [...boards].flatMap(([stopId, raw]) =>
            this.network.stations.has(stopId) ? normalisedRows(stopId, raw, now) : []);
        const byStopAndDestination = new Map();
        for (const row of rows) {
            const key = `${row.stopId}|${row.destinationId}`;
            if (!byStopAndDestination.has(key)) byStopAndDestination.set(key, []);
            byStopAndDestination.get(key).push(row);
        }

        // 1. Which way is each call's train going, and which later calls are
        //    the same train? A train's own later calls line up, station after
        //    station, with its run times; another train's calls match at most
        //    here and there. So each way out of the station is scored by how
        //    many consistent later calls lie that way, and the strongest wins.
        const forward = new Map();
        const shadowed = new Set();
        for (const row of rows) {
            if (row.stopId === row.destinationId) continue;
            const known = this.network.pattern(row.stopId, row.destinationId);
            const targets = this.network.targets(row.destinationId, row.stopId);
            const target = targets[0] ?? null;
            const paths = this.network.paths(row.stopId, MAXIMUM_SEARCH_HOPS);
            // Follow each way out as a chain: every later call must come one
            // run time after the previous matched call, so a different train
            // (the boards list two hours of them) rarely lines up twice.
            const directions = new Map();
            for (const [stationId] of paths) {
                if (stationId === row.stopId) continue;
                const route = this.network.route(paths, stationId);
                if (targets.length && !targets.some((id) => this.network.reachableWithout(route[1], id, row.stopId))) continue;
                const matches = this.chain(row, route, byStopAndDestination);
                const best = directions.get(route[1]);
                if (matches.length && (!best || matches.length > best.length)) directions.set(route[1], matches);
            }
            const ranked = [...directions].sort((a, b) => b[1].length - a[1].length);
            // TfL's patterns, when they agree, settle the direction; the
            // boards still say which later calls are this same train.
            if (known.ahead.size === 1) {
                const [direction] = known.ahead;
                forward.set(row, direction);
                for (const match of directions.get(direction) ?? []) shadowed.add(match.later);
                continue;
            }
            if (ranked.length && (ranked.length === 1 || ranked[0][1].length > ranked[1][1].length)) {
                const [direction, matches] = ranked[0];
                forward.set(row, direction);
                for (const match of matches) shadowed.add(match.later);
                const adjacent = matches.find((match) => match.route.length === 2);
                if (adjacent && row.departure !== null && adjacent.later.arrival !== null) {
                    this.learn(row.stopId, direction, (adjacent.later.arrival - row.departure) / SECOND);
                }
                continue;
            }
            // Equally good evidence both ways (only possible round the loop)
            // leaves the train off the map rather than guessing.
            if (ranked.length) continue;
            // No later call on the map: go by the destination (or the map edge
            // it leaves by). A train leaving the map here has no next station.
            if (!target) continue;
            if (target === row.stopId) { forward.set(row, null); continue; }
            const route = this.network.route(this.network.paths(row.stopId), target);
            if (route) forward.set(row, route[1]);
        }

        // Remember every call, so that once a train leaves a station the
        // board it left behind still says which branch it was on.
        for (const [key, value] of this.history) {
            if (value.seenAt < now - HISTORY_LIFETIME) this.history.delete(key);
        }
        for (const row of rows) {
            this.history.set(`${row.stopId}|${row.destinationId}|${row.scheduledArrival ?? row.at}`,
                { stopId: row.stopId, destinationId: row.destinationId, departure: row.departure ?? row.at, seenAt: now });
        }
        while (this.history.size > 5_000) this.history.delete(this.history.keys().next().value);

        // 2. Each remaining call is a train's next stop. Walk back along the
        //    line from it by run time to find the train.
        const trains = [];
        const seen = new Set();
        for (const row of rows) {
            if (shadowed.has(row) || !forward.has(row) || row.arrival === null) continue;
            // A train whose arrival has passed but which has not left yet is
            // standing at the platform.
            if (row.arrival <= now && !(row.departure !== null && row.departure > now)) continue;
            const position = this.place(row, forward.get(row), Math.max(1, (row.arrival - now) / SECOND), now,
                byStopAndDestination);
            if (!position) continue;
            const id = `thameslink:${row.destinationId}:${row.stopId}:${row.scheduledArrival ?? row.arrival}`;
            if (seen.has(id)) continue;
            seen.add(id);
            trains.push({
                id,
                lineId: 'thameslink',
                destination: row.destinationName,
                destinationStopId: row.destinationId,
                nextStopId: row.stopId,
                expectedArrival: new Date(row.arrival).toISOString(),
                ...position
            });
        }
        return trains.sort((a, b) => a.id.localeCompare(b.id));
    }

    /** The calls along `route` that are consistently this train's. */
    chain(row, route, byStopAndDestination) {
        const matches = [];
        let last = row;
        let seconds = 0;
        for (let index = 1; index < route.length; index++) {
            const run = this.runTime(route[index - 1], route[index]);
            if (run === null) break;
            seconds += run;
            let best = null;
            for (const later of byStopAndDestination.get(`${route[index]}|${row.destinationId}`) ?? []) {
                const gap = (later.at - (last.departure ?? last.at)) / SECOND;
                const error = Math.abs(gap - seconds);
                if (gap > 0 && error <= Math.max(90, seconds * 0.3) && (!best || error < best.error)) {
                    best = { later, error };
                }
            }
            if (!best) continue;
            matches.push({ route: route.slice(0, index + 1), later: best.later, error: best.error });
            last = best.later;
            seconds = 0;
        }
        return matches;
    }

    /**
     * At a junction, the branch whose board most recently lost a call for the
     * same destination at a time consistent with this train.
     */
    branch(candidates, next, row, remaining, now) {
        const arrival = now + remaining * SECOND;
        const departed = [...this.history.values()].filter((call) =>
            call.destinationId === row.destinationId && call.departure <= now);
        const matching = candidates.filter((candidate) => {
            // Fast trains skip the station next to a junction, so look a few
            // stations back along the branch for the call it last made.
            let from = next;
            let at = candidate;
            let seconds = 0;
            for (let hop = 0; hop < 3; hop++) {
                const run = this.runTime(at, from);
                if (run === null) return false;
                seconds += run;
                if (departed.some((call) => call.stopId === at
                    && Math.abs((arrival - call.departure) / SECOND - seconds) <= Math.max(90, seconds * 0.4))) return true;
                const onward = [...this.network.neighbours.get(at)].filter((id) => id !== from);
                if (onward.length !== 1) return false;
                from = at;
                at = onward[0];
            }
            return false;
        });
        return matching.length === 1 ? matching[0] : null;
    }

    place(row, forwardId, secondsToStop, now, byStopAndDestination = new Map()) {
        let next = row.stopId;
        let ahead = forwardId;
        let remaining = secondsToStop;
        for (let hop = 0; hop < MAXIMUM_WALK_HOPS; hop++) {
            // Whichever neighbour the train did not come from is where it is
            // going; the others are where it may have come from.
            const behind = [...this.network.neighbours.get(next)].filter((id) => id !== ahead);
            const known = [...this.network.pattern(next, row.destinationId).behind]
                .filter((id) => id === null || behind.includes(id));
            // Patterns that agree the train came onto the map here leave
            // nothing on the map to draw it on.
            if (known.length === 1 && known[0] === null) return null;
            const previous = behind.length === 1 ? behind[0]
                : known.length === 1 ? known[0] : this.branch(behind, next, row, remaining, now);
            if (!previous) return null;
            const seconds = this.runTime(previous, next);
            if (seconds === null) return null;
            if (remaining <= seconds) {
                return {
                    previousStationId: previous,
                    nextStationId: next,
                    progress: Math.max(0.02, Math.min(0.98, 1 - remaining / seconds)),
                    secondsToNextStation: Math.max(1, Math.round(remaining))
                };
            }
            remaining -= seconds;
            // Walking back past a station whose board still shows this train
            // to come (or starting there) means it has not reached the line
            // being walked: it is still there, or another call is its next one.
            const stillToCome = (byStopAndDestination.get(`${previous}|${row.destinationId}`) ?? [])
                .some((call) => (call.departure ?? call.at) > now
                    && Math.abs(((call.departure ?? call.at) - now) / SECOND - (-remaining)) <= Math.max(120, seconds));
            if (stillToCome) return null;
            ahead = next;
            next = previous;
        }
        return null;
    }
}
