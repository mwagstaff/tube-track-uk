import { readFileSync } from 'node:fs';
import { randomUUID, createHash } from 'node:crypto';
import { Router } from 'express';
import { JourneyError, selectJourneys } from './journey-planner.js';
import { JourneyDisruptions } from './journey-disruptions.js';
import { explicitInstant } from './journey-time.js';

const stations = JSON.parse(readFileSync(new URL('../data/combined-stations.json', import.meta.url))).stations;
const byID = new Map(stations.flatMap(s => [s.id, ...s.stopIds].map(id => [id.toUpperCase(), s])));
const byCRS = new Map(stations.flatMap(s => s.railCodes.map(code => [code, s])));
const operators = {
    SE: ['southeastern', 'Southeastern'], SW: ['south-western-railway', 'South Western Railway'],
    SN: ['southern', 'Southern'], TL: ['thameslink', 'Thameslink'], GN: ['great-northern', 'Great Northern'],
    GW: ['great-western-railway', 'Great Western Railway'], LE: ['greater-anglia', 'Greater Anglia'],
    CC: ['c2c', 'c2c'], CH: ['chiltern-railways', 'Chiltern Railways'],
    VT: ['avanti-west-coast', 'Avanti West Coast'], EM: ['east-midlands-railway', 'East Midlands Railway'],
    GR: ['london-north-eastern-railway', 'LNER'], LM: ['west-midlands-trains', 'West Midlands Trains'],
    HX: ['heathrow-express', 'Heathrow Express'], GX: ['gatwick-express', 'Gatwick Express'],
    LO: ['london-overground', 'London Overground'], XR: ['elizabeth', 'Elizabeth line']
};
const hash = value => createHash('sha256').update(value).digest('hex').slice(0, 24);
const clean = value => String(value ?? '').replace(/<[^>]*>/g, '').trim();
const minute = (a, b) => Math.max(0, Math.round((Date.parse(b) - Date.parse(a)) / 60000));
const warning = (value, kind = 'information') => typeof value === 'object' && value?.message
    ? value : { id: hash(String(value)), message: clean(value), kind, severity: 'information' };

export function validateCombinedQuery(query, now = Date.now()) {
    if (Object.entries(query).some(([key, value]) => !['from', 'to', 'timeMode', 'time', 'accessibility', 'via'].includes(key)
        || typeof value !== 'string')) throw new JourneyError('INVALID_QUERY', 'Use one value per supported journey parameter.');
    const from = byID.get(query.from?.toUpperCase()), to = byID.get(query.to?.toUpperCase());
    if (!from || !to) throw new JourneyError('UNKNOWN_STATION', 'Choose stations shown on the map.', 422);
    if (from.id === to.id) throw new JourneyError('SAME_STATION', 'Choose a different destination.');
    const timeMode = query.timeMode ?? 'now', accessibility = query.accessibility ?? 'none';
    if (!['now', 'departAt', 'arriveBy'].includes(timeMode)) throw new JourneyError('INVALID_TIME_MODE', 'Choose a valid journey time mode.');
    const requestedAt = timeMode === 'now' ? now : explicitInstant(query.time);
    if (requestedAt === null || (timeMode === 'now' && query.time !== undefined)
        || requestedAt < now - 60000 || requestedAt > now + 60 * 86400000) {
        throw new JourneyError('INVALID_TIME', 'Choose a time within the next 60 days, including its UTC offset.');
    }
    if (!['none', 'platform', 'train'].includes(accessibility)) throw new JourneyError('INVALID_ACCESSIBILITY', 'Choose a valid accessibility preference.');
    const via = query.via ? query.via.split(',').map(id => byID.get(id.toUpperCase())) : [];
    if (via.length > 4 || via.some(s => !s) || new Set([from.id, ...via.map(s => s?.id), to.id]).size !== via.length + 2) {
        throw new JourneyError('INVALID_VIA', 'Choose up to four different via stations, in travel order.');
    }
    return { from, to, requestedAt, timeMode, accessibility, via };
}

function point(raw) {
    const station = byCRS.get(raw?.crs);
    return { id: raw?.id ?? station?.id ?? `nr:${raw?.crs}`, name: clean(raw?.name ?? station?.name ?? raw?.crs), platform: null };
}

function transferLeg(raw, from, to, departure, arrival, instruction, mode = 'transfer') {
    return { mode, instruction, from, to, departureTime: departure, arrivalTime: arrival,
        scheduledDepartureTime: null, scheduledArrivalTime: null, timing: 'scheduled', lines: [], stops: [],
        warnings: (raw.warnings ?? []).map(v => warning(v)), durationMinutes: minute(departure, arrival) };
}

export function normalizeCombinedJourney(raw) {
    if (!Array.isArray(raw.legs) || !raw.legs.length) return null;
    const legs = [];
    for (const leg of raw.legs) {
        if (leg.live?.cancelled || leg.live?.status === 'cancelled') return null;
        const from = point(leg.from), to = point(leg.to);
        const local = leg.localJourney;
        if (local?.status === 'available') {
            const steps = local.steps ?? [];
            if (!steps.length) return null;
            if (Date.parse(steps[0].departureTime) > Date.parse(leg.departure)) {
                legs.push(transferLeg(leg, from, steps[0].from, leg.departure, steps[0].departureTime,
                    `Allow time to reach ${steps[0].from.name} and board the service`));
            }
            const mappedPoint = value => byCRS.has(value.id) ? { ...value, id: byCRS.get(value.id).id } : value;
            legs.push(...steps.map(step => ({ ...step, from: mappedPoint(step.from), to: mappedPoint(step.to), source: step.source ?? 'tfl',
                warnings: [...(step.warnings ?? []), ...(local.notes ?? []).map(v => warning(v))] })));
            if (Date.parse(steps.at(-1).arrivalTime) < Date.parse(leg.arrival)) {
                legs.push(transferLeg(leg, steps.at(-1).to, to, steps.at(-1).arrivalTime, leg.arrival,
                    `Allow time to reach the onward platform at ${to.name}`));
            }
        } else if (leg.kind === 'vehicle' && ['rail', 'replacementBus'].includes(leg.mode)) {
            const [operatorID, fallbackName] = operators[leg.operator] ?? [`national-rail:${leg.operator}`, leg.operator || 'National Rail'];
            const operatorName = clean(leg.operatorBranding?.name || fallbackName);
            const colour = /^#[0-9a-f]{6}$/i.test(leg.operatorBranding?.colour ?? '') ? leg.operatorBranding.colour : undefined;
            const live = leg.live && !['unknown', 'unavailable'].includes(leg.live.status)
                && Number.isFinite(Date.parse(leg.live.departure)) && Number.isFinite(Date.parse(leg.live.arrival));
            const notices = [...(leg.warnings ?? []), ...(leg.live?.warnings ?? [])];
            if (!live) notices.push('Live times are unavailable for this service; timetable times are shown.');
            legs.push({ mode: leg.mode === 'replacementBus' ? 'replacement-bus' : 'national-rail',
                instruction: `${leg.mode === 'replacementBus' ? 'Take the official replacement bus' : `Take ${operatorName}`} to ${to.name}`,
                from: { ...from, platform: leg.live?.platform ?? leg.platform ?? null }, to,
                departureTime: leg.departure, arrivalTime: leg.arrival,
                scheduledDepartureTime: leg.scheduledDeparture ?? leg.departure,
                scheduledArrivalTime: leg.scheduledArrival ?? leg.arrival,
                timing: live ? 'live' : 'scheduled', source: 'national-rail', serviceID: leg.serviceId,
                liveUpdatedAt: leg.live?.updatedAt ?? null,
                lines: [{ id: operatorID, name: operatorName, direction: to.name, operatorCode: leg.operator, ...(colour ? { colour } : {}) }],
                durationMinutes: minute(leg.departure, leg.arrival), warnings: notices.map(v => warning(v)),
                stops: (leg.callingPoints ?? []).map(call => point(call.station)) });
        } else if (leg.kind === 'transfer' && ['walk', 'interchange', 'tubeTransfer'].includes(leg.mode)) {
            legs.push(transferLeg(leg, from, to, leg.departure, leg.arrival,
                leg.mode === 'walk' ? `Walk to ${to.name}` : leg.mode === 'tubeTransfer'
                    ? `Transfer to ${to.name} using the railway timetable allowance; TfL directions are unavailable`
                    : `Change at ${to.name}; allow ${minute(leg.departure, leg.arrival)} minutes`,
                leg.mode === 'walk' ? 'walking' : 'transfer'));
            if (local?.status !== 'available') legs.at(-1).warnings.push(...(local?.notes ?? []).map(v => warning(v)));
        } else return null; // Never silently drop an unsupported transport leg.
    }
    let previous = Date.parse(raw.departure);
    if (!Number.isFinite(previous) || !Number.isFinite(Date.parse(raw.arrival))) return null;
    for (const [index, leg] of legs.entries()) {
        const start = Date.parse(leg.departureTime), end = Date.parse(leg.arrivalTime);
        if (!Number.isFinite(start) || !Number.isFinite(end) || start < previous || end < start) return null;
        leg.id = String(index);
        previous = end;
    }
    if (previous > Date.parse(raw.arrival)) return null;
    const routeKey = legs.map(l => `${l.mode}:${l.from.id}:${l.to.id}:${l.lines.map(v => v.id).join(',')}`).join('|');
    const warnings = [...new Map([...(raw.warnings ?? []).map(v => warning(v)), ...legs.flatMap(l => l.warnings)]
        .map(w => [w.message, w])).values()];
    for (const value of raw.warnings ?? []) legs[0].warnings.push(warning(value));
    return { id: hash(`${raw.id}:${routeKey}:${raw.departure}`), routeKey,
        departureTime: raw.departure, arrivalTime: raw.arrival, durationMinutes: minute(raw.departure, raw.arrival),
        changes: raw.changes, walkingMinutes: legs.filter(l => l.mode === 'walking').reduce((sum, l) => sum + l.durationMinutes, 0),
        disruptionScore: 0, warnings, legs, labels: [] };
}

export class CombinedJourneys {
    constructor({ fetch: request = globalThis.fetch, now = Date.now, tflPlanner,
        baseURL = process.env.TRAINTRACK_PLANNER_URL ?? 'https://api.skynolimit.dev/train-track/api/v5/journey-planner', disruptions } = {}) {
        this.fetch = request; this.now = now; this.baseURL = baseURL.replace(/\/$/, '');
        this.jobs = new Map(); this.tflPlanner = tflPlanner;
        this.disruptions = disruptions ?? (tflPlanner?.stations && new JourneyDisruptions({
            fetch: (path, options) => tflPlanner.fetch(path, options), stations: tflPlanner.stations, clock: now, nonVehicleModes: ['walking', 'transfer']
        }));
        if (!disruptions && this.disruptions) {
            this.disruptions.lineIDs = [...new Set([...this.disruptions.lineIDs,
                ...Object.values(operators).map(([id]) => id).filter(id => id !== 'london-overground')])];
        }
    }

    prune() { for (const [id, job] of this.jobs) if (job.expires < this.now()) this.jobs.delete(id); }

    async upstream(path, { signal, ...options } = {}) {
        try {
            const response = await this.fetch(`${this.baseURL}${path}`, { ...options, redirect: 'error',
                signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(8000)]),
                headers: { Accept: 'application/json', 'Content-Type': 'application/json', ...options.headers } });
            if (response.status === 204) return null;
            const body = await response.json();
            if (!response.ok) throw new JourneyError(body.error?.code ?? 'UPSTREAM_UNAVAILABLE',
                body.error?.message ?? 'Combined journey planning is temporarily unavailable.', response.status);
            return body;
        } catch (error) {
            if (error instanceof JourneyError) throw error;
            throw new JourneyError('UPSTREAM_UNAVAILABLE', 'Combined journey planning is temporarily unavailable. Please try again.', 503);
        }
    }

    async start(query, client, signal) {
        const request = validateCombinedQuery(query, this.now());
        this.prune();
        if (this.jobs.size >= 128) throw new JourneyError('RATE_LIMITED', 'Journey planning is busy. Try again shortly.', 429);
        const id = randomUUID();
        if (request.via.length) {
            const points = [request.from, ...request.via, request.to];
            const index = request.timeMode === 'arriveBy' ? points.length - 2 : 0;
            const job = { request, points, index, parts: [], client, expires: this.now() + 600000 };
            this.jobs.set(id, job);
            try { job.child = await this.start(this.segmentQuery(job), client, signal); }
            catch (error) { this.jobs.delete(id); throw error; }
            return { id, status: 'running', pollAfterMs: 1000 };
        }
        let upstream;
        try { upstream = await this.upstream('/search-jobs', { method: 'POST', signal,
            headers: { 'X-Planner-Client': client, 'Idempotency-Key': id },
            body: JSON.stringify({ origin: request.from.id, destination: request.to.id,
                time: new Date(request.requestedAt).toISOString(), timeType: request.timeMode === 'arriveBy' ? 'arriveBy' : 'departAfter',
                accessibility: request.accessibility }) }); }
        catch (error) {
            if (signal?.aborted || ![404, 429, 502, 503, 504].includes(error.status)) throw error;
            const result = await this.fallback(request).catch(() => { throw error; });
            this.jobs.set(id, { request, result, expires: this.now() + 600000 });
            return { id, status: 'completed', pollAfterMs: 1000, result };
        }
        if (!/^[a-f0-9-]{36}$/.test(upstream?.id ?? '')) throw new JourneyError('UPSTREAM_UNAVAILABLE', 'Invalid search response.', 503);
        this.jobs.set(id, { upstreamID: upstream.id, request, expires: this.now() + 600000 });
        return { id, status: upstream.status, pollAfterMs: 1000 };
    }

    async poll(id, signal) {
        this.prune();
        const job = this.jobs.get(id);
        if (!job) throw new JourneyError('SEARCH_EXPIRED', 'This search expired. Please search again.', 410);
        if (job.result) return { id, status: 'completed', pollAfterMs: 1000, result: job.result };
        if (job.child) return this.pollVia(id, job, signal);
        const upstream = await this.upstream(`/search-jobs/${job.upstreamID}`, { signal });
        if (upstream.status === 'failed') {
            try {
                job.result = await this.fallback(job.request);
                return { id, status: 'completed', pollAfterMs: 1000, result: job.result };
            } catch { /* Return the original actionable combined-search failure. */ }
        }
        if (upstream.status !== 'completed') return { id, status: upstream.status, pollAfterMs: 1000,
            ...(upstream.error ? { error: upstream.error } : {}) };
        if (!Array.isArray(upstream.result?.journeys)) throw new JourneyError('UPSTREAM_UNAVAILABLE', 'Invalid journey response.', 503);
        let journeys = upstream.result.journeys.map(normalizeCombinedJourney).filter(Boolean);
        const warnings = upstream.result.warnings ?? [];
        const messages = [...warnings.filter(message => message.startsWith('TfL: ')),
            ...warnings.filter(message => !message.startsWith('TfL: '))];
        let disruptionExpiry = this.now() + 20000;
        if (this.disruptions && journeys.length) {
            const snapshot = await this.disruptions.snapshot(journeys, signal ?? AbortSignal.timeout(3000));
            journeys = this.disruptions.enrich(journeys, snapshot);
            disruptionExpiry = Math.min(disruptionExpiry, ...Object.values(snapshot).map(s => s.expiresAt ?? disruptionExpiry));
        }
        if (journeys.some(j => j.disruption && j.disruption.coverage !== 'complete')) {
            messages.push('Some disruption information is unavailable. Check the notices before travelling.');
        }
        journeys = imminentJourneyCandidates(journeys, job.request, this.now());
        const choices = selectJourneys(journeys, job.request, this.now());
        // Preserve a useful fewer-change option among the existing three slots.
        const fewest = journeys.filter(j => j.changes < (choices[0]?.changes ?? 0)
            && Date.parse(j.departureTime) >= Math.max(this.now(), job.request.timeMode === 'arriveBy' ? this.now() : job.request.requestedAt)
            && (job.request.timeMode !== 'arriveBy' || Date.parse(j.arrivalTime) <= job.request.requestedAt))
            .sort((a, b) => a.changes - b.changes || a.arrivalTime.localeCompare(b.arrivalTime))[0];
        if (fewest) {
            const existing = choices.find(j => j.id === fewest.id);
            if (existing) existing.labels.push('fewerChanges');
            else {
                const { routeKey, ...choice } = fewest;
                const item = { ...choice, labels: ['fewerChanges'], waitingMinutes: Math.max(0, minute(new Date(job.request.requestedAt).toISOString(), choice.departureTime)) };
                if (choices.length < 3) choices.push(item); else choices[2] = item;
            }
        }
        if (!choices.length && upstream.result.search?.searchTruncated) {
            const notices = messages.filter(message => message.startsWith('TfL: ')).slice(0, 2);
            throw new JourneyError('SEARCH_INCOMPLETE', [...notices,
                'Journey connections could not all be checked. Please try again later.'].join(' '), 503);
        }
        if (!choices.length) messages.push('No usable journeys were found. Try another time.');
        if (upstream.result.search?.searchTruncated) messages.push('Some alternatives could not be checked within this search.');
        const expiresAt = Math.min(Date.parse(upstream.result.expiresAt) || this.now(), disruptionExpiry);
        job.result = { data: { from: job.request.from, to: job.request.to, timeMode: job.request.timeMode,
            requestedAt: new Date(job.request.requestedAt).toISOString(), accessibility: job.request.accessibility,
            journeys: choices, messages: [...new Set(messages)], expiresAt: new Date(expiresAt).toISOString(),
            attribution: 'Journey information from TrainTrack UK, National Rail and the Transport for London Journey Planner API' },
        meta: { updatedAt: new Date(this.now()).toISOString(), cached: false, stale: expiresAt <= this.now(), source: 'combined', timezone: 'Europe/London' } };
        return { id, status: 'completed', pollAfterMs: 1000, result: job.result };
    }

    async cancel(id) {
        const job = this.jobs.get(id); this.jobs.delete(id);
        if (job?.child) await this.cancel(job.child.id);
        if (job?.upstreamID) await this.upstream(`/search-jobs/${job.upstreamID}`, { method: 'DELETE' });
    }

    segmentQuery(job) {
        const backward = job.request.timeMode === 'arriveBy';
        const previous = backward ? job.parts[0] : job.parts.at(-1);
        // Explicit conservative interchange allowance, never zero-time stitching.
        const time = previous ? Date.parse(backward ? previous.departureTime : previous.arrivalTime)
            + (backward ? -1 : 1) * 5 * 60000 : job.request.requestedAt;
        return { from: job.points[job.index].id, to: job.points[job.index + 1].id,
            timeMode: backward ? 'arriveBy' : 'departAt', time: new Date(time).toISOString(),
            accessibility: job.request.accessibility };
    }

    async pollVia(id, job, signal) {
        const child = await this.poll(job.child.id, signal);
        if (child.status !== 'completed') return { ...child, id };
        const from = job.points[job.index], to = job.points[job.index + 1];
        if (this.tflPlanner && [from, to].every(s => s.stopIds.some(id => id.startsWith('940GZZDL')))) {
            try {
                const query = this.segmentQuery(job);
                const direct = await this.tflPlanner.plan({ ...query, from: from.tflId, to: to.tflId }, { transfer: true, mode: 'dlr' });
                child.result.data.journeys.push(...direct.data.journeys);
                child.result.data.messages.push(...direct.data.messages);
                child.result.data.expiresAt = new Date(Math.min(Date.parse(child.result.data.expiresAt), Date.parse(direct.data.expiresAt))).toISOString();
                child.result.data.journeys.sort((a, b) => job.request.timeMode === 'arriveBy'
                    ? b.departureTime.localeCompare(a.departureTime) : a.arrivalTime.localeCompare(b.arrivalTime));
            } catch { child.result.data.messages.push('Direct DLR alternatives could not be checked.'); }
        }
        const part = child.result.data.journeys[0];
        if (!part) return { id, status: 'failed', pollAfterMs: 1000,
            error: { code: 'NO_VIA_ROUTE', message: 'No connection was found through the selected via stations. Try another time or route.' } };
        job.expiry = Math.min(job.expiry ?? Infinity, Date.parse(child.result.data.expiresAt));
        job.messages = [...(job.messages ?? []), ...child.result.data.messages];
        const backward = job.request.timeMode === 'arriveBy';
        job.options ??= [];
        if (backward) { job.parts.unshift(part); job.options.unshift(child.result.data.journeys); }
        else { job.parts.push(part); job.options.push(child.result.data.journeys); }
        await this.cancel(job.child.id);
        job.index += backward ? -1 : 1;
        if (job.index >= 0 && job.index < job.points.length - 1) {
            job.child = await this.start(this.segmentQuery(job), job.client, signal);
            return { id, status: 'running', pollAfterMs: 1000 };
        }
        const choices = combineViaChoices(job.options, job.request.timeMode);
        if (!choices.length) throw new JourneyError('NO_VIA_ROUTE', 'No catchable connections were found through these via stations.');
        job.result = { data: { from: job.request.from, to: job.request.to, timeMode: job.request.timeMode,
            requestedAt: new Date(job.request.requestedAt).toISOString(), accessibility: job.request.accessibility,
            journeys: choices, expiresAt: new Date(job.expiry).toISOString(),
            messages: [...new Set([...job.messages, 'Via stations are searched in order with a five-minute minimum change allowance. Other combinations may be available.'])],
            attribution: 'Journey information from TrainTrack UK, National Rail and Transport for London' },
            meta: { updatedAt: new Date(this.now()).toISOString(), cached: false, stale: job.expiry <= this.now() } };
        return { id, status: 'completed', pollAfterMs: 1000, result: job.result };
    }

    async fallback(request) {
        if (!this.tflPlanner || !request.from.tflId || !request.to.tflId) {
            throw new JourneyError('UPSTREAM_UNAVAILABLE', 'National Rail journey planning is temporarily unavailable.', 503);
        }
        const result = await this.tflPlanner.plan({ from: request.from.tflId, to: request.to.tflId,
            timeMode: request.timeMode, accessibility: request.accessibility, include: 'thameslink',
            ...(request.timeMode === 'now' ? {} : { time: new Date(request.requestedAt).toISOString() }) });
        return { ...result, data: { ...result.data, from: request.from, to: request.to,
            messages: [...result.data.messages, 'Combined planning is unavailable. These are TfL-only results; other National Rail alternatives have not been checked.'] } };
    }
}

export function combinedJourneyRoutes(service) {
    const router = Router();
    const handle = work => async (req, res, next) => {
        const controller = new AbortController();
        const close = () => { if (!res.writableEnded) controller.abort(); };
        res.once('close', close); res.set('Cache-Control', 'no-store');
        try { res.json({ data: await work(req, controller.signal) }); }
        catch (error) { next(error); }
        finally { res.removeListener('close', close); }
    };
    router.post('/', handle((req, signal) => service.start(req.query,
        hash(req.get('X-TubeTrack-Install') || req.ip || 'anonymous'), signal)));
    router.get('/:id', handle((req, signal) => service.poll(req.params.id, signal)));
    router.delete('/:id', handle(async req => { await service.cancel(req.params.id); return {}; }));
    return router;
}

// Apply before both normal and fewer-change selection so a late alternative
// cannot be reintroduced after the departure window has been narrowed.
export function imminentJourneyCandidates(journeys, request, now) {
    if (request.timeMode === 'arriveBy') return journeys;
    const earliest = Math.max(now, request.requestedAt);
    const eligible = journeys.filter(j => Date.parse(j.departureTime) >= earliest);
    const imminent = eligible.filter(j => Date.parse(j.departureTime) <= earliest + 30 * 60000);
    return imminent.length ? imminent : eligible;
}

// Keep distinct line choices through the via stations instead of collapsing to the fastest segment.
export function combineViaChoices(options, timeMode = 'now') {
    let paths = [[]];
    for (const choices of options) {
        paths = paths.flatMap(parts => choices.filter(next => !parts.length
            || Date.parse(next.departureTime) >= Date.parse(parts.at(-1).arrivalTime) + 5 * 60000)
            .map(next => [...parts, next])).slice(0, 81);
    }
    const results = paths.map(parts => {
        const legs = [];
        for (const part of parts) {
            if (legs.length) {
                const last = legs.at(-1), next = part.legs[0];
                legs.push(transferLeg({ warnings: ['Allow at least five minutes to change; check local interchange access.'] },
                    last.to, next.from, last.arrivalTime, new Date(Date.parse(last.arrivalTime) + 5 * 60000).toISOString(),
                    `Change at ${next.from.name}`, 'transfer'));
            }
            legs.push(...part.legs);
        }
        const departureTime = parts[0].departureTime, arrivalTime = parts.at(-1).arrivalTime;
        return { id: hash(JSON.stringify(legs)), departureTime, arrivalTime,
            durationMinutes: minute(departureTime, arrivalTime), changes: parts.reduce((n, p) => n + p.changes, 0) + parts.length - 1,
            walkingMinutes: parts.reduce((n, p) => n + p.walkingMinutes, 0), waitingMinutes: 0,
            warnings: parts.flatMap(p => p.warnings), labels: [], legs: legs.map((l, i) => ({ ...l, id: String(i) })) };
    }).filter(j => j.durationMinutes <= 360);
    results.sort((a, b) => timeMode === 'arriveBy' ? b.departureTime.localeCompare(a.departureTime) : a.arrivalTime.localeCompare(b.arrivalTime));
    const seen = new Set();
    const distinct = results.filter(j => {
        const key = j.legs.filter(l => !['walking', 'transfer'].includes(l.mode))
            .map(l => `${l.from.id}:${l.to.id}:${l.lines.map(l => l.id).join(',')}`).join('|');
        if (seen.has(key)) return false; seen.add(key); return true;
    });
    const selected = distinct.slice(0, 3);
    const fewest = [...distinct].sort((a, b) => a.changes - b.changes || a.arrivalTime.localeCompare(b.arrivalTime))[0];
    if (fewest && !selected.includes(fewest)) selected[2] = fewest;
    return selected;
}
