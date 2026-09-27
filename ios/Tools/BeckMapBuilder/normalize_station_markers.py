#!/usr/bin/env python3
"""Normalize ordinary station artwork to line-coloured tick markers.

The map builders preserve explicit roundels and connectors for interchanges.
After every network has been composed, this pass replaces a remaining roundel
with a tick only when the station belongs to one line, has no colocated station
record, is not touched by authored connector artwork and is not drawn as an
interchange by the TfL reference (National Rail and River Bus interchanges are
single-line roundels on the official map).
"""

from __future__ import annotations

import argparse
import json
import math
from collections import Counter
from pathlib import Path

import reference_alignment
from map_geometry import (
    Point,
    acute_angle as _acute_angle,
    command_point as _command_point,
    distance as _distance,
    midpoint as _midpoint,
    path_end,
    path_end_tangent,
    path_start,
    path_start_tangent,
    point as _point,
    translated,
)

CONNECTION_KINDS = {"connector", "walkingConnector"}
CONNECTION_TOLERANCE = 10.0
REFERENCE_SYMBOL_TOLERANCE = 1.0
# TfL ticks run one tick length out from the line centre on the station-name
# side; a terminus has a bar of twice that length centred across the line end.
TICK_HALF_LENGTH = reference_alignment.TICK_LENGTH
TICK_WIDTH = reference_alignment.TICK_WIDTH
PATH_ATTACHMENT_TOLERANCE = 1.0
TICK_ANGLE_TOLERANCE_DEGREES = 0.5

# TubeGraph does not currently group this documented out-of-station
# interchange, and the traced artwork has no connector primitive to discover.
ADDITIONAL_CONNECTED_STATION_IDS = {
    "910GHACKNYC",  # Hackney Central
    "910GHAKNYNM",  # Hackney Downs
    "910GHAYESAH",  # Hayes & Harlington branch junction
}


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


def _nearest_station_endpoint(
    document: dict, paths_by_id: dict[str, dict], station_id: str,
    line_id: str, target: Point,
) -> tuple[float, Point, Point, str] | None:
    matches: list[tuple[float, Point, Point, str]] = []
    for segment in document["segments"]:
        if segment["lineID"] != line_id or station_id not in {
            segment["fromStationID"], segment["toStationID"]
        }:
            continue
        commands = paths_by_id[segment["pathID"]]["commands"]
        station_is_path_start = (
            segment["fromStationID"] == station_id
        ) == (segment["pathDirection"] == "forward")
        endpoint = path_start(commands) if station_is_path_start else path_end(commands)
        tangent = (
            path_start_tangent(commands)
            if station_is_path_start
            else path_end_tangent(commands)
        )
        if tangent is None:
            continue
        translation = segment.get("translation", {"x": 0, "y": 0})
        endpoint = translated(endpoint, translation)
        matches.append((_distance(target, endpoint), endpoint, tangent, segment["id"]))
    return min(matches, key=lambda match: (match[0], match[3]), default=None)


def _normal(line_id: str, tangent: Point) -> Point:
    magnitude = math.hypot(*tangent)
    if magnitude <= 0.001:
        raise ValueError(f"Cannot draw a tick for {line_id} from a zero tangent")
    return (
        -tangent[1] / magnitude * TICK_HALF_LENGTH,
        tangent[0] / magnitude * TICK_HALF_LENGTH,
    )


def _tick_record(line_id: str, start: Point, end: Point) -> dict:
    return {
        "kind": "tick",
        "tick": {
            "lineID": line_id,
            "start": _rounded(start),
            "end": _rounded(end),
            "width": TICK_WIDTH,
        },
    }


def _tick(line_id: str, centre: Point, tangent: Point) -> dict:
    """A terminus bar centred across the end of the line."""
    normal = _normal(line_id, tangent)
    return _tick_record(
        line_id,
        (centre[0] - normal[0], centre[1] - normal[1]),
        (centre[0] + normal[0], centre[1] + normal[1]),
    )


def _one_sided_tick(line_id: str, port: Point, tangent: Point, towards: Point | None) -> dict:
    """A through-station tick from the line centre towards `towards`."""
    normal = _normal(line_id, tangent)
    side = 1.0
    if towards is not None:
        along = (towards[0] - port[0]) * normal[0] + (towards[1] - port[1]) * normal[1]
        side = -1.0 if along < 0 else 1.0
    return _tick_record(
        line_id, port, (port[0] + side * normal[0], port[1] + side * normal[1])
    )


def _station_degree(document: dict, station_id: str, line_id: str) -> int:
    return sum(
        1 for segment in document["segments"]
        if segment["lineID"] == line_id
        and station_id in {segment["fromStationID"], segment["toStationID"]}
    )


def _circle(centre: Point) -> dict:
    return {
        "kind": "circle",
        "circle": {
            "centre": _rounded(centre),
            "radius": reference_alignment.ROUNDEL_RADIUS,
            "outlineWidth": reference_alignment.ROUNDEL_OUTLINE_WIDTH,
        },
    }


def _reference_symbol_centres(reference: dict | None) -> list[Point]:
    if reference is None:
        path = reference_alignment.REFERENCE_PATH
        if not path.exists():
            return []
        reference = json.loads(path.read_text())
    return [(float(symbol["x"]), float(symbol["y"])) for symbol in reference["symbols"]]


def _promote_connector_endpoint_ticks(document: dict) -> int:
    markers = document["stationMarkers"]
    circles = [
        _point(primitive["circle"]["centre"])
        for marker in markers
        for primitive in marker["primitives"]
        if primitive["kind"] == "circle"
    ]
    endpoints = _connector_endpoints(markers)
    promoted = 0
    for endpoint in endpoints:
        if any(_distance(endpoint, centre) <= PATH_ATTACHMENT_TOLERANCE for centre in circles):
            continue
        candidates: list[tuple[float, str, dict, list[int]]] = []
        for marker in markers:
            # A tick anchors at its start (through stations) or midpoint (termini).
            matching_ticks = [
                index
                for index, primitive in enumerate(marker["primitives"])
                if primitive["kind"] == "tick"
                and min(
                    _distance(endpoint, _point(primitive["tick"]["start"])),
                    _distance(endpoint, _midpoint(
                        _point(primitive["tick"]["start"]),
                        _point(primitive["tick"]["end"]),
                    )),
                ) <= PATH_ATTACHMENT_TOLERANCE
            ]
            anchor_distance = _distance(endpoint, _point(marker["anchor"]))
            if matching_ticks or anchor_distance <= PATH_ATTACHMENT_TOLERANCE:
                candidates.append((anchor_distance, marker["stationID"], marker, matching_ticks))
        if not candidates:
            continue
        _, _, marker, matching_ticks = min(candidates, key=lambda value: (value[0], value[1]))
        marker["primitives"] = [
            primitive
            for index, primitive in enumerate(marker["primitives"])
            if index not in matching_ticks
        ]
        marker["primitives"].append(_circle(endpoint))
        circles.append(endpoint)
        promoted += 1
    return promoted


def _normalize_tick_angles(document: dict) -> int:
    """Regenerate skewed ticks from the local route tangent.

    A tick that starts on its station port is a one-sided through-station
    tick and keeps its side; one centred on the port is a terminus bar."""
    paths_by_id = {path["id"]: path for path in document["paths"]}
    corrected = 0
    for marker in document["stationMarkers"]:
        for index, primitive in enumerate(marker["primitives"]):
            if primitive["kind"] != "tick":
                continue
            tick = primitive["tick"]
            start = _point(tick["start"])
            end = _point(tick["end"])
            centre = _midpoint(start, end)
            one_sided = _nearest_station_endpoint(
                document, paths_by_id, marker["stationID"], tick["lineID"], start
            )
            if one_sided is not None and one_sided[0] <= PATH_ATTACHMENT_TOLERANCE:
                match, anchor = one_sided, start
            else:
                match = _nearest_station_endpoint(
                    document, paths_by_id, marker["stationID"], tick["lineID"], centre
                )
                anchor = centre
            if match is None or match[0] > PATH_ATTACHMENT_TOLERANCE:
                continue
            tick_vector = (end[0] - start[0], end[1] - start[1])
            deviation = abs(90.0 - _acute_angle(tick_vector, match[2]))
            if deviation <= TICK_ANGLE_TOLERANCE_DEGREES:
                continue
            if anchor is start:
                marker["primitives"][index] = _one_sided_tick(tick["lineID"], start, match[2], end)
            else:
                marker["primitives"][index] = _tick(tick["lineID"], centre, match[2])
            corrected += 1
    return corrected


def normalize(document: dict, graph: dict, reference: dict | None = None) -> int:
    """Normalize ordinary ticks and interchange endpoints after composition."""
    reference_centres = _reference_symbol_centres(reference)
    stations_by_id = {station["id"]: station for station in graph["stations"]}
    hub_sizes = Counter(
        station.get("hubID") or station["id"] for station in graph["stations"]
    )
    paths_by_id = {path["id"]: path for path in document["paths"]}
    connector_endpoints = _connector_endpoints(document["stationMarkers"])
    labels: dict[str, Point] = {}
    for label in document.get("labels", []):
        for station_id in (label["stationID"], *label.get("associatedStationIDs", ())):
            labels.setdefault(station_id, _point(label["position"]))
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
            or any(
                _distance(centre, symbol) <= REFERENCE_SYMBOL_TOLERANCE
                for centre in circle_points
                for symbol in reference_centres
            )
        ):
            continue

        line_id = station["lineIDs"][0]
        retained = [
            primitive for primitive in marker["primitives"]
            if primitive["kind"] != "circle"
        ]
        if not any(primitive["kind"] == "tick" for primitive in retained):
            for centre in circle_points:
                match = _nearest_station_endpoint(
                    document, paths_by_id, marker["stationID"], line_id, centre
                )
                if match is None:
                    tangent = _station_tangent(
                        document, paths_by_id, marker["stationID"], line_id, centre
                    )
                    retained.append(_tick(line_id, centre, tangent))
                elif _station_degree(document, marker["stationID"], line_id) == 1:
                    retained.append(_tick(line_id, match[1], match[2]))
                else:
                    retained.append(_one_sided_tick(
                        line_id, match[1], match[2], labels.get(marker["stationID"])
                    ))
        marker["primitives"] = retained
        normalized_count += 1

    normalized_count += _promote_connector_endpoint_ticks(document)
    normalized_count += _normalize_tick_angles(document)
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
