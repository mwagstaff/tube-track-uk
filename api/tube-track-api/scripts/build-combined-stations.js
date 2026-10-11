import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

// The map/departure catalogue defines selectable endpoints. Never infer a CRS
// from proximity; its reviewed railCodes retain station/hub identity.
const data = new URL('../data/', import.meta.url);
const stops = JSON.parse(readFileSync(new URL('departure-stops.json', data)));
const tfl = JSON.parse(readFileSync(new URL('journey-stations.json', data))).stations;
const byID = new Map(tfl.flatMap(s => [s.id, ...s.stopIds].map(id => [id, s])));
const stations = stops.filter(s => s.mode === 'rail').map(s => {
    const match = [s.id, ...s.stopIDs].map(id => byID.get(id)).find(Boolean);
    return { id: s.id, name: s.name, stopIds: s.stopIDs, railCodes: s.railCodes,
        tflId: match?.lineIds.some(id => id !== 'thameslink') ? match.id : null,
        latitude: s.latitude, longitude: s.longitude,
        aliases: match?.aliases ?? [] };
});
// Departure-board aliases include nearby rail access. These are distinct map
// stations, not interchangeable journey endpoints. The reviewed TfL adapter
// handles Waterloo East–Southwark access; Bethnal Green's two stations remain
// distinct and need actual TfL walking directions.
for (const station of stations) {
    if (['940GZZLUBLG', '940GZZLUSWK'].includes(station.id)) station.railCodes = [];
}
const output = JSON.stringify({ schemaVersion: 1, stations }, null, 2) + '\n';
writeFileSync(new URL('combined-stations.json', data), output);
if (process.argv[2]) writeFileSync(resolve(process.argv[2], 'api/train-track-api/resources/combined-stations.json'), output);
console.log(`Generated ${stations.length} combined journey stations.`);
