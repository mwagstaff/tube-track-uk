#!/usr/bin/env python3
"""List the National Rail operators that call at each mapped rail station.

The app shows other operators' service status (Southern, Southeastern, Great
Northern...) on the stations they share with the lines it draws. TfL's
StopPoint records name every operator at a station, so this resolves each
910G stop point in TubeGraph.json once, offline, and writes a compact
operator-to-stations index. Lines the app draws itself are left out.

Usage: build_national_rail_operators.py [graph.json] [output.json]
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = pathlib.Path(__file__).resolve().parents[2]
GRAPH = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "TubeTrackUK/Resources/TubeGraph.json"
OUTPUT = (
    pathlib.Path(sys.argv[2])
    if len(sys.argv) > 2
    else ROOT / "TubeTrackUK/Resources/NationalRailOperators.json"
)
API_BASE = "https://api.tfl.gov.uk"


def fetch_json(path: str):
    # Anonymous TfL requests are rate limited; the API's key lifts that.
    key = os.environ.get("TUBETRACK_UK_TFL_UNIFIED_API_KEY")
    url = f"{API_BASE}{path}" + (f"?app_key={urllib.parse.quote(key)}" if key else "")
    request = urllib.request.Request(url, headers={"User-Agent": "TubeTrackUK-OperatorBuilder/1.0"})
    for attempt in range(8):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except OSError:
            if attempt == 7:
                raise
            time.sleep(min(30, 2 ** attempt))


def main() -> None:
    graph = json.loads(GRAPH.read_text())
    drawn_lines = {line["id"] for line in graph["lines"]}
    operators = {
        line["id"]: line["name"]
        for line in fetch_json("/Line/Mode/national-rail")
        if line["id"] not in drawn_lines
    }
    stop_ids = sorted(station["id"] for station in graph["stations"] if station["id"].startswith("910G"))

    def operators_at(stop_id: str) -> tuple[str, list[str]]:
        stop = fetch_json(f"/StopPoint/{urllib.parse.quote(stop_id)}")
        found = {
            identifier
            for group in stop.get("lineModeGroups", [])
            if group.get("modeName") == "national-rail"
            for identifier in group.get("lineIdentifier", [])
            if identifier in operators
        }
        return stop_id, sorted(found)

    stations_by_operator: dict[str, list[str]] = {operator: [] for operator in operators}
    with ThreadPoolExecutor(max_workers=2) as pool:
        for stop_id, found in pool.map(operators_at, stop_ids):
            for operator in found:
                stations_by_operator[operator].append(stop_id)

    index = {
        "schemaVersion": 1,
        "source": "Transport for London Unified API StopPoint lineModeGroups",
        "operators": [
            {"id": operator, "name": operators[operator], "stationIDs": sorted(stations)}
            for operator, stations in sorted(stations_by_operator.items())
            if stations
        ],
    }
    OUTPUT.write_text(json.dumps(index, indent=2) + "\n")
    print(f"Wrote {len(index['operators'])} operators across {len(stop_ids)} stop points to {OUTPUT}")


if __name__ == "__main__":
    main()
