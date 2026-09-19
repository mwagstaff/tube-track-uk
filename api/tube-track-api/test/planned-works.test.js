import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';

import {
    mergePlannedWorks,
    normalizeUnifiedAPIWorks,
    parsePlannedTrackClosurePages,
    PlannedTrackClosuresSource,
    PlannedWorksSourceError
} from '../lib/planned-works.js';

function item(str, x, y) { return { str, x, y }; }

function fixturePages() {
    return [{
        number: 1,
        items: [
            item('Correct at date of publication Friday 18 September 2026', 72, 790),
            item('Monday 19 until Sunday 25 October', 72, 758),
            item('District', 77, 692),
            item('Saturday 24', 170, 692),
            item('October', 170, 679),
            item('Sunday 25', 255, 692),
            item('October', 255, 679),
            item('Edgware Road and', 340, 692),
            item('Embankment to Ealing Broadway,', 340, 679),
            item('Kensington (Olympia), Richmond and Wimbledon', 340, 665)
        ]
    }];
}

test('parses dated rows from the six-month PDF without inventing exact times', () => {
    const parsed = parsePlannedTrackClosurePages(fixturePages(), {
        minimumEvents: 1,
        minimumHorizonDays: 0
    });
    assert.equal(parsed.publicationDate, '2026-09-18');
    assert.equal(parsed.horizonEnd, '2026-10-25');
    assert.deepEqual(parsed.works[0], {
        id: parsed.works[0].id,
        lineId: 'district',
        title: 'Planned closure',
        description: 'Edgware Road and Embankment to Ealing Broadway, Kensington (Olympia), Richmond and Wimbledon',
        dateRange: { start: '2026-10-24', end: '2026-10-25' },
        validFrom: null,
        validTo: null,
        timingPrecision: 'date',
        provisional: true,
        severity: null,
        affectedRoutes: [],
        affectedStops: [],
        sources: [{
            kind: 'tfl-planned-track-closures-pdf',
            url: 'https://content.tfl.gov.uk/planned-track-closures.pdf',
            publishedAt: '2026-09-18'
        }]
    });
});

test('fails closed when a PDF no longer contains a credible schedule', () => {
    assert.throws(
        () => parsePlannedTrackClosurePages(fixturePages()),
        (error) => error instanceof PlannedWorksSourceError
            && /expected at least 50/.test(error.message)
    );
});

test('hashes the downloaded PDF before the parser detaches its ArrayBuffer', async () => {
    const body = new TextEncoder().encode('synthetic PDF bytes');
    const expectedHash = createHash('sha256').update(body).digest('hex');
    const source = new PlannedTrackClosuresSource({
        fetchImpl: async () => new Response(body, {
            status: 200,
            headers: {
                etag: 'test-etag',
                'last-modified': 'Fri, 18 Sep 2026 10:33:58 GMT'
            }
        }),
        parsePDF: async (data) => {
            structuredClone(data, { transfer: [data] });
            return {
                works: [],
                publicationDate: '2026-09-18',
                horizonStart: '2026-09-19',
                horizonEnd: '2027-03-29'
            };
        },
        clock: () => Date.parse('2026-09-19T01:30:00Z')
    });

    const snapshot = await source.get();

    assert.equal(snapshot.meta.documentHash, expectedHash);
    assert.equal(snapshot.meta.publishedAt, '2026-09-18');
});

test('exact Unified API records supersede overlapping provisional PDF records', () => {
    const pdf = parsePlannedTrackClosurePages(fixturePages(), {
        minimumEvents: 1,
        minimumHorizonDays: 0
    }).works;
    pdf.push({
        ...pdf[0],
        id: 'unrelated-same-weekend',
        description: 'Barking to Upminster'
    });
    const api = normalizeUnifiedAPIWorks([{
        id: 'district',
        lineStatuses: [{
            id: 12,
            statusSeverity: 5,
            statusSeverityDescription: 'Part Closure',
            reason: 'DISTRICT LINE: No service between Embankment and Wimbledon.',
            validityPeriods: [{
                fromDate: '2026-10-24T03:30:00Z',
                toDate: '2026-10-26T01:29:00Z'
            }],
            disruption: { category: 'PlannedWork', affectedRoutes: [], affectedStops: [] }
        }]
    }]);
    const merged = mergePlannedWorks(pdf, api);
    assert.equal(merged.length, 2);
    const exact = merged.find((work) => work.timingPrecision === 'exact');
    assert.equal(exact.provisional, false);
    assert.equal(exact.description, 'DISTRICT LINE: No service between Embankment and Wimbledon.');
    assert.deepEqual(exact.sources.map((source) => source.kind), [
        'tfl-unified-api', 'tfl-planned-track-closures-pdf'
    ]);
    assert.equal(merged.find((work) => work.id === 'unrelated-same-weekend')?.description,
        'Barking to Upminster');
});
