import { createHash } from 'node:crypto';

import { getDocument } from 'pdfjs-dist/legacy/build/pdf.mjs';

export const PLANNED_TRACK_CLOSURES_URL =
    'https://content.tfl.gov.uk/planned-track-closures.pdf';

const DAY = 24 * 60 * 60 * 1_000;
const WEEKDAY = /^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b/i;
const MONTHS = new Map([
    ['january', 0], ['february', 1], ['march', 2], ['april', 3],
    ['may', 4], ['june', 5], ['july', 6], ['august', 7],
    ['september', 8], ['october', 9], ['november', 10], ['december', 11]
]);
const LINE_IDS = new Map([
    ['bakerloo', 'bakerloo'],
    ['central', 'central'],
    ['circle', 'circle'],
    ['district', 'district'],
    ['hammersmith and city', 'hammersmith-city'],
    ['jubilee', 'jubilee'],
    ['metropolitan', 'metropolitan'],
    ['northern', 'northern'],
    ['piccadilly', 'piccadilly'],
    ['victoria', 'victoria'],
    ['waterloo and city', 'waterloo-city'],
    ['dlr', 'dlr'],
    ['elizabeth', 'elizabeth'],
    ['london trams', 'tram'],
    ['liberty', 'liberty'],
    ['lioness', 'lioness'],
    ['mildmay', 'mildmay'],
    ['suffragette', 'suffragette'],
    ['weaver', 'weaver'],
    ['windrush', 'windrush']
]);

export class PlannedWorksSourceError extends Error {
    constructor(message, { cause } = {}) {
        super(message, { cause });
        this.name = 'PlannedWorksSourceError';
    }
}

function normalizeWhitespace(value) {
    return value.replace(/\s+/g, ' ').trim();
}

function normalizeLineLabel(value) {
    return normalizeWhitespace(value)
        .toLowerCase()
        .replaceAll('&', 'and')
        .replace(/\s+line$/, '');
}

function lineID(label) {
    return LINE_IDS.get(normalizeLineLabel(label));
}

function lineIDsForLabel(label) {
    const singular = lineID(label);
    if (singular) return [singular];
    const normalized = normalizeLineLabel(label);
    if (normalized.includes('london underground')
        && normalized.includes('docklands light railway')
        && normalized.includes('elizabeth')
        && normalized.includes('london overground')
        && normalized.includes('london trams')) {
        return [...new Set(LINE_IDS.values())];
    }
    return [];
}

function column(item) {
    if (item.x < 145) return 'line';
    if (item.x < 235) return 'start';
    if (item.x < 325) return 'end';
    return 'description';
}

function textFor(items, targetColumn, { preserveParagraphs = false } = {}) {
    const selected = items
        .filter((item) => column(item) === targetColumn && item.str.trim())
        .sort((left, right) => right.y - left.y || left.x - right.x);
    let result = '';
    let previousY;
    for (const item of selected) {
        const separator = preserveParagraphs && previousY !== undefined && previousY - item.y > 20
            ? '\n'
            : ' ';
        result += `${result ? separator : ''}${item.str.trim()}`;
        previousY = item.y;
    }
    return normalizeWhitespace(result.replaceAll('\n ', '\n'));
}

function isoDate(date) {
    return date.toISOString().slice(0, 10);
}

function inferCalendarDate(value, publicationDate) {
    const normalized = normalizeWhitespace(value);
    const match = normalized.match(
        /(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)?\s*(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)/i
    );
    if (!match) return null;

    const day = Number(match[1]);
    const month = MONTHS.get(match[2].toLowerCase());
    const lowerBound = publicationDate.getTime() - 14 * DAY;
    const upperBound = publicationDate.getTime() + 250 * DAY;
    const candidates = [];
    for (let year = publicationDate.getUTCFullYear() - 1;
        year <= publicationDate.getUTCFullYear() + 1;
        year += 1) {
        const date = new Date(Date.UTC(year, month, day));
        if (date.getUTCMonth() !== month || date.getUTCDate() !== day) continue;
        if (date.getTime() >= lowerBound && date.getTime() <= upperBound) candidates.push(date);
    }
    return candidates.sort((left, right) => left - right)[0] ?? null;
}

function publicationDateFrom(pages) {
    const text = pages.slice(0, 2)
        .flatMap((page) => page.items)
        .map((item) => item.str)
        .join(' ');
    const match = text.match(
        /Correct at date of publication\s+(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})/i
    );
    if (!match) {
        throw new PlannedWorksSourceError('The PDF publication date could not be found');
    }
    return new Date(Date.UTC(Number(match[3]), MONTHS.get(match[2].toLowerCase()), Number(match[1])));
}

function eventTitle(description) {
    const normalized = description.toLowerCase();
    if (normalized.includes('reduced service')) return 'Planned service change';
    if (normalized.includes('trains will not stop')) return 'Planned station non-stop';
    return 'Planned closure';
}

function stableID({ lineId, dateRange, description }) {
    const fingerprint = createHash('sha256')
        .update(`${lineId}\u001f${dateRange.start}\u001f${dateRange.end}\u001f${normalizeWhitespace(description).toLowerCase()}`)
        .digest('hex')
        .slice(0, 16);
    return `tfl-planned:${lineId}:${dateRange.start}:${fingerprint}`;
}

export function parsePlannedTrackClosurePages(
    pages,
    { minimumEvents = 50, minimumHorizonDays = 120 } = {}
) {
    const publicationDate = publicationDateFrom(pages);
    const works = [];
    let currentLineIDs = [];

    for (const page of pages) {
        const items = page.items
            .map((item) => ({ ...item, str: item.str.trim() }))
            .filter((item) => item.str
                && item.y > 80
                && !/^Continued/i.test(item.str)
                && !(item.x < 145 && WEEKDAY.test(item.str) && /\buntil\b/i.test(item.str)));
        const eventTops = items
            .filter((item) => column(item) === 'start' && WEEKDAY.test(item.str))
            .map((item) => item.y)
            .filter((value, index, values) => values.findIndex((other) => Math.abs(other - value) < 2) === index)
            .sort((left, right) => right - left);

        for (const [index, top] of eventTops.entries()) {
            const nextTop = eventTops[index + 1] ?? 80;
            const rowItems = items.filter((item) => item.y <= top + 2 && item.y > nextTop + 2);
            const label = textFor(rowItems, 'line');
            if (label) {
                let parsedLineIDs = lineIDsForLabel(label);
                if (parsedLineIDs.length === 0) {
                    const expandedLabel = textFor(
                        items.filter((item) => item.y <= top + 75 && item.y > nextTop + 2),
                        'line'
                    );
                    parsedLineIDs = lineIDsForLabel(expandedLabel);
                }
                if (parsedLineIDs.length === 0) {
                    throw new PlannedWorksSourceError(
                        `Unrecognised line label in PDF near page ${page.number}: ${label}`
                    );
                }
                currentLineIDs = parsedLineIDs;
            }
            if (currentLineIDs.length === 0) {
                throw new PlannedWorksSourceError('A closure row appeared before its line label');
            }

            const start = inferCalendarDate(textFor(rowItems, 'start'), publicationDate);
            const end = inferCalendarDate(textFor(rowItems, 'end'), publicationDate);
            const description = textFor(rowItems, 'description', { preserveParagraphs: true });
            // TfL occasionally leaves a dated table row blank when a previously
            // advertised item has been removed. It is not a disruption record.
            if (!description) continue;
            if (!start || !end) {
                throw new PlannedWorksSourceError(
                    `Incomplete ${currentLineIDs.join(',')} closure row near page ${page.number}`
                );
            }
            if (end < start) {
                throw new PlannedWorksSourceError(
                    `Closure end precedes start for ${currentLineIDs.join(',')} near page ${page.number}`
                );
            }

            const dateRange = { start: isoDate(start), end: isoDate(end) };
            for (const currentLineID of currentLineIDs) {
                const work = {
                    lineId: currentLineID,
                    title: eventTitle(description),
                    description,
                    dateRange,
                    validFrom: null,
                    validTo: null,
                    timingPrecision: 'date',
                    provisional: true,
                    severity: null,
                    affectedRoutes: [],
                    affectedStops: [],
                    sources: [{
                        kind: 'tfl-planned-track-closures-pdf',
                        url: PLANNED_TRACK_CLOSURES_URL,
                        publishedAt: isoDate(publicationDate)
                    }]
                };
                works.push({ id: stableID(work), ...work });
            }
        }
    }

    if (works.length < minimumEvents) {
        throw new PlannedWorksSourceError(
            `PDF parser found ${works.length} events; expected at least ${minimumEvents}`
        );
    }
    const horizonEnd = works.reduce(
        (latest, work) => work.dateRange.end > latest ? work.dateRange.end : latest,
        ''
    );
    const horizonDays = (new Date(`${horizonEnd}T00:00:00Z`) - publicationDate) / DAY;
    if (horizonDays < minimumHorizonDays) {
        throw new PlannedWorksSourceError(
            `PDF horizon is only ${Math.floor(horizonDays)} days; expected at least ${minimumHorizonDays}`
        );
    }

    return {
        works: works.sort(compareWorks),
        publicationDate: isoDate(publicationDate),
        horizonStart: works.reduce(
            (earliest, work) => !earliest || work.dateRange.start < earliest
                ? work.dateRange.start
                : earliest,
            ''
        ),
        horizonEnd
    };
}

export async function parsePlannedTrackClosuresPDF(data, options) {
    let document;
    try {
        document = await getDocument({ data: new Uint8Array(data), disableWorker: true }).promise;
        const pages = [];
        for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
            const page = await document.getPage(pageNumber);
            const content = await page.getTextContent();
            pages.push({
                number: pageNumber,
                items: content.items.map((item) => ({
                    str: item.str,
                    x: item.transform[4],
                    y: item.transform[5]
                }))
            });
        }
        return parsePlannedTrackClosurePages(pages, options);
    } catch (error) {
        if (error instanceof PlannedWorksSourceError) throw error;
        throw new PlannedWorksSourceError('TfL planned-closures PDF could not be parsed', { cause: error });
    } finally {
        await document?.destroy();
    }
}

function londonDate(instant) {
    const parts = new Intl.DateTimeFormat('en-GB', {
        timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit'
    }).formatToParts(instant);
    const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
    return `${values.year}-${values.month}-${values.day}`;
}

function isPlannedStatus(status) {
    const disruption = status.disruption ?? {};
    const metadata = [
        disruption.category,
        disruption.categoryDescription,
        disruption.closureText,
        status.statusSeverityDescription
    ].filter(Boolean).join(' ').toLowerCase();
    return metadata.includes('planned work')
        || metadata.includes('plannedwork')
        || metadata.includes('planned closure')
        || metadata.includes('plannedclosure');
}

export function normalizeUnifiedAPIWorks(lines) {
    const works = [];
    for (const line of Array.isArray(lines) ? lines : []) {
        for (const status of line.lineStatuses ?? []) {
            if (!isPlannedStatus(status)) continue;
            for (const period of status.validityPeriods ?? []) {
                const validFrom = new Date(period.fromDate);
                const validTo = new Date(period.toDate);
                if (Number.isNaN(validFrom.getTime()) || Number.isNaN(validTo.getTime()) || validTo <= validFrom) {
                    continue;
                }
                const description = status.reason
                    ?? status.disruption?.description
                    ?? status.statusSeverityDescription
                    ?? 'Planned engineering work';
                const dateRange = {
                    start: londonDate(validFrom),
                    end: londonDate(new Date(validTo.getTime() - 1))
                };
                const work = {
                    lineId: line.id,
                    title: status.statusSeverityDescription ?? 'Planned engineering work',
                    description,
                    dateRange,
                    validFrom: validFrom.toISOString(),
                    validTo: validTo.toISOString(),
                    timingPrecision: 'exact',
                    provisional: false,
                    severity: status.statusSeverity ?? null,
                    affectedRoutes: status.disruption?.affectedRoutes ?? [],
                    affectedStops: status.disruption?.affectedStops ?? [],
                    sources: [{ kind: 'tfl-unified-api', url: 'https://api.tfl.gov.uk' }]
                };
                works.push({ id: stableID(work), ...work });
            }
        }
    }
    return works.sort(compareWorks);
}

function rangesOverlap(left, right) {
    return left.start <= right.end && right.start <= left.end;
}

const DESCRIPTION_STOP_WORDS = new Set([
    'after', 'before', 'between', 'closure', 'district', 'during', 'from',
    'line', 'london', 'planned', 'service', 'services', 'station', 'stations',
    'sunday', 'saturday', 'trains', 'until', 'will', 'with'
]);

function descriptionTokens(value) {
    return new Set(value.toLowerCase()
        .replace(/[^a-z0-9]+/g, ' ')
        .split(' ')
        .filter((token) => token.length >= 4 && !DESCRIPTION_STOP_WORDS.has(token)));
}

function descriptionsLikelyMatch(left, right) {
    const leftTokens = descriptionTokens(left);
    const rightTokens = descriptionTokens(right);
    if (leftTokens.size === 0 || rightTokens.size === 0) return false;
    const shared = [...leftTokens].filter((token) => rightTokens.has(token)).length;
    return shared >= 2 && shared / Math.min(leftTokens.size, rightTokens.size) >= 0.25;
}

function compareWorks(left, right) {
    return left.dateRange.start.localeCompare(right.dateRange.start)
        || left.lineId.localeCompare(right.lineId)
        || left.description.localeCompare(right.description);
}

export function mergePlannedWorks(pdfWorks, apiWorks) {
    const matchedPDFIDs = new Set();
    const enrichedAPIWorks = apiWorks.map((apiWork) => {
        const matches = pdfWorks.filter((pdfWork) =>
            pdfWork.lineId === apiWork.lineId
            && rangesOverlap(pdfWork.dateRange, apiWork.dateRange)
            && descriptionsLikelyMatch(pdfWork.description, apiWork.description)
        );
        matches.forEach((match) => matchedPDFIDs.add(match.id));
        if (matches.length === 0) return apiWork;
        const sources = [...apiWork.sources];
        for (const match of matches) {
            for (const source of match.sources) {
                if (!sources.some((candidate) => candidate.kind === source.kind)) sources.push(source);
            }
        }
        return { ...apiWork, sources };
    });
    return [
        ...enrichedAPIWorks,
        ...pdfWorks.filter((work) => !matchedPDFIDs.has(work.id))
    ].sort(compareWorks);
}

export class PlannedTrackClosuresSource {
    constructor({
        fetchImpl = globalThis.fetch,
        parsePDF = parsePlannedTrackClosuresPDF,
        clock = Date.now,
        url = PLANNED_TRACK_CLOSURES_URL,
        freshForMs = 12 * 60 * 60 * 1_000,
        timeoutMs = 20_000
    } = {}) {
        this.fetchImpl = fetchImpl;
        this.parsePDF = parsePDF;
        this.clock = clock;
        this.url = url;
        this.freshForMs = freshForMs;
        this.timeoutMs = timeoutMs;
        this.cached = null;
        this.inFlight = null;
    }

    async get() {
        const now = this.clock();
        if (this.cached && now - this.cached.fetchedAtMs < this.freshForMs) {
            return this.#snapshot(this.cached, { cached: true, stale: false });
        }
        if (!this.inFlight) this.inFlight = this.#load();
        try {
            const loaded = await this.inFlight;
            if (loaded) this.cached = loaded;
            if (!this.cached) throw new PlannedWorksSourceError('TfL closure schedule is unavailable');
            return this.#snapshot(this.cached, { cached: loaded === null, stale: false });
        } catch (error) {
            if (this.cached) return this.#snapshot(this.cached, { cached: true, stale: true });
            throw error;
        } finally {
            this.inFlight = null;
        }
    }

    async #load() {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
        timeout.unref?.();
        try {
            const headers = { accept: 'application/pdf', 'user-agent': 'tube-track-api/0.2' };
            if (this.cached?.etag) headers['if-none-match'] = this.cached.etag;
            if (this.cached?.lastModified) headers['if-modified-since'] = this.cached.lastModified;
            const response = await this.fetchImpl(this.url, { headers, signal: controller.signal });
            if (response.status === 304 && this.cached) {
                this.cached.fetchedAtMs = this.clock();
                return null;
            }
            if (!response.ok) {
                throw new PlannedWorksSourceError(`TfL closure schedule returned HTTP ${response.status}`);
            }
            const data = await response.arrayBuffer();
            if (data.byteLength === 0 || data.byteLength > 5 * 1_024 * 1_024) {
                throw new PlannedWorksSourceError('TfL closure schedule had an unexpected size');
            }
            // PDF.js may transfer and detach the supplied ArrayBuffer on Node
            // 20, so derive anything else we need from it before parsing.
            const documentHash = createHash('sha256')
                .update(new Uint8Array(data))
                .digest('hex');
            const parsed = await this.parsePDF(data);
            return {
                ...parsed,
                fetchedAtMs: this.clock(),
                etag: response.headers.get('etag'),
                lastModified: response.headers.get('last-modified'),
                documentHash
            };
        } catch (error) {
            if (error instanceof PlannedWorksSourceError) throw error;
            throw new PlannedWorksSourceError('TfL closure schedule could not be fetched', { cause: error });
        } finally {
            clearTimeout(timeout);
        }
    }

    #snapshot(entry, { cached, stale }) {
        return {
            works: entry.works,
            meta: {
                kind: 'tfl-planned-track-closures-pdf',
                url: this.url,
                publishedAt: entry.publicationDate,
                fetchedAt: new Date(entry.fetchedAtMs).toISOString(),
                horizonStart: entry.horizonStart,
                horizonEnd: entry.horizonEnd,
                documentHash: entry.documentHash,
                cached,
                stale
            }
        };
    }
}

export function plannedWorksV2Response({ from, to, pdfSnapshot, apiResult }) {
    const apiWorks = normalizeUnifiedAPIWorks(apiResult.data);
    const works = mergePlannedWorks(pdfSnapshot.works, apiWorks)
        .filter((work) => work.dateRange.start <= to && work.dateRange.end >= from);
    const updatedAt = [pdfSnapshot.meta.fetchedAt, apiResult.meta?.updatedAt]
        .filter(Boolean)
        .sort()
        .at(-1) ?? new Date().toISOString();
    return {
        data: {
            works,
            coverage: {
                requestedFrom: from,
                requestedTo: to,
                publishedFrom: pdfSnapshot.meta.horizonStart,
                publishedThrough: pdfSnapshot.meta.horizonEnd,
                sources: [
                    pdfSnapshot.meta,
                    {
                        kind: 'tfl-unified-api',
                        url: 'https://api.tfl.gov.uk',
                        fetchedAt: apiResult.meta?.updatedAt ?? updatedAt,
                        cached: apiResult.meta?.cached ?? false,
                        stale: apiResult.meta?.stale ?? false
                    }
                ]
            }
        },
        meta: {
            updatedAt,
            cached: pdfSnapshot.meta.cached || (apiResult.meta?.cached ?? false),
            stale: pdfSnapshot.meta.stale || (apiResult.meta?.stale ?? false),
            count: works.length,
            schemaVersion: 2
        }
    };
}
