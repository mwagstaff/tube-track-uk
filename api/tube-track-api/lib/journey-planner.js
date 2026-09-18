import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { JourneyDisruptions } from './journey-disruptions.js';
import { explicitInstant, parseJourneyTime, tflDateTime } from './journey-time.js';

const catalogue = JSON.parse(readFileSync(new URL('../data/journey-stations.json', import.meta.url)));
const MODES = 'tube,dlr,overground,elizabeth-line,tram';
const RAIL_MODES = new Set(MODES.split(','));
const ACCESSIBILITY = { none: 'NoRequirements', platform: 'StepFreeToPlatform', train: 'StepFreeToVehicle' };
const hash = (value) => createHash('sha256').update(value).digest('hex').slice(0, 20);
const clean = (value) => String(value ?? '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim();
const normalized = (value) => value.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();

export class JourneyError extends Error {
    constructor(code, message, status = 400) {
        super(message);
        this.code = code;
        this.status = status;
    }
}

export class JourneyPlanner {
    constructor({ client, clock = Date.now, stations = catalogue.stations, disruptions } = {}) {
        this.client = client;
        this.clock = clock;
        this.stations = stations;
        this.byId = new Map(stations.flatMap((s) => [s.id, ...s.stopIds].map((id) => [id, s])));
        this.stationIds = new Map();
        this.cache = new Map();
        this.inFlight = new Map();
        this.active = 0;
        this.budget = { start: clock(), used: 0 };
        this.disruptions = disruptions ?? new JourneyDisruptions({ fetch: (path, options) => this.fetch(path, options), stations, clock });
    }

    search(query = '') {
        if (typeof query !== 'string' || query.length > 100) {
            throw new JourneyError('INVALID_QUERY', 'Station searches must be no longer than 100 characters.');
        }
        const terms = normalized(query).trim().split(/\s+/);
        return this.stations.filter((s) => terms.every((term) =>
            normalized([s.name, ...s.aliases, s.id, ...s.stopIds].join(' ')).includes(term)
        )).sort((a, b) => Number(normalized(b.name).startsWith(normalized(query)))
            - Number(normalized(a.name).startsWith(normalized(query)))
            || a.name.localeCompare(b.name, 'en-GB'));
    }

    validate(query) {
        const allowed = new Set(['from', 'to', 'timeMode', 'time', 'accessibility']);
        if (Object.entries(query).some(([key, value]) => !allowed.has(key) || typeof value !== 'string')) {
            throw new JourneyError('INVALID_QUERY', 'Use one value per supported journey parameter.');
        }
        const from = this.byId.get(query.from?.toUpperCase());
        const to = this.byId.get(query.to?.toUpperCase());
        if (!from || !to) throw new JourneyError('UNKNOWN_STATION', 'Choose stations from the London rail station catalogue.', 422);
        if (from.id === to.id) throw new JourneyError('SAME_STATION', 'Choose a different destination.');
        const timeMode = query.timeMode ?? 'now';
        if (!['now', 'departAt', 'arriveBy'].includes(timeMode)) {
            throw new JourneyError('INVALID_TIME_MODE', 'Choose now, departAt or arriveBy.');
        }
        const now = this.clock();
        const requestedAt = timeMode === 'now' ? now : explicitInstant(query.time);
        if ((timeMode === 'now' && query.time !== undefined) || requestedAt === null
            || requestedAt < now - 60_000 || requestedAt > now + 60 * 86_400_000) {
            throw new JourneyError('INVALID_TIME', 'Choose a time within the next 60 days, including its UTC offset.');
        }
        const accessibility = query.accessibility ?? 'none';
        if (!Object.hasOwn(ACCESSIBILITY, accessibility)) {
            throw new JourneyError('INVALID_ACCESSIBILITY', 'Choose none, platform or train.');
        }
        return { from, to, timeMode, requestedAt, accessibility };
    }

    async fetch(path, options = {}) {
        const now = this.clock();
        if (now - this.budget.start >= 60_000) this.budget = { start: now, used: 0 };
        // Reserve room for the app's existing live/status feeds. This is global
        // to this service, not per IP (which can be a shared reverse proxy).
        if (this.budget.used >= 180) throw new JourneyError('RATE_LIMITED', 'Journey planning is busy. Please try again shortly.', 429);
        this.budget.used += 1;
        return this.client.fetchJSON(path, { ...options, metricLabel: options.metricLabel ?? 'journeys:primary', metricUrl: '/Journey' });
    }

    async stationId(station, signal) {
        const saved = this.stationIds.get(station.id);
        if (saved && this.clock() - saved.updatedAt < 86_400_000) return saved.id;
        // HUB identifiers aren't accepted by the planner. StopPoint resolves a
        // member into the interchange's ICS code, preserving all its rail modes.
        try {
            const stop = await this.fetch(`/StopPoint/${station.stopIds[0]}`, {
                signal: AbortSignal.any([signal, AbortSignal.timeout(2_000)]),
                metricLabel: 'journeys:station'
            });
            const id = /^\d+$/.test(stop.icsCode ?? '') ? stop.icsCode : station.stopIds[0];
            this.stationIds.set(station.id, { id, updatedAt: this.clock() });
            return id;
        } catch (error) {
            if (signal.aborted || error instanceof JourneyError) throw error;
            // A valid NaPTAN member is accepted by JourneyResults. Resolution is
            // an interchange enhancement, not a dependency for every journey.
            return saved?.id ?? station.stopIds[0];
        }
    }

    async plan(query) {
        const request = this.validate(query);
        const key = JSON.stringify([request.from.id, request.to.id, request.timeMode,
            request.timeMode === 'now' ? Math.floor(request.requestedAt / 15_000) : request.requestedAt,
            request.accessibility]);
        let entry = this.cache.get(key);
        const cached = !!entry && entry.expiresAt > this.clock();
        if (!cached) {
            let pending = this.inFlight.get(key);
            if (!pending) {
                if (this.active >= 2) throw new JourneyError('RATE_LIMITED', 'Journey planning is busy. Please try again shortly.', 429);
                this.active += 1;
                pending = this.load(request).catch((error) => {
                    if (['TimeoutError', 'AbortError'].includes(error.name) || error.code === 'TFL_TIMEOUT') {
                        throw new JourneyError('UPSTREAM_UNAVAILABLE', 'TfL is taking too long to plan this journey. Please try again shortly.', 503);
                    }
                    if (error.name === 'TfLRequestError') {
                        throw new JourneyError('UPSTREAM_UNAVAILABLE', 'TfL journey planning is temporarily unavailable. Please try again shortly.', 503);
                    }
                    throw error;
                }).finally(() => {
                    this.active -= 1;
                    this.inFlight.delete(key);
                });
                this.inFlight.set(key, pending);
            }
            entry = await pending;
            this.cache.delete(key);
            this.cache.set(key, entry);
            while (this.cache.size > 128) this.cache.delete(this.cache.keys().next().value);
        }
        const choices = selectJourneys(entry.journeys, request, this.clock());
        const messages = [...entry.messages];
        if (!choices.length) messages.push('No rail journeys match this search. Try another time or accessibility preference.');
        if (choices[0]?.disruptionScore > 0 && !choices.some((j) => j.labels.includes('lessDisrupted'))) {
            messages.push('No less-disrupted rail alternative was returned for this search.');
        }
        return {
            data: {
                from: request.from, to: request.to, timeMode: request.timeMode,
                requestedAt: new Date(request.requestedAt).toISOString(), accessibility: request.accessibility,
                journeys: choices, messages: [...new Set(messages)],
                expiresAt: new Date(entry.expiresAt).toISOString(),
                attribution: 'Powered by the Transport for London Journey Planner API'
            },
            meta: { updatedAt: new Date(entry.updatedAt).toISOString(), cached, stale: false, source: 'tfl', timezone: 'Europe/London' }
        };
    }

    async load(request) {
        // Bound the whole search, including cold station lookups and fallback,
        // to less than the mobile client's 20-second request timeout.
        const signal = AbortSignal.timeout(18_000);
        const [from, to] = await Promise.all([this.stationId(request.from, signal), this.stationId(request.to, signal)]);
        const queryTime = request.timeMode === 'arriveBy'
            ? Math.floor(request.requestedAt / 60_000) * 60_000
            : Math.ceil(request.requestedAt / 60_000) * 60_000;
        const query = {
            ...tflDateTime(queryTime), timeIs: request.timeMode === 'arriveBy' ? 'Arriving' : 'Departing',
            mode: MODES, journeyPreference: 'LeastTime', includeAlternativeRoutes: 'true',
            calcOneDirection: 'true', useRealTimeLiveArrivals: 'true', applyHtmlMarkup: 'false',
            accessibilityPreference: ACCESSIBILITY[request.accessibility]
        };
        const path = `/Journey/JourneyResults/${from}/to/${to}`;
        let response;
        try {
            try {
                response = await this.fetch(path, { query, signal, timeoutMs: 12_000 });
            } catch (error) {
                // One retry for transient failures, still inside the overall
                // deadline and shared call budget. Never retry validation/429.
                if (signal.aborted || !(error.code === 'TFL_TIMEOUT'
                    || error.code === 'TFL_REQUEST_FAILED' || [502, 503, 504].includes(error.status))) throw error;
                response = await this.fetch(path, { query, signal, timeoutMs: 12_000, metricLabel: 'journeys:retry' });
            }
        } catch (error) {
            if (error.status === 300) throw new JourneyError('STATION_UNRESOLVED', 'TfL could not resolve these stations. Try another station.', 422);
            throw error;
        }
        if (!Array.isArray(response.journeys)) {
            throw new JourneyError('UPSTREAM_UNAVAILABLE', 'Journey planning is temporarily unavailable.', 503);
        }
        let journeys = response.journeys.map((j) => normalizeJourney(j, request)).filter(Boolean);
        const messages = (response.stopMessages ?? []).map(clean).filter(Boolean);
        // One bounded secondary search can find a useful different route. Never
        // manufacture a bypass or silently expand into buses/National Rail.
        if (journeys.length && (new Set(journeys.map((j) => j.routeKey)).size < 2
            || journeys.every((j) => j.disruptionScore > 0))) {
            try {
                const alternative = await this.fetch(path, {
                    query: { ...query, journeyPreference: 'LeastInterchange' },
                    signal: AbortSignal.any([signal, AbortSignal.timeout(2_500)]),
                    metricLabel: 'journeys:alternative'
                });
                journeys = journeys.concat((alternative.journeys ?? []).map((j) => normalizeJourney(j, request)).filter(Boolean));
            } catch {
                messages.push('Additional alternatives could not be checked.');
            }
        }
        const snapshot = await this.disruptions.snapshot(journeys, signal);
        journeys = this.disruptions.enrich(journeys, snapshot);
        if (journeys.some(j => ['partial', 'unavailable'].includes(j.disruption.coverage))) {
            messages.push('Some disruption information is unavailable. Check the notices before travelling.');
        }
        const updatedAt = this.clock();
        const recommended = Number(response.recommendedMaxAgeMinutes) * 60_000;
        const lifetime = Math.min(request.timeMode === 'now' ? 20_000 : 60_000,
            Number.isFinite(recommended) && recommended > 0 ? recommended : 20_000);
        const sourceExpiry = Object.values(snapshot).filter(s => s.status !== 'notApplicable')
            .map(s => s.expiresAt ?? updatedAt + 5_000);
        return { journeys, messages, updatedAt, expiresAt: Math.min(updatedAt + lifetime, ...sourceExpiry) };
    }
}

function normalizeWarning(raw, index) {
    const message = clean(raw.description || raw.summary);
    if (!message || /^(?:[^:]+:\s*)?(?:good service(?: on (?:all|other) (?:lines|routes))?|no (?:issues|disruption)(?: reported)?)[.!]?$/i.test(message)) return null;
    const accessibility = raw.type !== 'lineInfo'
        && /step.free|\blift\b|elevator|escalator|accessible/i.test(message)
        && !/severe delays|minor delays|suspended|no service/i.test(message);
    const kind = accessibility ? 'accessibility' : raw.type === 'lineInfo' ? 'line'
        : raw.type === 'stopInfo' ? 'station' : raw.category === 'PlannedWork' ? 'plannedWork' : 'information';
    // Accessibility notices are retained but don't imply a timing delay. TfL
    // can attach a notice about another platform at the same interchange.
    const severity = accessibility ? 'information'
        : /severe delays|suspend|suspension|not running|no service|part closure|closed|closure/i.test(message) ? 'severe'
            : /minor delays|reduced service|delays/i.test(message) ? 'minor' : 'information';
    return { id: hash(`${index}:${message}`), message, kind, severity };
}

export function normalizeJourney(raw, request) {
    if (!Array.isArray(raw.legs) || !raw.legs.length) return null;
    const departure = parseJourneyTime(raw.startDateTime, request.requestedAt);
    const arrival = parseJourneyTime(raw.arrivalDateTime, departure ?? request.requestedAt);
    if (departure === null || arrival === null || arrival < departure) return null;
    const legs = [];
    let anchor = departure;
    for (const [index, leg] of raw.legs.entries()) {
        const mode = leg.mode?.id;
        if (!RAIL_MODES.has(mode) && mode !== 'walking') return null;
        const start = parseJourneyTime(leg.departureTime, anchor);
        const end = parseJourneyTime(leg.arrivalTime, start ?? anchor);
        if (start === null || end === null || end < start || start < anchor) return null;
        anchor = end;
        const point = (p) => ({ id: p?.naptanId ?? p?.id ?? '', name: clean(p?.commonName), platform: clean(p?.platformName) || null });
        const lines = (leg.routeOptions ?? []).map((r) => ({
            id: r.lineIdentifier?.id ?? r.id ?? '', name: clean(r.lineIdentifier?.name ?? r.name),
            direction: clean(r.directions?.join(' / '))
        })).filter((line) => line.name);
        const warnings = [...(leg.disruptions ?? []), ...(leg.plannedWorks ?? []).map((w) => ({ ...w, category: 'PlannedWork' }))]
            .map((w) => normalizeWarning(w, index)).filter(Boolean);
        const scheduledDeparture = parseJourneyTime(leg.scheduledDepartureTime, start);
        const scheduledArrival = parseJourneyTime(leg.scheduledArrivalTime, end);
        legs.push({
            id: String(index), mode, instruction: clean(leg.instruction?.summary),
            from: point(leg.departurePoint), to: point(leg.arrivalPoint), lines,
            departureTime: new Date(start).toISOString(), arrivalTime: new Date(end).toISOString(),
            scheduledDepartureTime: scheduledDeparture === null ? null : new Date(scheduledDeparture).toISOString(),
            scheduledArrivalTime: scheduledArrival === null ? null : new Date(scheduledArrival).toISOString(),
            timing: scheduledDeparture !== null && scheduledDeparture !== start
                || scheduledArrival !== null && scheduledArrival !== end ? 'adjusted' : 'estimated',
            durationMinutes: Math.round((end - start) / 60_000), warnings,
            stops: (leg.path?.stopPoints ?? []).map((p) => ({ id: p.id ?? '', name: clean(p.name) }))
        });
    }
    if (anchor > arrival || !legs.some((l) => RAIL_MODES.has(l.mode))) return null;
    const routeKey = legs.map((l) => `${l.mode}:${l.from.id}:${l.to.id}:${l.lines.map((v) => v.id).sort().join(',')}`).join('|');
    const warnings = [...new Map(legs.flatMap((l) => l.warnings).map((w) => [w.message, w])).values()];
    const score = warnings.reduce((sum, w) => sum + (w.severity === 'severe' ? 10 : w.severity === 'minor' ? 1 : 0), 0);
    return {
        id: hash(`${routeKey}:${departure}`), routeKey,
        departureTime: new Date(departure).toISOString(), arrivalTime: new Date(arrival).toISOString(),
        durationMinutes: Math.round((arrival - departure) / 60_000),
        changes: Math.max(0, legs.filter((l) => RAIL_MODES.has(l.mode)).length - 1),
        walkingMinutes: legs.filter((l) => l.mode === 'walking').reduce((s, l) => s + l.durationMinutes, 0),
        disruptionScore: score, warnings, legs, labels: []
    };
}

export function selectJourneys(journeys, request, now) {
    const valid = journeys.filter((j) => +new Date(j.departureTime) >= now
        && (request.timeMode === 'arriveBy' ? +new Date(j.arrivalTime) <= request.requestedAt
            : +new Date(j.departureTime) >= request.requestedAt));
    valid.sort((a, b) => request.timeMode === 'arriveBy'
        ? b.departureTime.localeCompare(a.departureTime) || a.durationMinutes - b.durationMinutes
        : a.arrivalTime.localeCompare(b.arrivalTime) || a.changes - b.changes || a.walkingMinutes - b.walkingMinutes);
    const unique = [...new Map(valid.toReversed().map((j) => [j.routeKey, j])).values()].reverse();
    if (!unique.length) return [];
    const first = unique[0];
    const lessDisrupted = unique.slice(1).filter((j) => j.disruptionScore < first.disruptionScore
        && (!j.disruption || j.disruption.coverage === 'complete'))
        .sort((a, b) => a.disruptionScore - b.disruptionScore)[0];
    const selected = [first, ...(lessDisrupted ? [lessDisrupted] : []),
        ...unique.slice(1).filter((j) => j !== lessDisrupted)].slice(0, 3);
    return selected.map(({ routeKey, ...j }, index) => ({
        ...j, labels: index === 0 ? [request.timeMode === 'arriveBy' ? 'latestDeparture' : 'earliestArrival']
            : j.id === lessDisrupted?.id ? ['lessDisrupted'] : [],
        waitingMinutes: request.timeMode === 'arriveBy' ? 0
            : Math.max(0, Math.round((+new Date(j.departureTime) - request.requestedAt) / 60_000))
    }));
}
