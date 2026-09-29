import { readFile, writeFile } from 'node:fs/promises';

// The Thameslink stations and track the app maps, for estimating where trains
// are from departure boards. Regenerate after TubeGraph.json changes.
const graph = JSON.parse(await readFile(new URL('../../../ios/TubeTrackUK/Resources/TubeGraph.json', import.meta.url)));
const LINE_ID = 'thameslink';

function metres([lat1, lon1], [lat2, lon2]) {
    const radians = Math.PI / 180;
    const h = Math.sin((lat2 - lat1) * radians / 2) ** 2
        + Math.cos(lat1 * radians) * Math.cos(lat2 * radians) * Math.sin((lon2 - lon1) * radians / 2) ** 2;
    return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
}

const segments = graph.segments.filter((segment) => segment.lineID === LINE_ID).map((segment) => {
    const points = segment.geographicPoints.map((point) => [point.latitude, point.longitude]);
    const lengthM = points.slice(1).reduce((total, point, index) => total + metres(points[index], point), 0);
    return { from: segment.fromStationID, to: segment.toStationID, lengthM: Math.round(lengthM) };
}).sort((a, b) => `${a.from}${a.to}`.localeCompare(`${b.from}${b.to}`));
const ids = new Set(segments.flatMap((segment) => [segment.from, segment.to]));
const stations = graph.stations.filter((station) => ids.has(station.id))
    .map((station) => ({ id: station.id, name: station.name,
        latitude: Number(station.latitude.toFixed(5)), longitude: Number(station.longitude.toFixed(5)) }))
    .sort((a, b) => a.id.localeCompare(b.id));
// TfL's calling patterns, whole-network and in both directions, say which way
// a train goes next and which branch it came from. St Pancras's Thameslink
// platforms are their own stop in the app.
const ALIASES = new Map([['910GSTPX', '910GSTPXBOX']]);
const patterns = [];
for (const direction of ['outbound', 'inbound']) {
    const response = await fetch(`https://api.tfl.gov.uk/Line/${LINE_ID}/Route/Sequence/${direction}?serviceTypes=Regular`,
        { headers: { 'User-Agent': 'TubeTrackUK-NetworkBuilder/1.0' } });
    if (!response.ok) throw new Error(`TfL route sequence failed: ${response.status}`);
    for (const route of (await response.json()).orderedLineRoutes ?? []) {
        patterns.push(route.naptanIds.map((id) => ALIASES.get(id) ?? id));
    }
}
await writeFile(new URL('../data/thameslink-network.json', import.meta.url),
    JSON.stringify({ version: graph.generatedAt, stations, segments, patterns }, null, 2) + '\n');
console.log(`Exported ${stations.length} Thameslink stations, ${segments.length} segments and ${patterns.length} calling patterns.`);
