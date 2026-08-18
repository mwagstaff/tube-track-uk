#!/usr/bin/env python3
"""Build the bundled TubeGraph from TfL's current route topology.

The runtime app never depends on this script. It consumes the deterministic JSON
asset produced here. The builder intentionally uses only Python's standard
library so it can be rerun without installing project dependencies.
"""

from __future__ import annotations

import json
import math
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


API_BASE = "https://api.tfl.gov.uk"
LINE_IDS = (
    "bakerloo",
    "central",
    "circle",
    "district",
    "hammersmith-city",
    "jubilee",
    "metropolitan",
    "northern",
    "piccadilly",
    "victoria",
    "waterloo-city",
)
OUTPUT = Path(__file__).resolve().parents[2] / "TubeTrackUK" / "Resources" / "TubeGraph.json"


def fetch_json(path: str) -> Any:
    request = urllib.request.Request(
        f"{API_BASE}{path}",
        headers={"User-Agent": "TubeTrackUK-GraphBuilder/1.0"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def clean_station_name(name: str) -> str:
    suffixes = (
        " Underground Station",
        " Rail Station",
    )
    for suffix in suffixes:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def schematic_point(latitude: float, longitude: float) -> tuple[float, float]:
    # A deterministic London projection tuned for a landscape network canvas.
    # Segment paths are octilinearized below while station endpoints stay shared.
    min_lon, max_lon = -0.52, 0.34
    min_lat, max_lat = 51.38, 51.71
    x = 56 + ((longitude - min_lon) / (max_lon - min_lon)) * 1088
    y = 48 + ((max_lat - latitude) / (max_lat - min_lat)) * 804
    return round(x, 2), round(y, 2)


def octilinear_path(start: tuple[float, float], end: tuple[float, float]) -> list[dict[str, float]]:
    x1, y1 = start
    x2, y2 = end
    dx, dy = x2 - x1, y2 - y1
    ax, ay = abs(dx), abs(dy)
    points = [{"x": x1, "y": y1}]

    if ax < 1 or ay < 1 or abs(ax - ay) < 1:
        points.append({"x": x2, "y": y2})
        return points

    diagonal = min(ax, ay)
    elbow_x = x1 + math.copysign(diagonal, dx)
    elbow_y = y1 + math.copysign(diagonal, dy)
    points.append({"x": round(elbow_x, 2), "y": round(elbow_y, 2)})
    points.append({"x": x2, "y": y2})
    return points


def geographic_line_strings(payload: dict[str, Any]) -> list[list[tuple[float, float]]]:
    """Decode TfL's JSON-encoded GeoJSON-style [longitude, latitude] routes."""
    results: list[list[tuple[float, float]]] = []
    for raw_value in payload.get("lineStrings", []):
        try:
            value = json.loads(raw_value) if isinstance(raw_value, str) else raw_value
        except json.JSONDecodeError:
            continue

        def visit(node: Any) -> None:
            if isinstance(node, list) and node and all(
                isinstance(item, list)
                and len(item) >= 2
                and all(isinstance(value, (int, float)) for value in item[:2])
                for item in node
            ):
                results.append([(float(item[0]), float(item[1])) for item in node])
                return
            if isinstance(node, list):
                for child in node:
                    visit(child)

        visit(value)
    return results


def routed_geographic_path(
    start: dict[str, Any],
    end: dict[str, Any],
    line_strings: list[list[tuple[float, float]]],
) -> list[dict[str, float]]:
    """Slice the best official TfL line string between a segment's stations."""
    start_coordinate = (float(start["longitude"]), float(start["latitude"]))
    end_coordinate = (float(end["longitude"]), float(end["latitude"]))
    best: tuple[float, list[tuple[float, float]]] | None = None

    def distance_squared(left: tuple[float, float], right: tuple[float, float]) -> float:
        dx = (left[0] - right[0]) * 0.62
        dy = left[1] - right[1]
        return dx * dx + dy * dy

    for line_string in line_strings:
        if len(line_string) < 2:
            continue
        start_index = min(range(len(line_string)), key=lambda index: distance_squared(line_string[index], start_coordinate))
        end_index = min(range(len(line_string)), key=lambda index: distance_squared(line_string[index], end_coordinate))
        score = distance_squared(line_string[start_index], start_coordinate) + distance_squared(line_string[end_index], end_coordinate)
        if start_index == end_index:
            score += 0.001
        lower, upper = sorted((start_index, end_index))
        route = line_string[lower : upper + 1]
        if start_index > end_index:
            route.reverse()
        if best is None or score < best[0]:
            best = (score, route)

    if best is None or best[0] > 0.001:
        route = [start_coordinate, end_coordinate]
    else:
        route = best[1]
        if distance_squared(route[0], start_coordinate) > 0.0000005:
            route.insert(0, start_coordinate)
        if distance_squared(route[-1], end_coordinate) > 0.0000005:
            route.append(end_coordinate)

    return [
        {"latitude": round(latitude, 6), "longitude": round(longitude, 6)}
        for longitude, latitude in route
    ]


def main() -> int:
    station_records: dict[str, dict[str, Any]] = {}
    station_lines: defaultdict[str, set[str]] = defaultdict(set)
    line_payloads: dict[str, dict[str, Any]] = {}

    for line_id in LINE_IDS:
        print(f"Fetching {line_id} topology...", file=sys.stderr)
        payload = fetch_json(
            f"/Line/{urllib.parse.quote(line_id)}/Route/Sequence/outbound?serviceTypes=Regular"
        )
        line_payloads[line_id] = payload

        for sequence in payload.get("stopPointSequences", []):
            for point in sequence.get("stopPoint", []):
                station_id = point.get("id")
                latitude = point.get("lat")
                longitude = point.get("lon")
                if not station_id or latitude is None or longitude is None:
                    continue
                station_records[station_id] = {
                    "id": station_id,
                    "name": clean_station_name(point.get("name", station_id)),
                    "latitude": latitude,
                    "longitude": longitude,
                }
                station_lines[station_id].add(line_id)

        for route in payload.get("orderedLineRoutes", []):
            for station_id in route.get("naptanIds", []):
                station_lines[station_id].add(line_id)

    stations: list[dict[str, Any]] = []
    station_points: dict[str, tuple[float, float]] = {}
    for station_id, station in station_records.items():
        x, y = schematic_point(station["latitude"], station["longitude"])
        station_points[station_id] = (x, y)
        lines = sorted(station_lines[station_id])
        stations.append(
            {
                **station,
                "schematicX": x,
                "schematicY": y,
                "lineIDs": lines,
                "interchange": len(lines) > 1,
                "searchAliases": [
                    station["name"].lower(),
                    station["name"].lower().replace("&", "and"),
                ],
            }
        )

    segments: list[dict[str, Any]] = []
    lines: list[dict[str, Any]] = []

    for line_id in LINE_IDS:
        payload = line_payloads[line_id]
        line_strings = geographic_line_strings(payload)
        segment_ids: list[str] = []
        seen_pairs: set[tuple[str, str]] = set()
        routes: list[list[str]] = []

        for route in payload.get("orderedLineRoutes", []):
            station_ids = [station_id for station_id in route.get("naptanIds", []) if station_id in station_records]
            if len(station_ids) < 2:
                continue
            routes.append(station_ids)
            for from_id, to_id in zip(station_ids, station_ids[1:]):
                pair = tuple(sorted((from_id, to_id)))
                if pair in seen_pairs:
                    continue
                seen_pairs.add(pair)
                segment_id = f"{line_id}:{pair[0]}:{pair[1]}"
                segment_ids.append(segment_id)
                from_station = station_records[from_id]
                to_station = station_records[to_id]
                segments.append(
                    {
                        "id": segment_id,
                        "lineID": line_id,
                        "fromStationID": from_id,
                        "toStationID": to_id,
                        "schematicPoints": octilinear_path(station_points[from_id], station_points[to_id]),
                        "geographicPoints": routed_geographic_path(
                            from_station, to_station, line_strings
                        ),
                    }
                )

        lines.append(
            {
                "id": line_id,
                "name": payload.get("lineName") or line_id,
                "segmentIDs": segment_ids,
                "routes": routes,
            }
        )

    stations.sort(key=lambda station: station["name"])
    segments.sort(key=lambda segment: segment["id"])
    lines.sort(key=lambda line: LINE_IDS.index(line["id"]))

    graph = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "source": {
            "name": "Transport for London Unified API",
            "url": f"{API_BASE}/Line/{{lineId}}/Route/Sequence/outbound",
            "attribution": "Data provided by Transport for London",
        },
        "schematicSize": {"width": 1200.0, "height": 900.0},
        "stations": stations,
        "segments": segments,
        "lines": lines,
    }

    errors: list[str] = []
    station_ids = {station["id"] for station in stations}
    if len(lines) != len(LINE_IDS):
        errors.append(f"expected {len(LINE_IDS)} lines, found {len(lines)}")
    for segment in segments:
        if segment["fromStationID"] not in station_ids or segment["toStationID"] not in station_ids:
            errors.append(f"segment {segment['id']} references a missing station")
    for line in lines:
        if not line["segmentIDs"]:
            errors.append(f"line {line['id']} contains no segments")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    OUTPUT.write_text(json.dumps(graph, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(
        f"Wrote {OUTPUT}: {len(stations)} stations, {len(segments)} line segments, {len(lines)} lines",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (urllib.error.URLError, TimeoutError) as error:
        print(f"Network error: {error}", file=sys.stderr)
        raise SystemExit(2)
