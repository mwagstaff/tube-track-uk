// Rebuild the offline pier catalogue from reviewed, recorded API fixtures.
// New piers also need explicit RiverSchematic.json anchors before appearing on
// the authored map. Runtime discovery remains independent of this bundle.
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { normaliseRiverNetwork } from '../lib/river.js';

const fixture = async (name) => JSON.parse(await readFile(new URL(`../test/fixtures/river/${name}.json`, import.meta.url)));
const files = await readdir(new URL('../test/fixtures/river/', import.meta.url));
const sequences = await Promise.all(files.filter(name => /^rb\d+[a-z]?-(inbound|outbound)\.json$/.test(name)).sort().map(name => fixture(name.replace(/\.json$/, ''))));
const result = normaliseRiverNetwork(await fixture('lines'), (await fixture('piers')).stopPoints, sequences);
await writeFile(new URL('../../../ios/TubeTrackUK/Resources/RiverNetwork.json', import.meta.url), `${JSON.stringify(result, null, 2)}\n`);
console.log(`Built ${result.piers.length} piers and ${result.routes.length} route variants`);
