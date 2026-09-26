export const USAGE_SURFACES = Object.freeze(['ios_app', 'widget', 'watch']);
export const USAGE_FEATURES = Object.freeze(['map', 'near_me', 'journeys', 'profile', 'game']);

export function clientMetadata(req) {
    const id = req.get?.('x-tubetrack-install');
    const rawSurface = req.get?.('x-tubetrack-surface');
    const rawVersion = req.get?.('x-tubetrack-app-version');
    const match = /^(\d{1,2})\.(\d{1,2})(?:\.\d{1,3})?$/.exec(rawVersion ?? '');
    const version = match && Number(match[1]) <= 10 && Number(match[2]) <= 30
        ? `${Number(match[1])}.${Number(match[2])}` : 'unknown';
    return {
        installId: typeof id === 'string' && /^[0-9A-Za-z-]{8,64}$/.test(id) ? id : null,
        surface: USAGE_SURFACES.includes(rawSurface) ? rawSurface : 'unknown',
        version
    };
}
