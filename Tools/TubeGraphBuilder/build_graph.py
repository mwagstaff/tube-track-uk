#!/usr/bin/env python3
"""Build the bundled TubeGraph from TfL's current route topology.

The runtime app never depends on this script. It consumes the deterministic JSON
asset produced here. The builder intentionally uses only Python's standard
library so it can be rerun without installing project dependencies.
"""

from __future__ import annotations

import argparse
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
    "dlr",
    "elizabeth",
    "liberty",
    "lioness",
    "mildmay",
    "suffragette",
    "weaver",
    "windrush",
)
OUTPUT = Path(__file__).resolve().parents[2] / "TubeTrackUK" / "Resources" / "TubeGraph.json"

# These coordinates are an original, topology-led central London composition.
# They use the reference map's design language (long shared axes and 45-degree
# transitions) without copying its artwork or production coordinates.
CENTRAL_SCHEMATIC_POINTS: dict[str, tuple[float, float]] = {
    "Paddington": (350, 245),
    "Paddington (H&C Line)-Underground": (370, 325),
    "Edgware Road (Bakerloo)": (395, 245),
    "Edgware Road (Circle Line)": (430, 325),
    "Marylebone": (440, 285),
    "Baker Street": (490, 285),
    "Regent's Park": (535, 330),
    "Great Portland Street": (550, 285),
    "Euston Square": (615, 285),
    "Euston": (670, 225),
    "King's Cross St. Pancras": (790, 225),
    "Angel": (850, 270),
    "Old Street": (910, 315),
    "Farringdon": (835, 345),
    "Barbican": (875, 385),
    "Moorgate": (915, 385),
    "Liverpool Street": (975, 345),
    "Aldgate": (1035, 405),
    "Aldgate East": (1085, 455),
    "Whitechapel": (1075, 455),
    "Tower Hill": (1035, 485),
    "Monument": (935, 485),
    "Bank": (935, 445),
    "Cannon Street": (895, 525),
    "Mansion House": (855, 565),
    "Blackfriars": (815, 625),
    "Temple": (755, 625),
    "Embankment": (695, 625),
    "Westminster": (625, 625),
    "St. James's Park": (565, 625),
    "Victoria": (505, 625),
    "Sloane Square": (445, 625),
    "South Kensington": (385, 625),
    "Gloucester Road": (325, 625),
    "Earl's Court": (265, 625),
    "High Street Kensington": (265, 565),
    "Notting Hill Gate": (265, 445),
    "Bayswater": (315, 365),
    "Queensway": (315, 445),
    "Lancaster Gate": (375, 405),
    "Marble Arch": (435, 405),
    "Bond Street": (495, 405),
    "Oxford Circus": (555, 405),
    "Tottenham Court Road": (625, 405),
    "Holborn": (705, 405),
    "Chancery Lane": (765, 465),
    "St. Paul's": (825, 465),
    "Green Park": (555, 525),
    "Piccadilly Circus": (615, 525),
    "Leicester Square": (665, 525),
    "Covent Garden": (705, 485),
    "Goodge Street": (625, 345),
    "Warren Street": (625, 285),
    "Russell Square": (745, 285),
    "Charing Cross": (665, 585),
    "Waterloo": (725, 705),
    "Southwark": (795, 705),
    "London Bridge": (875, 625),
    "Borough": (875, 705),
    "Knightsbridge": (445, 565),
    "Hyde Park Corner": (495, 525),
    # Inner branches are explicitly aligned so they enter the central grid on
    # calm diagonals instead of inheriting geographic zig-zags.
    "Camden Town": (610, 165),
    "Mornington Crescent": (650, 205),
    "Chalk Farm": (565, 120),
    "Belsize Park": (520, 75),
    "Hampstead": (475, 30),
    "Kentish Town": (655, 120),
    "Tufnell Park": (625, 75),
    "Archway": (595, 30),
    "Caledonian Road": (830, 185),
    "Holloway Road": (870, 145),
    "Arsenal": (910, 105),
    "Highbury & Islington": (890, 125),
    "Finsbury Park": (950, 65),
    "Bethnal Green": (1035, 345),
    "Mile End": (1135, 405),
    "Stratford": (1255, 285),
    "Stepney Green": (1135, 455),
    "Bow Road": (1195, 455),
    "Bromley-by-Bow": (1255, 455),
    "West Ham": (1315, 395),
    "Plaistow": (1375, 395),
    "Bermondsey": (935, 625),
    "Canada Water": (995, 625),
    "Canary Wharf": (1055, 565),
    "North Greenwich": (1115, 565),
    "Canning Town": (1175, 505),
    "Lambeth North": (755, 745),
    "Elephant & Castle": (815, 765),
    "Kennington": (725, 805),
    "Nine Elms": (625, 805),
    "Battersea Power Station": (565, 805),
    "Oval": (725, 865),
    "Stockwell": (725, 925),
    "Pimlico": (565, 685),
    "Vauxhall": (625, 745),
    "West Kensington": (205, 625),
    "Barons Court": (145, 625),
    "Hammersmith (Dist&Picc Line)": (85, 625),
    "Kensington (Olympia)": (205, 685),
    "Royal Oak": (310, 325),
    "Westbourne Park": (250, 325),
    "Ladbroke Grove": (190, 325),
    "Latimer Road": (130, 385),
    "Wood Lane": (130, 445),
    "Shepherd's Bush Market": (130, 505),
    "Goldhawk Road": (130, 565),
    "Hammersmith (H&C Line)": (85, 610),
    # Heathrow follows the diagram's compact terminal loop rather than placing
    # three terminal names on a geographic east-west run.
    "Heathrow Terminals 2 & 3": (-71, 469),
    "Heathrow Terminal 5": (-119, 541),
    "Heathrow Terminal 4": (-71, 541),
}

# A station can have separate route-aligned platforms. Keep the station's
# canonical point for selection/focus, while authoring each coloured route to
# its own platform point. The renderer draws the interchange connector bar.
SCHEMATIC_ROUTE_POINT_OVERRIDES: dict[tuple[str, str], tuple[float, float]] = {
    ("circle", "Paddington"): (350, 325),
    ("district", "Paddington"): (350, 325),
}
SCHEMATIC_SEGMENT_PATH_OVERRIDES: dict[
    tuple[str, str, str], tuple[tuple[float, float], ...]
] = {
    ("piccadilly", "Heathrow Terminal 5", "Heathrow Terminals 2 & 3"): (
        (-119, 541),
        (-119, 517),
        (-71, 469),
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--osm-pbf",
        type=Path,
        help="Filtered OSM PBF containing TfL rail route relations and railway ways.",
    )
    parser.add_argument("--output", type=Path, default=OUTPUT)
    return parser.parse_args()


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


def schematic_point(name: str, latitude: float, longitude: float) -> tuple[float, float]:
    if name in CENTRAL_SCHEMATIC_POINTS:
        return CENTRAL_SCHEMATIC_POINTS[name]

    # A piecewise geographic warp gives central London the whitespace needed
    # for interchange and label clarity while compressing the long outer arms.
    def piecewise(value: float, knots: tuple[tuple[float, float], ...]) -> float:
        for (input_a, output_a), (input_b, output_b) in zip(knots, knots[1:]):
            if value <= input_b:
                fraction = min(1.0, max(0.0, (value - input_a) / (input_b - input_a)))
                return output_a + (output_b - output_a) * fraction
        return knots[-1][1]

    x = piecewise(longitude, ((-0.52, 45), (-0.25, 235), (0.05, 1085), (0.34, 1355)))
    y = piecewise(latitude, ((51.38, 955), (51.46, 795), (51.57, 175), (51.71, 35)))
    grid = 5.0
    return round(x / grid) * grid, round(y / grid) * grid


def snapped_direction(start: dict[str, Any], end: dict[str, Any]) -> tuple[int, int]:
    dx = (float(end["longitude"]) - float(start["longitude"])) * 0.62
    dy = -(float(end["latitude"]) - float(start["latitude"]))
    if abs(dx) > abs(dy) * 1.8:
        return (1 if dx >= 0 else -1, 0)
    if abs(dy) > abs(dx) * 1.8:
        return (0, 1 if dy >= 0 else -1)
    return (1 if dx >= 0 else -1, 1 if dy >= 0 else -1)


def topology_schematic_points(
    stations: dict[str, dict[str, Any]],
    line_payloads: dict[str, dict[str, Any]],
) -> dict[str, tuple[float, float]]:
    """Lay outer branches out as long octilinear runs from central anchors.

    The central composition is hand-balanced above. This propagation step makes
    the rest of each route follow stable 0/45/90-degree corridors, so bends occur
    at stations and branches rather than as a staircase inside every edge.
    """
    positions = {
        station_id: CENTRAL_SCHEMATIC_POINTS[station["name"]]
        for station_id, station in stations.items()
        if station["name"] in CENTRAL_SCHEMATIC_POINTS
    }
    routes = [
        [station_id for station_id in route.get("naptanIds", []) if station_id in stations]
        for payload in line_payloads.values()
        for route in payload.get("orderedLineRoutes", [])
    ]
    routes = [route for route in routes if len(route) >= 2]
    spacing = 24.0

    for _ in range(6):
        changed = False
        for route in routes:
            known = [index for index, station_id in enumerate(route) if station_id in positions]
            if not known:
                continue

            # Fill gaps between known interchanges. The final connection to the
            # next anchor may turn at that station, which keeps edge paths simple.
            for left_index, right_index in zip(known, known[1:]):
                if right_index - left_index <= 1:
                    continue
                direction = snapped_direction(stations[route[left_index]], stations[route[right_index]])
                x, y = positions[route[left_index]]
                for index in range(left_index + 1, right_index):
                    station_id = route[index]
                    if station_id in positions:
                        x, y = positions[station_id]
                        continue
                    x += direction[0] * spacing
                    y += direction[1] * spacing
                    positions[station_id] = (x, y)
                    changed = True

            first_known = known[0]
            if first_known > 0:
                direction = snapped_direction(stations[route[first_known]], stations[route[0]])
                x, y = positions[route[first_known]]
                for index in range(first_known - 1, -1, -1):
                    x += direction[0] * spacing
                    y += direction[1] * spacing
                    station_id = route[index]
                    if station_id not in positions:
                        positions[station_id] = (x, y)
                        changed = True

            last_known = known[-1]
            if last_known < len(route) - 1:
                direction = snapped_direction(stations[route[last_known]], stations[route[-1]])
                x, y = positions[route[last_known]]
                for index in range(last_known + 1, len(route)):
                    x += direction[0] * spacing
                    y += direction[1] * spacing
                    station_id = route[index]
                    if station_id not in positions:
                        positions[station_id] = (x, y)
                        changed = True
        if not changed:
            break

    for station_id, station in stations.items():
        positions.setdefault(
            station_id,
            schematic_point(station["name"], station["latitude"], station["longitude"]),
        )
    return positions


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


def schematic_route_point(
    line_id: str,
    station_id: str,
    stations: dict[str, dict[str, Any]],
    station_points: dict[str, tuple[float, float]],
) -> tuple[float, float]:
    station_name = stations[station_id]["name"]
    return SCHEMATIC_ROUTE_POINT_OVERRIDES.get(
        (line_id, station_name),
        station_points[station_id],
    )


def schematic_segment_path(
    line_id: str,
    from_id: str,
    to_id: str,
    stations: dict[str, dict[str, Any]],
    station_points: dict[str, tuple[float, float]],
) -> list[dict[str, float]]:
    from_name = stations[from_id]["name"]
    to_name = stations[to_id]["name"]
    direct_key = (line_id, from_name, to_name)
    reverse_key = (line_id, to_name, from_name)
    if direct_key in SCHEMATIC_SEGMENT_PATH_OVERRIDES:
        points = SCHEMATIC_SEGMENT_PATH_OVERRIDES[direct_key]
        return [{"x": x, "y": y} for x, y in points]
    if reverse_key in SCHEMATIC_SEGMENT_PATH_OVERRIDES:
        points = reversed(SCHEMATIC_SEGMENT_PATH_OVERRIDES[reverse_key])
        return [{"x": x, "y": y} for x, y in points]
    return octilinear_path(
        schematic_route_point(line_id, from_id, stations, station_points),
        schematic_route_point(line_id, to_id, stations, station_points),
    )


def geographic_line_strings(payload: dict[str, Any]) -> list[list[tuple[float, float]]]:
    """Decode TfL's JSON-encoded GeoJSON-style [longitude, latitude] routes."""
    results: list[list[tuple[float, float]]] = []
    for raw_value in payload.get("lineStrings", []):
        try:
            value = json.loads(raw_value) if isinstance(raw_value, str) else raw_value
        except json.JSONDecodeError:
            continue

        def visit(node: Any) -> None:
            if isinstance(node, dict):
                if "coordinates" in node:
                    visit(node["coordinates"])
                return
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
    args = parse_args()
    existing_geography: dict[str, list[dict[str, float]]] = {}
    if args.output.is_file():
        try:
            existing_graph = json.loads(args.output.read_text(encoding="utf-8"))
            existing_geography = {
                segment["id"]: segment.get("geographicPoints", [])
                for segment in existing_graph.get("segments", [])
            }
        except (OSError, json.JSONDecodeError, KeyError):
            pass
    osm_router = None
    if args.osm_pbf is not None:
        if not args.osm_pbf.is_file():
            raise FileNotFoundError(f"OSM PBF not found: {args.osm_pbf}")
        from osm_railway_router import OSMTubeRailwayRouter

        print(f"Loading OpenStreetMap Tube railway graph from {args.osm_pbf}...", file=sys.stderr)
        osm_router = OSMTubeRailwayRouter(args.osm_pbf)

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
                    "hubID": point.get("topMostParentId") or point.get("parentId"),
                }
                station_lines[station_id].add(line_id)

        for route in payload.get("orderedLineRoutes", []):
            for station_id in route.get("naptanIds", []):
                station_lines[station_id].add(line_id)

    hub_lines: defaultdict[str, set[str]] = defaultdict(set)
    for station_id, station in station_records.items():
        hub_lines[station.get("hubID") or station_id].update(station_lines[station_id])

    stations: list[dict[str, Any]] = []
    station_points = topology_schematic_points(station_records, line_payloads)
    for station_id, station in station_records.items():
        x, y = station_points[station_id]
        lines = sorted(station_lines[station_id])
        stations.append(
            {
                **station,
                "schematicX": x,
                "schematicY": y,
                "lineIDs": lines,
                "interchange": len(hub_lines[station.get("hubID") or station_id]) > 1,
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
                # Keep the last reviewed OSM track geometry during API-only
                # topology refreshes. TfL's route sequence geometry is often
                # only station-to-station for DLR and Elizabeth line, so
                # discarding these points would turn the map back into chords.
                geographic_points = existing_geography.get(segment_id)
                if osm_router is not None:
                    osm_geographic_points = osm_router.path(
                        line_id,
                        (float(from_station["longitude"]), float(from_station["latitude"])),
                        (float(to_station["longitude"]), float(to_station["latitude"])),
                    )
                    if osm_geographic_points is not None:
                        geographic_points = osm_geographic_points
                    else:
                        fallback_name = (
                            "existing OSM geometry" if geographic_points else "TfL fallback"
                        )
                        print(
                            f"WARNING: OSM route unavailable for {line_id} "
                            f"{from_station['name']} -> {to_station['name']}; using {fallback_name}",
                            file=sys.stderr,
                        )
                if geographic_points is None:
                    geographic_points = routed_geographic_path(
                        from_station, to_station, line_strings
                    )

                segments.append(
                    {
                        "id": segment_id,
                        "lineID": line_id,
                        "fromStationID": from_id,
                        "toStationID": to_id,
                        "schematicPoints": schematic_segment_path(
                            line_id,
                            from_id,
                            to_id,
                            station_records,
                            station_points,
                        ),
                        "geographicPoints": geographic_points,
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

    uses_osm_geometry = osm_router is not None or bool(existing_geography)
    graph = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "source": {
            "name": "TfL topology with OpenStreetMap railway geometry" if uses_osm_geometry else "Transport for London Unified API",
            "url": "https://www.openstreetmap.org/copyright" if uses_osm_geometry else f"{API_BASE}/Line/{{lineId}}/Route/Sequence/outbound",
            "attribution": "Data provided by Transport for London; © OpenStreetMap contributors" if uses_osm_geometry else "Data provided by Transport for London",
        },
        "schematicSize": {"width": 1400.0, "height": 1000.0},
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

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(graph, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(
        f"Wrote {args.output}: {len(stations)} stations, {len(segments)} line segments, {len(lines)} lines",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (urllib.error.URLError, TimeoutError) as error:
        print(f"Network error: {error}", file=sys.stderr)
        raise SystemExit(2)
