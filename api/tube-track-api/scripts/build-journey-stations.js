import { readFile, mkdir, writeFile } from 'node:fs/promises';

// Keep the API's rail scope and interchange groups aligned with the app's map.
const graph = JSON.parse(await readFile(new URL('../../../ios/TubeTrackUK/Resources/TubeGraph.json', import.meta.url)));
const groups = new Map();
// National Rail platforms join an interchange under its TfL name (King's Cross
// St. Pancras, not St Pancras International), so they are grouped last.
const nationalRailLines = new Set(['thameslink']);
const nationalRailOnly = (station) => station.lineIDs.every((lineId) => nationalRailLines.has(lineId));
const ordered = [...graph.stations].sort((a, b) => Number(nationalRailOnly(a)) - Number(nationalRailOnly(b)));
for (const station of ordered) {
    const id = station.hubID ?? station.id;
    const existing = groups.get(id);
    const group = existing ?? {
        id, name: station.name, stopIds: [], aliases: [], lineIds: [],
        latitude: station.latitude, longitude: station.longitude
    };
    if (!(existing && nationalRailOnly(station)) && station.name.length < group.name.length) group.name = station.name;
    group.stopIds.push(station.id);
    group.aliases = [...new Set([...group.aliases, station.name, ...station.searchAliases])];
    group.lineIds = [...new Set([...group.lineIds, ...station.lineIDs])].sort();
    groups.set(id, group);
}
const catalogue = {
    version: graph.generatedAt,
    attribution: 'Powered by TfL Open Data',
    stations: [...groups.values()].sort((a, b) => a.name.localeCompare(b.name, 'en-GB'))
};
await mkdir(new URL('../data/', import.meta.url), { recursive: true });
await writeFile(new URL('../data/journey-stations.json', import.meta.url), JSON.stringify(catalogue, null, 2) + '\n');
console.log(`Exported ${catalogue.stations.length} rail stations/interchanges.`);
