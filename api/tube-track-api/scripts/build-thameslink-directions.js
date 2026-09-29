import { mkdir, writeFile } from 'node:fs/promises';

// Thameslink departures carry no direction, only a destination. Every stop the
// line can terminate at is classified once, from TfL's own stop list: north of
// the core (Bedford, Luton, Cambridge, Peterborough and the Welwyn branch) is
// Northbound, everything else Southbound. St Pancras and King's Cross are core
// termini whose direction depends on where the train is, so they stay unknown.
const CORE_TERMINI = new Set(['910GSTPX', '910GSTPXBOX', '910GKNGX']);
const NORTH_OF_CORE_LATITUDE = 51.535;

const response = await fetch('https://api.tfl.gov.uk/Line/thameslink/StopPoints', {
    headers: { 'User-Agent': 'TubeTrackUK-DirectionBuilder/1.0' }
});
if (!response.ok) throw new Error(`TfL StopPoints failed: ${response.status}`);
const stops = await response.json();
const directions = Object.fromEntries(stops
    .filter((stop) => /^910G/.test(stop.naptanId) && !CORE_TERMINI.has(stop.naptanId))
    .sort((a, b) => a.naptanId.localeCompare(b.naptanId))
    .map((stop) => [stop.naptanId, stop.lat > NORTH_OF_CORE_LATITUDE ? 'Northbound' : 'Southbound']));
await mkdir(new URL('../data/', import.meta.url), { recursive: true });
await writeFile(new URL('../data/thameslink-directions.json', import.meta.url), JSON.stringify({
    source: 'https://api.tfl.gov.uk/Line/thameslink/StopPoints',
    // Every Thameslink stop TfL lists, including the core termini.
    stopIds: stops.map((stop) => stop.naptanId).filter((id) => /^910G/.test(id)).sort(),
    // Where each stop is, so a train bound off the map can be pointed at the
    // map edge nearest its destination.
    coordinates: Object.fromEntries(stops.filter((stop) => /^910G/.test(stop.naptanId))
        .sort((a, b) => a.naptanId.localeCompare(b.naptanId))
        .map((stop) => [stop.naptanId, [Number(stop.lat.toFixed(5)), Number(stop.lon.toFixed(5))]])),
    directions
}, null, 2) + '\n');
console.log(`Classified ${Object.keys(directions).length} Thameslink destinations.`);
