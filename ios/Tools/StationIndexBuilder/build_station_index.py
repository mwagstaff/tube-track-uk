#!/usr/bin/env python3
"""Derive the slim station index bundled with TubeTrackCore from TubeGraph.json.

The widget extension needs station names, identifiers, hubs and lines for its
configuration picker, but not the 1.9 MB rail graph. Re-run this whenever
TubeGraph.json changes; StationIndexTests fails if the two drift apart.

Usage: build_station_index.py [graph.json] [StationIndex.json]
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
GRAPH = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "TubeTrackUK/Resources/TubeGraph.json"
OUTPUT = (
    pathlib.Path(sys.argv[2])
    if len(sys.argv) > 2
    else ROOT / "TubeTrackCore/Sources/TubeTrackCore/Resources/StationIndex.json"
)


def main() -> None:
    graph = json.loads(GRAPH.read_text())
    stations = []
    for station in sorted(graph["stations"], key=lambda s: s["id"]):
        aliases = []
        for alias in station.get("searchAliases", []):
            if alias not in aliases and alias != station["name"].lower():
                aliases.append(alias)
        stations.append(
            {
                "id": station["id"],
                "hubID": station.get("hubID") or station["id"],
                "name": station["name"],
                "lineIDs": station["lineIDs"],
                "searchAliases": aliases,
            }
        )
    index = {"schemaVersion": graph["schemaVersion"], "stations": stations}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(index, separators=(",", ":"), ensure_ascii=False) + "\n")
    print(f"Wrote {len(stations)} stations to {OUTPUT} ({OUTPUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
