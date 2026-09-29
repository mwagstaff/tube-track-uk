import { LINE_COLOURS } from './line-colours.js';

export const STATUS_MODES = 'tube,dlr,elizabeth-line,overground,tram';
// National Rail lines are fetched by id: the mode feed carries every UK operator.
export const NATIONAL_RAIL_LINE_IDS = Object.freeze(LINE_COLOURS
    .filter((line) => line.mode === 'national-rail').map((line) => line.id));

/**
 * The status of every supported line: TfL modes plus National Rail lines.
 * A National Rail outage never takes the TfL-mode statuses down with it; the
 * missing lines are reported in `meta.unavailableLineIds` instead.
 */
export async function loadLineStatuses({ client, resourceCache }) {
    const modes = resourceCache.get('status', {
        freshForMs: 60_000,
        load: () => client.fetchJSON(`/Line/Mode/${STATUS_MODES}/Status`, {
            query: { detail: 'true' },
            metricLabel: 'status'
        })
    });
    const nationalRail = NATIONAL_RAIL_LINE_IDS.length === 0 ? null : resourceCache.get('status:national-rail-lines', {
        freshForMs: 60_000,
        load: () => client.fetchJSON(`/Line/${NATIONAL_RAIL_LINE_IDS.join(',')}/Status`, {
            query: { detail: 'true' },
            metricLabel: 'status:national-rail-lines'
        })
    }).catch(() => null);
    const [modeResult, railResult] = await Promise.all([modes, nationalRail]);
    const railData = Array.isArray(railResult?.data) ? railResult.data : [];
    const available = new Set(railData.map((line) => line?.id));
    const unavailableLineIds = NATIONAL_RAIL_LINE_IDS.filter((id) => !available.has(id));
    const modeData = Array.isArray(modeResult.data) ? modeResult.data : [];
    return {
        data: [...modeData, ...railData],
        meta: {
            ...modeResult.meta,
            updatedAt: [modeResult.meta.updatedAt, railResult?.meta.updatedAt].filter(Boolean).sort()[0],
            cached: modeResult.meta.cached && (railResult?.meta.cached ?? true),
            stale: modeResult.meta.stale || (railResult?.meta.stale ?? false),
            ...(unavailableLineIds.length ? { unavailableLineIds } : {})
        }
    };
}
