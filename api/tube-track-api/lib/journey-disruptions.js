import { createHash } from 'node:crypto';
import { ResourceCache } from './resource-cache.js';
import { londonParts, parseJourneyTime } from './journey-time.js';

const MODES = 'tube,dlr,overground,elizabeth-line,tram';
const LIVE_TTL = 30_000;
const WORKS_TTL = 300_000;
const LOOKUP_TIMEOUT = 2_500;
const LIVE_HORIZON = 15 * 60_000;
const clean = value => String(value ?? '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim();
const hash = value => createHash('sha256').update(value).digest('hex').slice(0, 20);
const unique = items => [...new Map(items.map(item => [clean(item.message).toLowerCase(), item])).values()];
const day = instant => { const p = londonParts(instant); return `${p.year}-${p.month}-${p.day}`; };
const nextDay = date => new Date(Date.parse(`${date}T12:00:00Z`) + 86_400_000).toISOString().slice(0, 10);
const rank = { information: 0, minor: 1, major: 10 };

// Severity numbers are categories, not a numeric ordering. In particular,
// Service Closed (20) and Part Closed (11) are major, not better than Good (10).
export function statusSeverity(code) {
    if ([10, 18].includes(code)) return 'none';
    if ([1, 2, 3, 4, 5, 6, 8, 11, 16, 20].includes(code)) return 'major';
    if ([7, 9, 14].includes(code)) return 'minor';
    if ([0, 12, 13, 15, 17, 19].includes(code)) return 'information';
    return null;
}

function waitFor(promise, signal) {
    if (signal.aborted) {
        promise.catch(() => {});
        return Promise.reject(signal.reason);
    }
    return new Promise((resolve, reject) => {
        const abort = () => reject(signal.reason);
        signal.addEventListener('abort', abort, { once: true });
        promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
    });
}

export class JourneyDisruptions {
    constructor({ fetch, stations, clock = Date.now }) {
        this.fetch = fetch;
        this.clock = clock;
        this.cache = new ResourceCache({ clock });
        this.lineIDs = [...new Set(stations.flatMap(s => s.lineIds))].sort();
        this.stationHubs = new Map(stations.flatMap(s => [s.id, ...s.stopIds].map(id => [id, s.id])));
    }

    async snapshot(journeys, signal) {
        const now = this.clock();
        const legs = journeys.flatMap(j => j.legs).filter(l => l.mode !== 'walking');
        if (!legs.length) return {};
        const first = Math.min(...legs.map(l => Date.parse(l.departureTime)));
        const last = Math.max(...legs.map(l => Date.parse(l.arrivalTime)));
        const from = day(first);
        const to = nextDay(day(last));
        const nearTerm = first <= now + LIVE_HORIZON;
        // Both requests run together; a feed outage must not lose a valid route.
        const [realtime, plannedWorks] = await Promise.all([
            nearTerm
                ? this.lookup('realtime', `/Line/Mode/${MODES}/Status`, LIVE_TTL, signal)
                : { status: 'notApplicable', checkedAt: null, data: [] },
            // Dated feeds also contain realtime statuses, so near-term searches
            // need the same freshness as the live feed.
            this.lookup(`plannedWorks:${from}:${to}`, `/Line/${this.lineIDs.join(',')}/Status/${from}/to/${to}`, nearTerm ? LIVE_TTL : WORKS_TTL, signal)
        ]);
        return { realtime, plannedWorks };
    }

    async lookup(key, path, ttl, parentSignal) {
        const signal = AbortSignal.any([parentSignal, AbortSignal.timeout(LOOKUP_TIMEOUT)]);
        try {
            signal.throwIfAborted();
            const response = await waitFor(this.cache.get(key, {
                freshForMs: ttl,
                load: async () => {
                    const data = await this.fetch(path, {
                        query: { detail: 'true' }, signal: AbortSignal.timeout(LOOKUP_TIMEOUT),
                        metricLabel: key === 'realtime' ? 'journeys:realtime-status' : 'journeys:planned-works'
                    });
                    if (!Array.isArray(data) || data.some(line => !line || typeof line !== 'object'
                        || !Array.isArray(line.lineStatuses) || line.lineStatuses.some(status => !status
                            || typeof status !== 'object' || (status.validityPeriods != null
                                && (!Array.isArray(status.validityPeriods) || status.validityPeriods.some(p => !p)))))) {
                        throw new Error('Invalid disruption feed');
                    }
                    return data;
                }
            }), signal);
            return { status: response.meta.stale ? 'stale' : 'available',
                checkedAt: response.meta.updatedAt, data: response.data,
                expiresAt: response.meta.stale ? this.clock() + 5_000 : Date.parse(response.meta.updatedAt) + ttl };
        } catch {
            return { status: 'unavailable', checkedAt: null, data: [] };
        }
    }

    enrich(journeys, snapshot) {
        return journeys.map(journey => {
            const legs = journey.legs.map(leg => this.enrichLeg(leg, snapshot));
            const issues = mergeIssues(legs.flatMap(leg => leg.disruption.issues));
            const sources = ['realtime', 'plannedWorks'].map(source => {
                const checks = legs.filter(l => l.mode !== 'walking').map(l => l.disruption.sources.find(s => s.source === source));
                const priority = ['unavailable', 'partial', 'stale', 'available', 'notApplicable'];
                const status = priority.find(status => checks.some(c => c.status === status)) ?? 'notApplicable';
                const dates = checks.map(c => c.checkedAt).filter(Boolean).sort();
                return { source, status, checkedAt: dates[0] ?? null };
            });
            const disruption = summarize(issues, sources);
            const warnings = unique(legs.flatMap(l => l.warnings));
            // One incident on several legs or in several feeds counts once.
            const disruptionScore = issues.filter(i => !i.stale).reduce((sum, issue) => sum + rank[issue.severity], 0);
            return { ...journey, legs, warnings, disruption, disruptionScore };
        });
    }

    enrichLeg(leg, snapshot) {
        const issues = leg.warnings.map(warning => ({
            id: hash(`${warning.kind}:${clean(warning.message).toLowerCase()}`),
            sources: ['journeyPlanner'], severity: warning.severity === 'severe' ? 'major' : warning.severity,
            kind: warning.kind, lineId: leg.lines.length === 1 ? canonicalLine(leg.lines[0], this.lineIDs) : null,
            description: warning.message, statusCode: null, statusDescription: null,
            scope: 'journeyLeg', validityPeriods: [], stale: false
        }));
        const sources = [];
        for (const source of ['realtime', 'plannedWorks']) {
            const feed = snapshot[source] ?? { status: 'unavailable', checkedAt: null, data: [] };
            const applicable = leg.mode !== 'walking' && (source !== 'realtime'
                || Date.parse(leg.departureTime) <= this.clock() + LIVE_HORIZON);
            const check = { source, status: applicable ? feed.status : 'notApplicable', checkedAt: applicable ? feed.checkedAt : null };
            sources.push(check);
            if (!applicable || !['available', 'stale'].includes(feed.status)) continue;
            const ids = [...new Set(leg.lines.map(line => canonicalLine(line, this.lineIDs)))];
            if (!ids.length || ids.includes(null)) check.status = 'partial';
            for (const id of ids.filter(Boolean)) {
                const line = feed.data.find(line => canonicalLine(line, this.lineIDs) === id);
                if (!line || !Array.isArray(line.lineStatuses) || !line.lineStatuses.length) {
                    check.status = 'partial';
                    continue;
                }
                for (const status of line.lineStatuses) {
                    const severity = statusSeverity(status.statusSeverity);
                    if (!severity) { check.status = 'partial'; continue; }
                    if (severity === 'none') continue;
                    const periods = (status.validityPeriods ?? []).map(p => ({
                        from: parseJourneyTime(p.fromDate, Date.parse(leg.departureTime)),
                        to: parseJourneyTime(p.toDate, Date.parse(leg.arrivalTime))
                    }));
                    const validPeriods = periods.filter(p => p.from !== null && p.to !== null && p.to > p.from);
                    if (validPeriods.length !== periods.length) check.status = 'partial';
                    if (validPeriods.length && !validPeriods.some(p =>
                        p.from < Date.parse(leg.arrivalTime) && p.to > Date.parse(leg.departureTime))) continue;
                    // An undated planned closure cannot be asserted for a specific
                    // future trip. Retain uncertainty rather than inventing dates.
                    if (!validPeriods.length && source === 'plannedWorks') { check.status = 'partial'; continue; }
                    const description = clean(status.reason || status.disruption?.description || status.statusSeverityDescription);
                    const planned = status.disruption?.category === 'PlannedWork' || status.statusSeverity === 4
                        || /planned ?(work|closure)/i.test(status.disruption?.categoryDescription ?? '');
                    issues.push({
                        id: hash(`${id}:${status.statusSeverity}:${description.toLowerCase()}`),
                        sources: [source], severity, kind: planned ? 'plannedWork' : status.statusSeverity === 13 ? 'accessibility' : 'line',
                        lineId: id, description, statusCode: status.statusSeverity,
                        statusDescription: clean(status.statusSeverityDescription),
                        scope: this.scope(status, leg),
                        validityPeriods: validPeriods.map(p => ({ from: new Date(p.from).toISOString(), to: new Date(p.to).toISOString() })),
                        stale: feed.status === 'stale'
                    });
                }
            }
        }
        const merged = mergeIssues(issues);
        const disruption = summarize(merged, sources);
        // Preserve the warning contract consumed by released iOS clients.
        const warnings = [...leg.warnings];
        for (const issue of merged.filter(i => !i.stale && !i.sources.includes('journeyPlanner'))) {
            if (!warnings.some(w => clean(w.message).toLowerCase() === issue.description.toLowerCase())) {
                warnings.push({ id: issue.id, message: issue.description, kind: issue.kind,
                    severity: issue.severity === 'major' ? 'severe' : issue.severity });
            }
        }
        return { ...leg, warnings, disruption };
    }

    scope(status, leg) {
        const hub = id => this.stationHubs.get(id) ?? id;
        const stops = new Set([leg.from.id, ...leg.stops.map(s => s.id), leg.to.id].filter(Boolean).map(hub));
        const affectedStops = status.disruption?.affectedStops;
        const affected = (Array.isArray(affectedStops) ? affectedStops : []).map(s => s?.naptanId ?? s?.id).filter(Boolean);
        if (affected.some(id => stops.has(hub(id)))) return 'station';
        const affectedRoutes = status.disruption?.affectedRoutes;
        for (const route of Array.isArray(affectedRoutes) ? affectedRoutes : []) {
            if (route?.isEntireRouteSection !== false) continue;
            const sequence = route.routeSectionNaptanEntrySequence;
            const ids = (Array.isArray(sequence) ? sequence : []).map(s => s?.stopPoint?.naptanId ?? s?.stopPoint?.id).filter(Boolean);
            if (ids.filter(id => stops.has(hub(id))).length >= 2) return 'section';
        }
        // Detailed route metadata can describe the whole line even for a partial
        // closure. Keep this explicitly line-level; do not claim an exact match.
        return 'line';
    }
}

function canonicalLine(line, supported) {
    const id = line.id === 'elizabeth-line' ? 'elizabeth' : line.id;
    if (supported.includes(id)) return id;
    const name = clean(line.name).toLowerCase().replace(/ line$/, '').replace(/ & /g, '-').replace(/ /g, '-');
    return supported.includes(name) ? name : null;
}

function mergeIssues(issues) {
    const merged = new Map();
    for (const issue of issues) {
        const key = `${issue.lineId}:${issue.description.toLowerCase()}`;
        const previous = merged.get(key);
        if (!previous) { merged.set(key, { ...issue, id: hash(key) }); continue; }
        const strongest = previous.stale !== issue.stale ? (previous.stale ? issue : previous)
            : rank[issue.severity] > rank[previous.severity]
                || (rank[issue.severity] === rank[previous.severity] && previous.statusCode === null && issue.statusCode !== null)
                ? issue : previous;
        merged.set(key, { ...strongest, id: previous.id,
            sources: [...new Set([...previous.sources, ...issue.sources])],
            stale: previous.stale && issue.stale,
            validityPeriods: [...new Map([...previous.validityPeriods, ...issue.validityPeriods]
                .map(p => [JSON.stringify(p), p])).values()]
        });
    }
    return [...merged.values()];
}

function summarize(issues, sources) {
    const applicable = sources.filter(s => s.status !== 'notApplicable');
    const complete = applicable.every(s => s.status === 'available');
    const coverage = !applicable.length ? 'notApplicable' : complete ? 'complete'
        : applicable.some(s => ['available', 'partial', 'stale'].includes(s.status)) ? 'partial' : 'unavailable';
    const confirmed = issues.filter(i => !i.stale);
    const status = confirmed.some(i => i.severity === 'major') ? 'majorIssues'
        : confirmed.some(i => i.severity === 'minor') ? 'minorDelays'
            : confirmed.length ? 'information' : complete ? 'noIssues' : 'unknown';
    const summaries = {
        majorIssues: 'Major disruption reported.', minorDelays: 'Minor delays or reduced service reported.',
        information: 'Travel notices reported.', noIssues: 'No disruption reported.',
        unknown: 'Disruption information is incomplete or unavailable.'
    };
    return { status, hasDisruption: confirmed.length > 0 ? true : complete ? false : null,
        summary: summaries[status], coverage, issues, sources };
}
