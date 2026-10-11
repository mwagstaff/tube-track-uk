"""Export identical departure endpoint identities for the app and API.

Run from the repository root after rebuilding the station index / rail map.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
core = ROOT / 'ios/TubeTrackCore/Sources/TubeTrackCore/Resources'
index = json.loads((core / 'StationIndex.json').read_text())['stations']
graph = json.loads((ROOT / 'ios/TubeTrackUK/Resources/TubeGraph.json').read_text())['stations']
rail = json.loads((ROOT / 'ios/TubeTrackUK/Resources/NationalRailMap.json').read_text())['stations']
coordinates = {s['id']: s for s in graph + rail}
codes = json.loads((core / 'NationalRailStations.json').read_text())
groups = {}
for entry in index:
    groups.setdefault(entry['hubID'], []).append(entry)
indexed = {e['id'] for e in index}
for station in rail:
    if station['id'] not in indexed:
        groups.setdefault(station.get('hubID') or station['id'], []).append(dict(
            id=station['id'], name=station['name'], lineIDs=station['lineIDs']))
result = []
for hub, entries in groups.items():
    point = next((coordinates[e['id']] for e in entries if e['id'] in coordinates), None)
    if not point:
        continue
    name = min((e['name'] for e in entries), key=len)
    for suffix in [' Underground Station', ' DLR Station', ' Rail Station', ' Tram Stop']:
        name = name.removesuffix(suffix)
    result.append(dict(id=hub, name=name, latitude=point['latitude'], longitude=point['longitude'],
                       stopIDs=sorted(e['id'] for e in entries),
                       lineIDs=sorted({line for e in entries for line in e['lineIDs']}),
                       railCodes=sorted({c for e in entries for c in codes.get(e['id'], [])} | set(codes.get(hub, []))),
                       mode='rail'))
result.sort(key=lambda s: (s['name'], s['id']))
for target in [core / 'DepartureStops.json', ROOT / 'api/tube-track-api/data/departure-stops.json']:
    target.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
print(f'Exported {len(result)} departure endpoints')
