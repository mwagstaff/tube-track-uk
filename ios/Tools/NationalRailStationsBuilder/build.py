"""Build the departure CRS index from TrainTrack's station catalogue and reviewed interchanges.

Usage: python3 build.py /path/to/train-track-uk
Walking links to separate stations are deliberately excluded.
"""
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[3]
resources = Path(sys.argv[1]) / "api/train-track-api/resources"
rail = json.loads((resources / "stations.json").read_text())
reviewed = json.loads((resources / "london-tfl-stations.json").read_text())["stations"]
tube = json.loads((root / "api/tube-track-api/data/journey-stations.json").read_text())["stations"]

def normalized(name):
    name = re.sub(r" (Rail|Underground|DLR) Station$| Tram Stop$| Station$| \(.*?\)", "", name)
    return re.sub("[^a-z0-9]", "", name.lower().removeprefix("london "))

result = {}
for station in tube:
    codes = {r["crs"] for r in rail
             if normalized(r["name"]) == normalized(station["name"])
             and abs(float(r["latitude"]) - station["latitude"]) < .015
             and abs(float(r["longitude"]) - station["longitude"]) < .02}
    for crs, link in reviewed.items():
        if link.get("accessWalkingMinutes"):
            continue
        if link["hubId"] == station["id"] or set(link["stopIds"]) & set(station["stopIds"]):
            codes.add(crs)
    if codes:
        for stop in set(station["stopIds"] + [station["id"]]):
            result[stop] = sorted(codes)
    elif any(stop.startswith("910G") for stop in station["stopIds"]):
        raise ValueError(f"Unmapped rail station: {station['name']}")

output = root / "ios/TubeTrackCore/Sources/TubeTrackCore/Resources/NationalRailStations.json"
output.write_text(json.dumps(dict(sorted(result.items())), indent=2) + "\n")
(root / "api/tube-track-api/data/national-rail-stations.json").write_text(output.read_text())
print(f"Wrote {len(result)} stop/hub mappings covering {len(set(sum(result.values(), [])))} CRS codes")
