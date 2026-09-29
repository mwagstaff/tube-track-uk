import { Router } from 'express';
import { LINE_COLOURS } from './line-colours.js';

// Lines the app draws itself are reported by /api/v1/status, not here.
const OWN_LINE_IDS = new Set(LINE_COLOURS.map((line) => line.id));

export function normaliseOperatorStatuses(lines) {
    if (!Array.isArray(lines)) throw new Error('Invalid National Rail status feed');
    return lines.filter((line) => line?.id && !OWN_LINE_IDS.has(line.id))
        .map((line) => ({
            id: line.id,
            name: line.name ?? line.id,
            lineStatuses: (line.lineStatuses ?? []).map((status) => ({
                id: status.id ?? 0,
                statusSeverity: status.statusSeverity,
                statusSeverityDescription: status.statusSeverityDescription,
                reason: status.reason ?? null
            }))
        }))
        .sort((a, b) => a.name.localeCompare(b.name, 'en-GB'));
}

export function createNationalRailRoutes({ client, resourceCache }) {
    const router = Router();
    router.get('/status', async (req, res, next) => {
        try {
            const result = await resourceCache.get('status:national-rail-operators', {
                freshForMs: 60_000,
                load: async () => normaliseOperatorStatuses(await client.fetchJSON('/Line/Mode/national-rail/Status', {
                    query: { detail: 'true' },
                    metricLabel: 'status:national-rail-operators'
                }))
            });
            res.set('Cache-Control', 'public, max-age=30, stale-if-error=300');
            res.json(result);
        } catch (error) { next(error); }
    });
    return router;
}
