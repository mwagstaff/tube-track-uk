const normalized = value => String(value ?? '').trim().toLowerCase();

// Mirrors StationArrivalsService.coalescedCanaryWharfDLRPlatformFaces.
// These are two boarding faces of the same track, not alternative platforms.
// Never infer this from matching destination/countdown at an arbitrary station.
export function coalesceDeparturePlatforms(rows) {
    const result = [];
    const clusters = new Map();
    for (const row of rows) {
        const match = /^(?:platform\s+)?([1-6])$/i.exec(String(row.platformName ?? '').trim());
        const time = Date.parse(row.expectedArrival ?? '');
        if (row.lineId !== 'dlr' || normalized(row.stopId) !== '940gzzdlcan'
            || !match || !Number.isFinite(time)) {
            result.push(row);
            continue;
        }
        const platform = Number(match[1]);
        const key = JSON.stringify([normalized(row.id), normalized(row.vehicleId),
            normalized(row.direction), normalized(row.destinationStopId),
            normalized(row.destinationName), normalized(row.towards), Math.ceil(platform / 2)]);
        const candidates = clusters.get(key) ?? [];
        const cluster = candidates.find(candidate => !candidate.platforms.has(platform)
            && Math.abs(candidate.time - time) <= 2_000);
        if (cluster) {
            cluster.platforms.add(platform);
            result[cluster.index] = { ...result[cluster.index],
                platformName: `Platforms ${[...cluster.platforms].sort((a, b) => a - b).join(' & ')}` };
        } else {
            candidates.push({ time, index: result.length, platforms: new Set([platform]) });
            result.push(row);
        }
        clusters.set(key, candidates);
    }
    return coalesceAlternativePlatforms(result);
}

// Tube feeds can advertise the same identified train on alternative tracks.
// Unlike Canary Wharf, this does not mean both platforms can be used.
function coalesceAlternativePlatforms(rows) {
    const tubeLines = new Set(['bakerloo', 'central', 'circle', 'district', 'hammersmith-city',
        'jubilee', 'metropolitan', 'northern', 'piccadilly', 'victoria', 'waterloo-city']);
    const result = [];
    const clusters = new Map();
    for (const row of rows) {
        const vehicle = normalized(row.vehicleId);
        const time = Date.parse(row.expectedArrival ?? '');
        const platform = normalized(row.platformName);
        if (!tubeLines.has(row.lineId) || !vehicle || /^0+$/.test(vehicle)
            || !normalized(row.stopId) || !platform || !Number.isFinite(time)) {
            result.push(row);
            continue;
        }
        const key = JSON.stringify([row.lineId, normalized(row.stopId), vehicle,
            normalized(row.direction), normalized(row.destinationStopId),
            normalized(row.destinationName), normalized(row.towards)]);
        const candidates = clusters.get(key) ?? [];
        const cluster = candidates.find(candidate => !candidate.platforms.has(platform)
            && Math.abs(candidate.time - time) <= 2_000);
        if (cluster) {
            cluster.platforms.add(platform);
            const cardinal = ['northbound', 'southbound', 'eastbound', 'westbound'].find(direction =>
                [...cluster.platforms].every(value => value.includes(direction)));
            result[cluster.index] = { ...result[cluster.index], platformName: cardinal
                ? `${cardinal[0].toUpperCase()}${cardinal.slice(1)} - Check platform` : 'Check platform' };
        } else {
            candidates.push({ time, index: result.length, platforms: new Set([platform]) });
            result.push(row);
        }
        clusters.set(key, candidates);
    }
    return result;
}
