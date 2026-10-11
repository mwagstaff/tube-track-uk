#!/usr/bin/env node
// Replay an API benchmark through the app-facing HTTP adapter, without live
// timetable drift. Input is a combined-planner-bench.js JSON report containing legs.
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import express from 'express';
import { CombinedJourneys, combinedJourneyRoutes, normalizeCombinedJourney, imminentJourneyCandidates } from '../lib/combined-journeys.js';

const report = JSON.parse(await readFile(process.argv[2], 'utf8'));
const now = Date.parse(report.request.time);
for (const run of report.runs) {
    const reverse = report.request.timeType === 'arriveBy';
    // Arrive-by searches must permit departures before the arrival deadline.
    const clock = reverse ? now - 6 * 3600000 : now;
    const service = new CombinedJourneys({ now: () => clock, fetch: async (_url, options) =>
        options.method === 'DELETE' ? new Response(null, { status: 204 }) : Response.json(options.method === 'POST'
            ? { id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', status: 'queued' }
            : { status: 'completed', result: { journeys: run.journeys, warnings: run.warnings ?? [],
                expiresAt: new Date(now + 60000).toISOString(), search: run.search } }) });
    const app = express();
    app.use('/api/v2/journey-searches', combinedJourneyRoutes(service));
    app.use((error, _req, res, _next) => res.status(error.status ?? 500).json({ error: error.message }));
    const server = await new Promise(resolve => { const server = app.listen(0, '127.0.0.1', () => resolve(server)); });
    try {
        const base = `http://127.0.0.1:${server.address().port}/api/v2/journey-searches`;
        const params = new URLSearchParams({ from: report.request.origin, to: report.request.destination,
            timeMode: reverse ? 'arriveBy' : 'departAt', time: report.request.time });
        const started = await fetch(`${base}?${params}`, { method: 'POST' });
        assert.equal(started.status, 200);
        const job = (await started.json()).data;
        const response = await fetch(`${base}/${job.id}`);
        assert.equal(response.status, 200);
        const choices = (await response.json()).data.result.data.journeys;
        const eligible = imminentJourneyCandidates(run.journeys.map(normalizeCombinedJourney).filter(Boolean),
            { timeMode: reverse ? "arriveBy" : "departAt", requestedAt: now }, clock).filter(j =>
            Date.parse(j.departureTime) >= clock && (reverse ? Date.parse(j.arrivalTime) <= now : Date.parse(j.departureTime) >= now));
        assert.ok(eligible.length && choices.length, 'Replay must exercise valid journeys');
        assert.ok(choices.every(choice => eligible.some(j => j.id === choice.id)), 'All choices must respect the departure window');
        const field = reverse ? 'departureTime' : 'arrivalTime';
        const best = (reverse ? Math.max : Math.min)(...eligible.map(j => Date.parse(j[field])));
        assert.equal(Date.parse(choices[0][field]), best, 'First choice must have the optimal time across all supplied routes');
        assert.ok(choices[0].labels.includes(reverse ? 'latestDeparture' : 'earliestArrival'));
        console.log(JSON.stringify({ run: run.run, departure: choices[0].departureTime,
            arrival: choices[0].arrivalTime, waitingMinutes: choices[0].waitingMinutes, choices: choices.length }));
        await fetch(`${base}/${job.id}`, { method: 'DELETE' });
    } finally { await new Promise(resolve => server.close(resolve)); }
}
