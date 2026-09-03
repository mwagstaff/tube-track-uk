#!/usr/bin/env python3
"""Normalize ordinary station artwork to line-coloured tick markers.

The map builders preserve explicit roundels and connectors for interchanges.
After every network has been composed, this pass replaces a remaining roundel
with a tick only when the station belongs to one line, has no colocated station
record, and is not touched by authored connector artwork.
"""

from __future__ import annotations

import argparse
import json
import math
from collections import Counter
from pathlib import Path


Point = tuple[float, float]
CONNECTION_KINDS = {"connector", "walkingConnector"}
CONNECTION_TOLERANCE = 10.0
TICK_HALF_LENGTH = 7.0
TICK_WIDTH = 3.2

# TubeGraph does not currently group this documented out-of-station
# interchange, and the traced artwork has no connector primitive to discover.
ADDITIONAL_CONNECTED_STATION_IDS = {
    "910GHACKNYC",  # Hackney Central
    "910GHAKNYNM",  # Hackney Downs
}


def _point(value: dict) -> Point:
    return (value["x"], value["y"])


def _rounded(point: Point) -> dict:
    return {"x": round(point[0], 3), "y": round(point[1], 3)}


def _connector_endpoints(markers: list[dict]) -> list[Point]:
    endpoints: list[Point] = []
    for marker in markers:
        for primitive in marker["primitives"]:
            kind = primitive["kind"]
            if kind not in CONNECTION_KINDS:
                continue
            connector = primitive[kind]
            endpoints.extend((_point(connector["start"]), _point(connector["end"])))
    return endpoints


def _marker_points(marker: dict) -> list[Point]:
    circle_points = [
        _point(primitive["circle"]["centre"])
        for primitive in marker["primitives"]
        if primitive["kind"] == "circle"
    ]
    return circle_points or [_point(marker["anchor"])]


def _is_connected(marker: dict, connector_endpoints: list[Point]) -> bool:
    if any(primitive["kind"] in CONNECTION_KINDS for primitive in marker["primitives"]):
        return True
    return any(
        math.dist(marker_point, endpoint) <= CONNECTION_TOLERANCE
        for marker_point in _marker_points(marker)
        for endpoint in connector_endpoints
    )


def _command_point(command: dict, key: str = "to") -> Point:
    return _point(command[key])


def _start_tangent(commands: list[dict]) -> Point:
    start = _command_point(commands[0])
    for command in commands[1:]:
        operation = command["op"]
        if operation == "cubic":
            candidates = (_command_point(command, "control1"), _command_point(command))
        elif operation == "line":
            candidates = (_command_point(command),)
        else:
            continue
        for candidate in candidates:
            tangent = (candidate[0] - start[0], candidate[1] - start[1])
            if math.hypot(*tangent) > 0.001:
                return tangent
    raise ValueError("Path has no non-zero tangent at its start")


def _end_tangent(commands: list[dict]) -> Point:
    current = _command_point(commands[0])
    drawable: list[tuple[dict, Point]] = []
    for command in commands[1:]:
        if command["op"] in {"line", "cubic"}:
            drawable.append((command, current))
            current = _command_point(command)
    for command, previous in reversed(drawable):
        end = _command_point(command)
        if command["op"] == "cubic":
            candidates = (_command_point(command, "control2"), previous)
        else:
            candidates = (previous,)
        for candidate in candidates:
            tangent = (end[0] - candidate[0], end[1] - candidate[1])
            if math.hypot(*tangent) > 0.001:
                return tangent
    raise ValueError("Path has no non-zero tangent at its end")


def _station_tangent(
    document: dict,
    paths_by_id: dict[str, dict],
    station_id: str,
    line_id: str,
    marker_point: Point,
) -> Point:
    candidates: list[tuple[float, str, Point]] = []
    for segment in document["segments"]:
        if segment["lineID"] != line_id or station_id not in {
            segment["fromStationID"], segment["toStationID"]
        }:
            continue
        commands = paths_by_id[segment["pathID"]]["commands"]
        starts_at_station = (
            segment["fromStationID"] == station_id
            if segment["pathDirection"] == "forward"
            else segment["toStationID"] == station_id
        )
        endpoint = _command_point(commands[0] if starts_at_station else commands[-1])
        translation = segment.get("translation", {"x": 0, "y": 0})
        endpoint = (
            endpoint[0] + translation["x"],
            endpoint[1] + translation["y"],
        )
        tangent = _start_tangent(commands) if starts_at_station else _end_tangent(commands)
        candidates.append((math.dist(endpoint, marker_point), segment["id"], tangent))
    if not candidates:
        raise ValueError(f"Station {station_id} has no authored {line_id} path tangent")
    return min(candidates, key=lambda candidate: (candidate[0], candidate[1]))[2]


def _tick(line_id: str, centre: Point, tangent: Point) -> dict:
    magnitude = math.hypot(*tangent)
    if magnitude <= 0.001:
        raise ValueError(f"Cannot draw a tick for {line_id} from a zero tangent")
    normal = (
        -tangent[1] / magnitude * TICK_HALF_LENGTH,
        tangent[0] / magnitude * TICK_HALF_LENGTH,
    )
    return {
        "kind": "tick",
        "tick": {
            "lineID": line_id,
            "start": _rounded((centre[0] - normal[0], centre[1] - normal[1])),
            "end": _rounded((centre[0] + normal[0], centre[1] + normal[1])),
            "width": TICK_WIDTH,
        },
    }


def normalize(document: dict, graph: dict) -> int:
    """Replace false roundels and return the number of normalized stations."""
    stations_by_id = {station["id"]: station for station in graph["stations"]}
    hub_sizes = Counter(
        station.get("hubID") or station["id"] for station in graph["stations"]
    )
    paths_by_id = {path["id"]: path for path in document["paths"]}
    connector_endpoints = _connector_endpoints(document["stationMarkers"])
    normalized_count = 0

    for marker in document["stationMarkers"]:
        station = stations_by_id[marker["stationID"]]
        circle_points = [
            _point(primitive["circle"]["centre"])
            for primitive in marker["primitives"]
            if primitive["kind"] == "circle"
        ]
        if not circle_points:
            continue
        hub_id = station.get("hubID") or station["id"]
        if (
            len(station["lineIDs"]) != 1
            or hub_sizes[hub_id] != 1
            or marker["stationID"] in ADDITIONAL_CONNECTED_STATION_IDS
            or _is_connected(marker, connector_endpoints)
        ):
            continue

        line_id = station["lineIDs"][0]
        retained = [
            primitive for primitive in marker["primitives"]
            if primitive["kind"] != "circle"
        ]
        if not any(primitive["kind"] == "tick" for primitive in retained):
            for centre in circle_points:
                tangent = _station_tangent(
                    document, paths_by_id, marker["stationID"], line_id, centre
                )
                retained.append(_tick(line_id, centre, tangent))
        marker["primitives"] = retained
        normalized_count += 1

    return normalized_count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--document", required=True, type=Path)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    document = json.loads(arguments.document.read_text())
    graph = json.loads(arguments.graph.read_text())
    count = normalize(document, graph)
    arguments.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"Normalized {count} ordinary station markers")


if __name__ == "__main__":
    main()
