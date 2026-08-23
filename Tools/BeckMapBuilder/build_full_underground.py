#!/usr/bin/env python3
"""Compose the complete Underground map in the official TfL design space.

This is an offline artwork compiler. It does not calculate a layout. Existing
trace-verified slices are translated back into the fixed PDF coordinate space,
and the three seams absent from those slices are split directly from the same
official vector master paths. TubeGraph supplies identifiers and adjacency only.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

import build_central_core_join as vector
import build_rail_extensions as rail
import build_overground_extensions as overground


ARTWORK_WIDTH = 4764.0
ARTWORK_HEIGHT = 3632.0
SUPPLEMENTAL_HEATHROW_SEGMENT_ID = "piccadilly:940GZZLUHNX:940GZZLUHR4"
UNDERGROUND_LINE_IDS = {
    "bakerloo", "central", "circle", "district", "hammersmith-city",
    "jubilee", "metropolitan", "northern", "piccadilly", "victoria",
    "waterloo-city",
}
@dataclass(frozen=True)
class Slice:
    name: str
    origin: vector.Point


# Order is intentional: when verified slices overlap, the most recently
# corrected branch/interchange artwork owns the semantic segment and marker.
SLICES = (
    Slice("western-fan", (100.0, 600.0)),
    Slice("eastern-fan", (2750.0, 350.0)),
    Slice("south-connector", (1250.0, 1550.0)),
    Slice("northwest-connector", (100.0, 300.0)),
    Slice("north-connector", (1250.0, 450.0)),
    Slice("central-completion", (1500.0, 1250.0)),
    Slice("central-core-join", (900.0, 700.0)),
    Slice("east-connector", (1200.0, 600.0)),
)


def point(x: float, y: float) -> vector.Point:
    return (x, y)


# Approximate ports are manually identified in the 4,764 x 3,632 vector design
# space. The compiler snaps them to exact points on the selected master path.
SEAM_ROUTES = (
    vector.RouteSpec(
        "circle.shared-central.full.v1", "circle", "98.728943%", 1,
        tuple((name, point(x, y)) for name, (x, y) in (
            ("Paddington (H&C Line)-Underground", (1460, 1386)),
            ("Edgware Road (Circle Line)", (1492, 1386)),
            ("Baker Street", (1682, 1400)),
            ("Great Portland Street", (1785, 1400)),
            ("Euston Square", (1915, 1400)),
            ("King's Cross St. Pancras", (2140, 1400)),
            ("Farringdon", (2205, 1470)),
            ("Barbican", (2265, 1550)),
            ("Moorgate", (2355, 1580)),
            ("Liverpool Street", (2385, 1550)),
        )),
    ),
    vector.RouteSpec(
        "hammersmith-city.shared-central.full.v1", "hammersmith-city", "93.824768%", 1,
        tuple((name, point(x, y)) for name, (x, y) in (
            ("Paddington (H&C Line)-Underground", (1460, 1378)),
            ("Edgware Road (Circle Line)", (1492, 1378)),
            ("Baker Street", (1682, 1400)),
            ("Great Portland Street", (1785, 1400)),
            ("Euston Square", (1915, 1400)),
            ("King's Cross St. Pancras", (2140, 1400)),
            ("Farringdon", (2205, 1470)),
            ("Barbican", (2265, 1550)),
            ("Moorgate", (2355, 1580)),
            ("Liverpool Street", (2385, 1550)),
        )),
    ),
    vector.RouteSpec(
        "metropolitan.shared-central.full.v1", "metropolitan", "51.182556%", 2,
        tuple((name, point(x, y)) for name, (x, y) in (
            ("Baker Street", (1682, 1400)),
            ("Great Portland Street", (1785, 1400)),
            ("Euston Square", (1915, 1400)),
            ("King's Cross St. Pancras", (2140, 1400)),
            ("Farringdon", (2205, 1470)),
            ("Barbican", (2265, 1550)),
            ("Moorgate", (2355, 1580)),
            ("Liverpool Street", (2385, 1550)),
        )),
    ),
    vector.RouteSpec(
        "waterloo-city.full.v1", "waterloo-city", "53.001404%", 0,
        (("Waterloo", point(1970, 1970)), ("Bank", point(2345, 1610))),
    ),
    vector.RouteSpec(
        "piccadilly.heathrow-trunk.full.v1", "piccadilly", "17.060852%", 1,
        tuple((name, point(x, y)) for name, (x, y) in (
            ("Heathrow Terminal 5", (202, 2288)),
            ("Heathrow Terminals 2 & 3", (318, 2118)),
            ("Hatton Cross", (344, 2094)),
            ("Hounslow West", (410, 2030)),
            ("Hounslow Central", (450, 1993)),
            ("Hounslow East", (469, 1967)),
            ("Osterley", (498, 1939)),
            ("Boston Manor", (519, 1918)),
            ("Northfields", (545, 1892)),
            ("South Ealing", (588, 1849)),
            ("Acton Town", (708, 1843)),
        )),
    ),
    vector.RouteSpec(
        "piccadilly.heathrow-loop.full.v1", "piccadilly", "17.060852%", 3,
        (("Hatton Cross", point(356, 2081)),
         ("Heathrow Terminal 4", point(319, 2288)),
         ("Heathrow Terminals 2 & 3", point(238, 2203))),
    ),
)


LABEL_OFFSETS: dict[str, tuple[float, float, str]] = {
    "Great Portland Street": (0, 28, "centre"),
    "Euston Square": (0, 28, "centre"),
    "Farringdon": (20, 12, "leading"),
    "Barbican": (20, 12, "leading"),
    "Heathrow Terminal 5": (0, 34, "centre"),
    "Heathrow Terminals 2 & 3": (-22, -24, "trailing"),
    "Hatton Cross": (24, 0, "leading"),
    "Heathrow Terminal 4": (0, 34, "centre"),
    "Hounslow West": (18, 12, "leading"),
    "Hounslow Central": (18, 12, "leading"),
    "Hounslow East": (18, 12, "leading"),
    "Osterley": (18, 12, "leading"),
    "Boston Manor": (-18, -10, "trailing"),
    "Northfields": (18, 12, "leading"),
    "South Ealing": (-18, -10, "trailing"),
}


LABEL_OVERRIDES: dict[str, tuple[float, float, str]] = {
    # The source slices intentionally use artwork-space label positions. Keep
    # Waterloo close to its interchange rather than inheriting the historic
    # wide-left placement from the early south prototype.
    "Waterloo": (-34, 25, "trailing"),
    # Both names sit in deliberately open areas so their high-priority labels
    # remain placeable before the user reaches maximum zoom.
    "Edgware Road (Circle Line)": (0, 48, "centre"),
    "Bond Street": (-36, -24, "trailing"),
    # Both semantic Paddington records share one visible station name. Their
    # preferred label directions converge on the same southeast label area.
    "Paddington": (108, 70, "leading"),
    "Paddington (H&C Line)-Underground": (63, 40, "leading"),
    # Royal Oak is deliberately displayed on the outward diagonal approach,
    # matching the official map's separation from Paddington.
    "Royal Oak": (-18, -16, "trailing"),
    # Keep Ruislip's name attached to its corrected shared-corridor stop,
    # rather than retaining the earlier label position at the Central crossing.
    "Ruislip": (0, 22, "centre"),
    # The Central-line stop is deliberately south of the Piccadilly /
    # Metropolitan crossing, so its name remains attached to the relocated
    # tick without suggesting an interchange with either shared-corridor line.
    "Ruislip Gardens": (-18, 12, "trailing"),
    # Stepney Green uses the open lower-right area, while Mile End moves above
    # its interchange to keep the two high-priority labels independently
    # placeable at compact zoom levels.
    "Stepney Green": (20, 28, "leading"),
    "Mile End": (0, -64, "centre"),
    "Barking": (0, -22, "centre"),
    # Keep both labels attached to the west-shifted Jubilee stations. These
    # offsets reproduce the trace-verified label relationship while the
    # authored ports move left to broaden the Canning Town sweep.
    "Canary Wharf": (-10, -56, "trailing"),
    "North Greenwich": (-18, 5, "trailing"),
    # Prefer the open lower-right quadrant, beyond the Jubilee line, so the
    # name cannot be mistaken for nearby East India at compact zoom levels.
    "Canning Town": (28, 48, "leading"),
    "Stratford": (20, 16, "leading"),
    # Match the official map's grouping: the name belongs to the elevated
    # Jubilee node, left of the District / H&C corridor node.
    "West Ham": (-18, 0, "trailing"),
}


LABEL_TEXT_OVERRIDES: dict[str, str] = {
    "Edgware Road (Circle Line)": "Edgware Road\n(Circle Line)",
    "Bond Street": "Bond\nStreet",
}


HEATHROW_VISIBLE_ROUTE: dict[str, str] = {
    "940GZZLUHR5": "piccadilly.heathrow-trunk.full.v1",
    "940GZZLUHRC": "piccadilly.heathrow-trunk.full.v1",
    "940GZZLUHNX": "piccadilly.heathrow-trunk.full.v1",
    "940GZZLUHR4": "piccadilly.heathrow-loop.full.v1",
}


HEATHROW_LABEL_TEXT: dict[str, str] = {
    "Heathrow Terminal 5": "Heathrow\nTerminal 5",
    "Heathrow Terminals 2 & 3": "Heathrow\nTerminals 2 & 3",
    "Heathrow Terminal 4": "Heathrow\nTerminal 4",
}


# These are ordinary stops on shared corridors. Their multiple semantic line
# memberships must not promote them to interchange roundels.
ORDINARY_SHARED_STATION_TANGENTS: dict[str, vector.Point] = {
    "Bayswater": (0, 1),
    "High Street Kensington": (0, 1),
    "Sloane Square": (1, 0),
    "St. James's Park": (1, 0),
    "Temple": (1, 0),
    "Mansion House": (1, 1),
    "Barbican": (1, 1),
    "Stepney Green": (1, 0),
}


# These are ordinary stops served by both lines, not interchange complexes.
# The tangent is the authored shared-corridor direction at each station.
UXBRIDGE_SHARED_STATION_TANGENTS: dict[str, vector.Point] = {
    "Uxbridge": (1, 0),
    "Hillingdon": (1, 0),
    "Ickenham": (1, 0),
    "Ruislip": (1, 0),
    "Ruislip Manor": (1, 0),
    "Eastcote": (1, 1),
}


def shifted_point(value: dict, origin: vector.Point) -> dict:
    return vector.rounded((value["x"] + origin[0], value["y"] + origin[1]))


def translated_point(value: dict, dx: float, dy: float) -> dict:
    return vector.rounded((value["x"] + dx, value["y"] + dy))


def translate_segment_and_path(segment: dict, path: dict, dx: float, dy: float) -> None:
    for command in path["commands"]:
        for key in ("to", "control1", "control2"):
            if key in command:
                command[key] = translated_point(command[key], dx, dy)
    for key in ("fromPort", "toPort"):
        segment[key] = translated_point(segment[key], dx, dy)


def translate_station_endpoint(
    segment: dict,
    path: dict,
    station_id: str,
    dx: float,
    dy: float,
) -> None:
    if segment["fromStationID"] == station_id:
        port_key = "fromPort"
        station_is_path_start = segment["pathDirection"] == "forward"
    elif segment["toStationID"] == station_id:
        port_key = "toPort"
        station_is_path_start = segment["pathDirection"] == "reverse"
    else:
        raise ValueError(f"Segment {segment['id']} does not meet station {station_id}")

    segment[port_key] = translated_point(segment[port_key], dx, dy)
    command = path["commands"][0 if station_is_path_start else -1]
    if command["op"] not in {"move", "line", "cubic"} or "to" not in command:
        raise ValueError(f"Unexpected endpoint command for {segment['id']}")
    command["to"] = translated_point(command["to"], dx, dy)


def shift_document(document: dict, origin: vector.Point) -> dict:
    result = copy.deepcopy(document)
    for path in result["paths"]:
        for command in path["commands"]:
            for key in ("to", "control1", "control2"):
                if key in command:
                    command[key] = shifted_point(command[key], origin)
    for segment in result["segments"]:
        for key in ("fromPort", "toPort"):
            if segment.get(key) is not None:
                segment[key] = shifted_point(segment[key], origin)
    for marker in result["stationMarkers"]:
        marker["anchor"] = shifted_point(marker["anchor"], origin)
        for primitive in marker["primitives"]:
            payload = primitive[primitive["kind"]]
            for key in ("start", "end", "centre"):
                if key in payload:
                    payload[key] = shifted_point(payload[key], origin)
    for label in result["labels"]:
        label["position"] = shifted_point(label["position"], origin)
    result["artworkSize"] = {"width": ARTWORK_WIDTH, "height": ARTWORK_HEIGHT}
    return result


def tick_at(line_id: str, point_value: vector.Point, tangent: vector.Point) -> dict:
    dx, dy = tangent
    magnitude = math.hypot(dx, dy) or 1
    normal = (-dy / magnitude * 7, dx / magnitude * 7)
    return {"kind": "tick", "tick": {
        "lineID": line_id,
        "start": vector.rounded((point_value[0] - normal[0], point_value[1] - normal[1])),
        "end": vector.rounded((point_value[0] + normal[0], point_value[1] + normal[1])),
        "width": 3.2,
    }}


def tick_primitive(line_id: str, match: vector.Match) -> dict:
    return tick_at(line_id, match.point, match.tangent)


def circle(point_value: vector.Point) -> dict:
    return {"kind": "circle", "circle": {
        "centre": vector.rounded(point_value), "radius": 8.5, "outlineWidth": 3.5,
    }}


def connector(start: vector.Point, end: vector.Point) -> dict:
    return {"kind": "connector", "connector": {
        "start": vector.rounded(start), "end": vector.rounded(end), "width": 7.5,
    }}


def primitive_points(marker: dict) -> list[vector.Point]:
    points: list[vector.Point] = []
    for primitive in marker["primitives"]:
        if primitive["kind"] == "circle":
            centre = primitive["circle"]["centre"]
            points.append((centre["x"], centre["y"]))
    return points


def station_ports(segments: dict[str, dict], station_id: str, line_id: str) -> list[vector.Point]:
    ports: list[vector.Point] = []
    for segment in segments.values():
        if segment["lineID"] != line_id:
            continue
        if segment["fromStationID"] == station_id and segment.get("fromPort"):
            value = segment["fromPort"]
            ports.append((value["x"], value["y"]))
        if segment["toStationID"] == station_id and segment.get("toPort"):
            value = segment["toPort"]
            ports.append((value["x"], value["y"]))
    return vector.unique_points(ports, tolerance=3)


def average_point(points: list[vector.Point]) -> vector.Point:
    return tuple(sum(point[index] for point in points) / len(points) for index in (0, 1))


def line_port(segments: dict[str, dict], station_id: str, line_id: str) -> vector.Point:
    ports = station_ports(segments, station_id, line_id)
    if not ports:
        raise ValueError(f"Station {station_id} has no authored {line_id} port")
    return average_point(ports)


def shared_line_port(
    segments: dict[str, dict],
    station_id: str,
    line_ids: tuple[str, ...],
) -> vector.Point:
    return average_point([line_port(segments, station_id, line_id) for line_id in line_ids])


def build(svg_path: Path, graph_path: Path, resources: Path) -> dict:
    graph = json.loads(graph_path.read_text())
    stations_by_name: dict[str, dict] = {}
    for station in graph["stations"]:
        is_underground = any(
            line_id in UNDERGROUND_LINE_IDS for line_id in station["lineIDs"]
        )
        if station["name"] not in stations_by_name or is_underground:
            stations_by_name[station["name"]] = station
    stations_by_id = {station["id"]: station for station in graph["stations"]}
    graph_segments = {segment["id"]: segment for segment in graph["segments"]}

    selected_segments: dict[str, dict] = {}
    selected_paths: dict[str, dict] = {}
    marker_candidates: dict[str, list[tuple[int, dict]]] = {}
    label_candidates: dict[str, list[tuple[int, dict]]] = {}
    routes: dict[str, dict] = {}

    for priority, source in enumerate(SLICES):
        document = json.loads((resources / f"{source.name}.json").read_text())
        shifted = shift_document(document, source.origin)
        paths_by_id = {path["id"]: path for path in shifted["paths"]}
        for segment in shifted["segments"]:
            if segment["id"] in selected_segments:
                continue
            selected_segments[segment["id"]] = segment
            selected_paths[segment["pathID"]] = paths_by_id[segment["pathID"]]
        for marker in shifted["stationMarkers"]:
            marker_candidates.setdefault(marker["stationID"], []).append((priority, marker))
        for label in shifted["labels"]:
            label_candidates.setdefault(label["stationID"], []).append((priority, label))
        for route in shifted["routes"]:
            routes.setdefault(route["id"], route)

    vector.CROP_X = 0.0
    vector.CROP_Y = 0.0
    vector.ARTWORK_WIDTH = ARTWORK_WIDTH
    vector.ARTWORK_HEIGHT = ARTWORK_HEIGHT
    root = ET.parse(svg_path).getroot()
    seam_matches: dict[str, list[tuple[str, str, vector.Match]]] = {}

    for route in SEAM_ROUTES:
        master = vector.find_master_path(root, route)
        matches = [(name, vector.nearest_match(master, approximate)) for name, approximate in route.stations]
        station_ids = [stations_by_name[name]["id"] for name, _ in matches]
        route_segment_ids: list[str] = []
        for name, match in matches:
            seam_matches.setdefault(name, []).append((route.identifier, route.line_id, match))

        for index, ((from_name, from_match), (to_name, to_match)) in enumerate(zip(matches, matches[1:])):
            from_id = stations_by_name[from_name]["id"]
            to_id = stations_by_name[to_name]["id"]
            if {from_id, to_id} == {"940GZZLUHNX", "940GZZLUHR4"}:
                segment_id = SUPPLEMENTAL_HEATHROW_SEGMENT_ID
                semantic = {
                    "id": segment_id, "lineID": "piccadilly",
                    "fromStationID": from_id, "toStationID": to_id,
                }
            else:
                semantic = vector.semantic_segment(graph, route.line_id, from_id, to_id)
                segment_id = semantic["id"]

            if segment_id not in selected_segments:
                path_id = f"beck.v1.path.{route.identifier}.{index}"
                selected_paths[path_id] = {
                    "id": path_id,
                    "commands": vector.path_commands(vector.path_slice(master, from_match, to_match)),
                }
                selected_segments[segment_id] = {
                    "id": segment_id,
                    "lineID": route.line_id,
                    "fromStationID": semantic["fromStationID"],
                    "toStationID": semantic["toStationID"],
                    "fromPort": vector.rounded(from_match.point),
                    "toPort": vector.rounded(to_match.point),
                    "pathID": path_id,
                    "pathDirection": "forward",
                    "translation": {"x": 0, "y": 0},
                }
            route_segment_ids.append(segment_id)

        routes[route.identifier] = {
            "id": route.identifier,
            "lineID": route.line_id,
            "stationIDs": station_ids,
            "segmentIDs": route_segment_ids,
        }

    expected_segments = {
        segment["id"] for segment in graph["segments"]
        if segment["lineID"] in UNDERGROUND_LINE_IDS
    }
    actual_graph_segments = set(selected_segments) - {SUPPLEMENTAL_HEATHROW_SEGMENT_ID}
    if actual_graph_segments != expected_segments:
        missing = sorted(expected_segments - actual_graph_segments)
        unexpected = sorted(actual_graph_segments - expected_segments)
        raise ValueError(f"Full map segment mismatch; missing={missing}, unexpected={unexpected}")

    # The Piccadilly and Metropolitan Uxbridge traces came from two verified
    # slices with slightly different corridor offsets. Reconcile them here in
    # the fixed official design space: the Metropolitan path moves 2.5 units
    # toward Piccadilly, retaining two independently addressable paths with a
    # compact, deterministic separation. Continue that correction into the
    # first outbound Metropolitan segment so the line stays topologically
    # continuous through Rayners Lane.
    uxbridge_metropolitan_segments = (
        "metropolitan:940GZZLUHGD:940GZZLUUXB",
        "metropolitan:940GZZLUHGD:940GZZLUICK",
        "metropolitan:940GZZLUICK:940GZZLURSP",
        "metropolitan:940GZZLURSM:940GZZLURSP",
        "metropolitan:940GZZLUEAE:940GZZLURSM",
        "metropolitan:940GZZLUEAE:940GZZLURYL",
    )
    for segment_id in uxbridge_metropolitan_segments:
        segment = selected_segments[segment_id]
        translate_segment_and_path(
            segment,
            selected_paths[segment["pathID"]],
            0,
            2.5,
        )

    metropolitan_outbound = selected_segments[
        "metropolitan:940GZZLURYL:940GZZLUWHW"
    ]
    translate_station_endpoint(
        metropolitan_outbound,
        selected_paths[metropolitan_outbound["pathID"]],
        "940GZZLURYL",
        0,
        2.5,
    )

    # The official map places Ruislip to the east of the Central line's plain
    # crossing. Move both shared-corridor ports 24 units east so neither stop
    # marker nor tick can imply a Central-line interchange.
    for segment_id in (
        "metropolitan:940GZZLUICK:940GZZLURSP",
        "metropolitan:940GZZLURSM:940GZZLURSP",
        "piccadilly:940GZZLUICK:940GZZLURSP",
        "piccadilly:940GZZLURSM:940GZZLURSP",
    ):
        segment = selected_segments[segment_id]
        translate_station_endpoint(
            segment,
            selected_paths[segment["pathID"]],
            "940GZZLURSP",
            24,
            0,
        )

    def move_line_port(station_id: str, line_id: str, target: vector.Point) -> None:
        current = line_port(selected_segments, station_id, line_id)
        dx = target[0] - current[0]
        dy = target[1] - current[1]
        for segment in selected_segments.values():
            if segment["lineID"] != line_id:
                continue
            if station_id not in {segment["fromStationID"], segment["toStationID"]}:
                continue
            translate_station_endpoint(
                segment,
                selected_paths[segment["pathID"]],
                station_id,
                dx,
                dy,
            )

    def set_line_port(station_id: str, line_id: str, target: vector.Point) -> None:
        """Place every authored endpoint for one station/line at one exact port."""
        for segment in selected_segments.values():
            if segment["lineID"] != line_id:
                continue
            if station_id not in {segment["fromStationID"], segment["toStationID"]}:
                continue
            port_key = (
                "fromPort"
                if segment["fromStationID"] == station_id
                else "toPort"
            )
            current = segment[port_key]
            translate_station_endpoint(
                segment,
                selected_paths[segment["pathID"]],
                station_id,
                target[0] - current["x"],
                target[1] - current["y"],
            )

    # The Hammersmith & City and Circle lines share this vertical corridor.
    # Keep each H&C station port on the same horizontal row as its Circle peer
    # while preserving the authored side-by-side lane spacing.
    for station_id in ("940GZZLUSBM", "940GZZLUGHK", "940GZZLUHSC"):
        circle_port = line_port(selected_segments, station_id, "circle")
        hammersmith_city_port = line_port(
            selected_segments, station_id, "hammersmith-city"
        )
        set_line_port(
            station_id,
            "hammersmith-city",
            (hammersmith_city_port[0], circle_port[1]),
        )

    # Retain Stepney Green's traced shared-corridor ports. An earlier builder
    # offset moved both lanes 32 units west into the southeast Elizabeth branch;
    # the authored position remains clear of that crossing and of Mile End.

    # Aldgate is a shared Circle / Metropolitan terminus. Keep the two paths
    # parallel around the eastern corner rather than pulling the Metropolitan
    # endpoint diagonally across the Circle geometry.
    aldgate_circle_port = line_port(selected_segments, "940GZZLUALD", "circle")
    aldgate_metropolitan_port = (
        aldgate_circle_port[0] - 8.27,
        aldgate_circle_port[1],
    )
    move_line_port(
        "940GZZLUALD",
        "metropolitan",
        aldgate_metropolitan_port,
    )
    aldgate_metropolitan_segment = selected_segments[
        "metropolitan:940GZZLUALD:940GZZLULVT"
    ]
    if aldgate_metropolitan_segment["pathDirection"] != "forward":
        raise ValueError("Unexpected Aldgate Metropolitan path direction")
    aldgate_metropolitan_path = selected_paths[
        aldgate_metropolitan_segment["pathID"]
    ]
    aldgate_metropolitan_path["commands"] = [
        {"op": "move", "to": vector.rounded((2384.994, 1557.672))},
        {"op": "line", "to": vector.rounded((2536.656, 1557.817))},
        {
            "op": "cubic",
            "control1": vector.rounded((2542.2, 1557.817)),
            "control2": vector.rounded((2547.244, 1560.064)),
            "to": vector.rounded((2550.879, 1563.699)),
        },
        {
            "op": "cubic",
            "control1": vector.rounded((2554.514, 1567.334)),
            "control2": vector.rounded((2556.714, 1572.378)),
            "to": vector.rounded((2556.714, 1577.859)),
        },
        {"op": "line", "to": vector.rounded(aldgate_metropolitan_port)},
    ]

    # Bond Street has two distinct physical nodes. Bring the Central node
    # towards the Jubilee route so the short interchange connector reads as
    # one station, while retaining independently addressable line geometry.
    move_line_port("940GZZLUBND", "central", (1728.0, 1592.344))
    move_line_port("940GZZLUBND", "jubilee", (1682.0, 1620.0))

    # Marble Arch is an ordinary Central stop. Move it clear of the Jubilee
    # vertical on its west side so its tick cannot be mistaken for another
    # interchange or become part of the Bond Street interchange connector.
    move_line_port("940GZZLUMBA", "central", (1656.0, 1592.344))

    # At Baker Street the Jubilee line runs visibly straight through. Shift
    # the shared Circle / H&C / Metropolitan node east, leaving the Bakerloo
    # and Jubilee node on the vertical with a diagonal interchange link.
    for line_id in ("circle", "hammersmith-city", "metropolitan"):
        baker_shared_port = line_port(
            selected_segments, "940GZZLUBST", line_id
        )
        move_line_port(
            "940GZZLUBST",
            line_id,
            (baker_shared_port[0] + 28, baker_shared_port[1]),
        )

    # The Metropolitan line is a constant horizontal lane beneath Circle
    # through Baker Street, Great Portland Street, and Euston Square. Force
    # both sides of the Baker Street roundel onto that baseline; the eastbound
    # turn begins only after Euston Square.
    baker_metropolitan_segment = selected_segments[
        "metropolitan:940GZZLUBST:940GZZLUGPS"
    ]
    baker_metropolitan_inbound_segment = selected_segments[
        "metropolitan:940GZZLUBST:940GZZLUFYR"
    ]
    great_portland_euston_square_segment = selected_segments[
        "metropolitan:940GZZLUESQ:940GZZLUGPS"
    ]
    if baker_metropolitan_segment["pathDirection"] != "forward":
        raise ValueError("Baker Street to Great Portland Street must be forward")
    if baker_metropolitan_inbound_segment["pathDirection"] != "forward":
        raise ValueError("Finchley Road to Baker Street must be forward")
    if great_portland_euston_square_segment["pathDirection"] != "forward":
        raise ValueError("Great Portland Street to Euston Square must be forward")

    baker_metropolitan_port = line_port(
        selected_segments, "940GZZLUBST", "metropolitan"
    )
    great_portland_metropolitan_port = line_port(
        selected_segments, "940GZZLUGPS", "metropolitan"
    )
    euston_square_metropolitan_port = line_port(
        selected_segments, "940GZZLUESQ", "metropolitan"
    )
    metropolitan_baseline_y = great_portland_metropolitan_port[1]
    set_line_port(
        "940GZZLUBST",
        "metropolitan",
        (baker_metropolitan_port[0], metropolitan_baseline_y),
    )
    set_line_port(
        "940GZZLUGPS",
        "metropolitan",
        (great_portland_metropolitan_port[0], metropolitan_baseline_y),
    )
    set_line_port(
        "940GZZLUESQ",
        "metropolitan",
        (euston_square_metropolitan_port[0], metropolitan_baseline_y),
    )
    baker_metropolitan_port = line_port(
        selected_segments, "940GZZLUBST", "metropolitan"
    )
    great_portland_metropolitan_port = line_port(
        selected_segments, "940GZZLUGPS", "metropolitan"
    )
    euston_square_metropolitan_port = line_port(
        selected_segments, "940GZZLUESQ", "metropolitan"
    )

    baker_metropolitan_path = selected_paths[
        baker_metropolitan_segment["pathID"]
    ]
    baker_metropolitan_path["commands"] = [
        {"op": "move", "to": vector.rounded(baker_metropolitan_port)},
        {"op": "line", "to": vector.rounded(great_portland_metropolitan_port)},
    ]

    great_portland_euston_square_path = selected_paths[
        great_portland_euston_square_segment["pathID"]
    ]
    great_portland_euston_square_path["commands"] = [
        {"op": "move", "to": vector.rounded(great_portland_metropolitan_port)},
        {"op": "line", "to": vector.rounded(euston_square_metropolitan_port)},
    ]

    baker_metropolitan_inbound_path = selected_paths[
        baker_metropolitan_inbound_segment["pathID"]
    ]
    baker_metropolitan_inbound_path["commands"] = (
        copy.deepcopy(baker_metropolitan_inbound_path["commands"][:-2])
        + [
            {
                "op": "line",
                "to": vector.rounded(
                    (
                        baker_metropolitan_port[0] - 32,
                        metropolitan_baseline_y,
                    )
                ),
            },
            {"op": "line", "to": vector.rounded(baker_metropolitan_port)},
        ]
    )

    # The source slices place Ruislip Gardens directly on the nearby
    # Piccadilly / Metropolitan corridor. The official diagram keeps this
    # Central-line stop visibly south of that plain crossing. Move the real
    # segment split (not merely its label) to prevent a false interchange.
    ruislip_gardens_port = line_port(
        selected_segments, "940GZZLURSG", "central"
    )
    move_line_port(
        "940GZZLURSG",
        "central",
        (ruislip_gardens_port[0], ruislip_gardens_port[1] + 24),
    )

    # The official eastern layout carries the Jubilee line to the left of the
    # District / H&C corridor at West Ham, with its interchange node above the
    # east-west lines. Move the addressable Canning Town–West Ham–Stratford
    # section as one authored vertical and retain a smooth tangent approach
    # from North Greenwich.
    for station_id in ("940GZZLUCGT", "940GZZLUWHM", "940GZZLUSTD"):
        current = line_port(selected_segments, station_id, "jubilee")
        move_line_port(
            station_id,
            "jubilee",
            (
                current[0] - 24,
                current[1] - (24 if station_id == "940GZZLUWHM" else 0),
            ),
        )

    canning_town = line_port(selected_segments, "940GZZLUCGT", "jubilee")
    west_ham = line_port(selected_segments, "940GZZLUWHM", "jubilee")
    stratford = line_port(selected_segments, "940GZZLUSTD", "jubilee")

    # The official diagram carries Canary Wharf and North Greenwich farther
    # west, leaving room for a broad, continuous sweep into Canning Town.
    # Coalesce every adjoining segment onto one exact station port: the source
    # slices previously disagreed about North Greenwich by nearly 20 units.
    canary_wharf = line_port(selected_segments, "940GZZLUCYF", "jubilee")
    north_greenwich_approach = selected_segments[
        "jubilee:940GZZLUCGT:940GZZLUNGW"
    ]
    approach_path = selected_paths[north_greenwich_approach["pathID"]]
    original_north_greenwich = approach_path["commands"][0]["to"]
    canary_wharf = (canary_wharf[0] - 24, canary_wharf[1])
    north_greenwich = (
        original_north_greenwich["x"] - 24,
        original_north_greenwich["y"],
    )

    for station_id, target in (
        ("940GZZLUCYF", canary_wharf),
        ("940GZZLUNGW", north_greenwich),
    ):
        for segment in selected_segments.values():
            if segment["lineID"] != "jubilee":
                continue
            if station_id == segment["fromStationID"]:
                endpoint = segment["fromPort"]
            elif station_id == segment["toStationID"]:
                endpoint = segment["toPort"]
            else:
                continue
            translate_station_endpoint(
                segment,
                selected_paths[segment["pathID"]],
                station_id,
                target[0] - endpoint["x"],
                target[1] - endpoint["y"],
            )

    canada_water_to_canary = selected_segments[
        "jubilee:940GZZLUCWR:940GZZLUCYF"
    ]
    canada_path = selected_paths[canada_water_to_canary["pathID"]]
    canada_start = (
        canada_water_to_canary["fromPort"]["x"],
        canada_water_to_canary["fromPort"]["y"],
    )
    canada_path["commands"] = [
        {"op": "move", "to": vector.rounded(canada_start)},
        {"op": "line", "to": vector.rounded((2807.171, 1917.468))},
        {"op": "line", "to": vector.rounded((2937.671, 1917.468))},
        {
            "op": "cubic",
            "control1": vector.rounded((2948.046, 1917.468)),
            "control2": vector.rounded((2955.92, 1928.085)),
            "to": vector.rounded(canary_wharf),
        },
    ]

    canary_to_north = selected_segments[
        "jubilee:940GZZLUCYF:940GZZLUNGW"
    ]
    selected_paths[canary_to_north["pathID"]]["commands"] = [
        {"op": "move", "to": vector.rounded(canary_wharf)},
        {
            "op": "cubic",
            "control1": vector.rounded((canary_wharf[0] + 12, canary_wharf[1] + 12)),
            "control2": vector.rounded((canary_wharf[0] + 28, north_greenwich[1])),
            "to": vector.rounded((canary_wharf[0] + 60, north_greenwich[1])),
        },
        {"op": "line", "to": vector.rounded(north_greenwich)},
    ]

    # Keep this link explicitly octilinear, as in the TfL artwork: a short
    # horizontal run from North Greenwich, one 45-degree diagonal, then a
    # vertical approach into Canning Town.  The authored intermediate points
    # replace the previous Bézier while leaving both semantic station ports
    # untouched.
    diagonal_run = 64
    approach_path["commands"] = [
        {
            "op": "move",
            "to": vector.rounded(north_greenwich),
        },
        {
            "op": "line",
            "to": vector.rounded(
                (canning_town[0] - diagonal_run, north_greenwich[1])
            ),
        },
        {
            "op": "line",
            "to": vector.rounded(
                (canning_town[0], north_greenwich[1] - diagonal_run)
            ),
        },
        {
            "op": "line",
            "to": vector.rounded(canning_town),
        },
    ]

    for segment_id, start, end in (
        ("jubilee:940GZZLUCGT:940GZZLUWHM", canning_town, west_ham),
        ("jubilee:940GZZLUSTD:940GZZLUWHM", west_ham, stratford),
    ):
        segment = selected_segments[segment_id]
        if segment["pathDirection"] != "forward":
            raise ValueError(f"Unexpected Jubilee eastern path direction for {segment_id}")
        selected_paths[segment["pathID"]]["commands"] = [
            {"op": "move", "to": vector.rounded(start)},
            {"op": "line", "to": vector.rounded(end)},
        ]

    # Reconcile the longitudinal station positions inherited from the two
    # source slices. On horizontal portions, both ports share one x position.
    # On the Rayners Lane diagonal, the same midpoint is split by a 9.1-unit
    # normal so the two lines remain visibly distinct but read as one corridor.
    for station_id in (
        "940GZZLUUXB",
        "940GZZLUHGD",
        "940GZZLUICK",
        "940GZZLURSP",
        "940GZZLURSM",
    ):
        metropolitan_port = line_port(selected_segments, station_id, "metropolitan")
        piccadilly_port = line_port(selected_segments, station_id, "piccadilly")
        shared_x = (metropolitan_port[0] + piccadilly_port[0]) / 2
        move_line_port(
            station_id,
            "metropolitan",
            (shared_x, metropolitan_port[1]),
        )
        move_line_port(
            station_id,
            "piccadilly",
            (shared_x, piccadilly_port[1]),
        )

    diagonal_half_offset = 9.1 / (2 * math.sqrt(2))
    for station_id in ("940GZZLUEAE", "940GZZLURYL"):
        metropolitan_port = line_port(selected_segments, station_id, "metropolitan")
        piccadilly_port = line_port(selected_segments, station_id, "piccadilly")
        midpoint = average_point([metropolitan_port, piccadilly_port])
        move_line_port(
            station_id,
            "metropolitan",
            (
                midpoint[0] + diagonal_half_offset,
                midpoint[1] - diagonal_half_offset,
            ),
        )
        move_line_port(
            station_id,
            "piccadilly",
            (
                midpoint[0] - diagonal_half_offset,
                midpoint[1] + diagonal_half_offset,
            ),
        )

    # Re-author the shared bend after the station ports have been reconciled.
    # Retaining intermediate commands from either source slice would make the
    # paths visit the old Eastcote position and double back before Rayners
    # Lane. Each lane now follows one monotonic horizontal-to-diagonal curve,
    # followed by a straight parallel run into Rayners Lane.
    for line_id in ("metropolitan", "piccadilly"):
        approach = selected_segments[
            f"{line_id}:940GZZLUEAE:940GZZLURSM"
        ]
        departure = selected_segments[
            f"{line_id}:940GZZLUEAE:940GZZLURYL"
        ]
        if approach["pathDirection"] != "forward" or departure["pathDirection"] != "forward":
            raise ValueError(f"Unexpected Uxbridge bend direction for {line_id}")

        start = (approach["fromPort"]["x"], approach["fromPort"]["y"])
        eastcote = (approach["toPort"]["x"], approach["toPort"]["y"])
        rayners_lane = (departure["toPort"]["x"], departure["toPort"]["y"])
        outbound = (
            rayners_lane[0] - eastcote[0],
            rayners_lane[1] - eastcote[1],
        )
        outbound_length = math.hypot(*outbound)
        outbound_unit = (
            outbound[0] / outbound_length,
            outbound[1] / outbound_length,
        )
        bend_start = (eastcote[0] - 22, start[1])
        selected_paths[approach["pathID"]]["commands"] = [
            {"op": "move", "to": vector.rounded(start)},
            {"op": "line", "to": vector.rounded(bend_start)},
            {
                "op": "cubic",
                "control1": vector.rounded((bend_start[0] + 8, bend_start[1])),
                "control2": vector.rounded((
                    eastcote[0] - outbound_unit[0] * 10,
                    eastcote[1] - outbound_unit[1] * 10,
                )),
                "to": vector.rounded(eastcote),
            },
        ]
        selected_paths[departure["pathID"]]["commands"] = [
            {"op": "move", "to": vector.rounded(eastcote)},
            {"op": "line", "to": vector.rounded(rayners_lane)},
        ]

    # The Edgware Road (Circle Line) station template is displayed farther
    # east than the source slice to reproduce the official Paddington spacing.
    # Its District and Circle runs terminate here, so unlike the through-lines
    # they must be explicitly extended to the relocated lower roundel.
    for segment_id in (
        "circle:940GZZLUERC:940GZZLUPAC",
        "district:940GZZLUERC:940GZZLUPAC",
    ):
        segment = selected_segments[segment_id]
        if segment["pathDirection"] != "forward":
            raise ValueError(f"Unexpected Edgware Road path direction for {segment_id}")
        endpoint = segment["toPort"]
        extended_endpoint = {
            "x": round(endpoint["x"] + 32, 3),
            "y": endpoint["y"],
        }
        path = selected_paths[segment["pathID"]]
        final_command = path["commands"][-1]
        if final_command["op"] != "line" or final_command["to"] != endpoint:
            raise ValueError(f"Unexpected Edgware Road terminal geometry for {segment_id}")
        final_command["to"] = extended_endpoint
        segment["toPort"] = extended_endpoint

    markers: list[dict] = []
    labels: list[dict] = []
    for station_id, station in stations_by_id.items():
        if not any(line_id in UNDERGROUND_LINE_IDS for line_id in station["lineIDs"]):
            continue
        candidates = marker_candidates.get(station_id, [])
        if candidates:
            _, marker = max(
                candidates,
                key=lambda item: (len(item[1]["lineIDs"]), len(item[1]["primitives"]), -item[0]),
            )
            marker = copy.deepcopy(marker)
        else:
            marker = None

        line_matches = seam_matches.get(station["name"], [])
        seam_points = vector.unique_points((match.point for _, _, match in line_matches), tolerance=5)
        line_ids = list(station["lineIDs"])

        # TfL groups these shared-service corridors into one or two physical
        # nodes instead of drawing a ring for every line-specific port.
        if station["name"] == "Aldgate":
            circle_port = line_port(selected_segments, station_id, "circle")
            metropolitan_port = line_port(
                selected_segments, station_id, "metropolitan"
            )
            anchor = average_point([circle_port, metropolitan_port])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [
                    tick_at("circle", circle_port, (0, 1)),
                    tick_at("metropolitan", metropolitan_port, (0, 1)),
                ],
            }
        elif station["name"] == "Bond Street":
            central_port = line_port(selected_segments, station_id, "central")
            jubilee_port = line_port(selected_segments, station_id, "jubilee")
            anchor = average_point([central_port, jubilee_port])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [
                    connector(central_port, jubilee_port),
                    circle(central_port),
                    circle(jubilee_port),
                ],
            }
        elif station["name"] == "Marble Arch":
            central_port = line_port(selected_segments, station_id, "central")
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(central_port),
                "hitRadius": 24,
                "primitives": [tick_at("central", central_port, (1, 0))],
            }
        elif station["name"] == "Baker Street":
            lower_port = average_point(
                station_ports(selected_segments, station_id, "bakerloo")
            )
            shared_port = average_point([
                line_port(selected_segments, station_id, line_id)
                for line_id in ("circle", "hammersmith-city", "metropolitan")
            ])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(lower_port),
                "hitRadius": 24,
                "primitives": [
                    connector(lower_port, shared_port),
                    circle(lower_port),
                    circle(shared_port),
                ],
            }
        elif station["name"] == "Great Portland Street":
            anchor = average_point([match.point for _, _, match in line_matches])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [
                    tick_primitive(line_id, match)
                    for _, line_id, match in line_matches
                ],
            }
        elif station["name"] == "Euston Square":
            anchor = average_point([match.point for _, _, match in line_matches])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [circle(anchor)],
            }
        elif station["name"] == "King's Cross St. Pancras":
            deep_line_ports: list[vector.Point] = []
            for line_id in ("northern", "piccadilly", "victoria"):
                deep_line_ports.extend(station_ports(selected_segments, station_id, line_id))
            deep_line_port = average_point(vector.unique_points(deep_line_ports, tolerance=3))
            shared_port = average_point([match.point for _, _, match in line_matches])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(deep_line_port),
                "hitRadius": 24,
                "primitives": [
                    connector(deep_line_port, shared_port),
                    circle(deep_line_port),
                    circle(shared_port),
                ],
            }
        elif station["name"] == "Edgware Road (Circle Line)":
            circle_ports = sorted(
                station_ports(selected_segments, station_id, "circle"),
                key=lambda port: port[1],
            )
            upper_port = average_point([
                station_ports(selected_segments, station_id, "hammersmith-city")[0],
                circle_ports[0],
            ])
            lower_port = average_point([
                station_ports(selected_segments, station_id, "district")[0],
                circle_ports[-1],
            ])
            # The source station split is compressed against Paddington. The
            # upper through-lines can move along their continuing straight
            # corridor. The terminating lower paths were extended above, so
            # their computed port already is the relocated roundel centre.
            upper_port = (upper_port[0] + 32, upper_port[1])
            # The two route corridors differ by a tiny source-trace offset.
            # Use one display x-coordinate so the stacked roundels read as a
            # precise vertical interchange rather than a slightly bent one.
            roundel_x = lower_port[0]
            upper_port = (roundel_x, upper_port[1])
            lower_port = (roundel_x, lower_port[1])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(upper_port),
                "hitRadius": 24,
                "primitives": [
                    connector(upper_port, lower_port),
                    circle(upper_port),
                    circle(lower_port),
                ],
            }
        elif station["name"] == "Kennington":
            # Keep the northern roundel at the Charing Cross / Battersea node,
            # then align the two-node interchange at 45 degrees with the
            # Victoria line immediately below it.
            upper_port = (marker["anchor"]["x"], marker["anchor"]["y"])
            roundel_spacing = 24.3
            lower_port = (
                upper_port[0] + roundel_spacing,
                upper_port[1] + roundel_spacing,
            )
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(upper_port),
                "hitRadius": 24,
                "primitives": [
                    connector(upper_port, lower_port),
                    circle(upper_port),
                    circle(lower_port),
                ],
            }
        elif station["name"] in {"Paddington", "Paddington (H&C Line)-Underground"}:
            main_id = stations_by_name["Paddington"]["id"]
            hammersmith_id = stations_by_name["Paddington (H&C Line)-Underground"]["id"]
            main_shared_port = average_point([
                line_port(selected_segments, main_id, "circle"),
                line_port(selected_segments, main_id, "district"),
            ])
            hammersmith_endpoint = average_point([
                line_port(selected_segments, hammersmith_id, "circle"),
                line_port(selected_segments, hammersmith_id, "hammersmith-city"),
            ])
            # The H&C/Circle paths are horizontal immediately west of their
            # semantic endpoint. Display their shared roundel on that real
            # corridor, separating the three-node chain as on the official
            # map without inventing an off-line averaged point.
            hammersmith_shared_port = (
                hammersmith_endpoint[0] - 45,
                hammersmith_endpoint[1],
            )
            if station["name"] == "Paddington":
                bakerloo_port = line_port(selected_segments, main_id, "bakerloo")
                marker = {
                    "stationID": station_id,
                    "name": station["name"],
                    "lineIDs": line_ids,
                    "anchor": vector.rounded(bakerloo_port),
                    "hitRadius": 24,
                    # The companion marker supplies the middle H&C/Circle
                    # roundel. This marker owns the Bakerloo and Circle/District
                    # roundels plus the two continuous internal links.
                    "primitives": [
                        connector(bakerloo_port, hammersmith_shared_port),
                        connector(hammersmith_shared_port, main_shared_port),
                        circle(bakerloo_port),
                        circle(main_shared_port),
                    ],
                }
            else:
                marker = {
                    "stationID": station_id,
                    "name": station["name"],
                    "lineIDs": line_ids,
                    "anchor": vector.rounded(hammersmith_shared_port),
                    "hitRadius": 24,
                    "primitives": [circle(hammersmith_shared_port)],
                }
        elif station["name"] == "Royal Oak":
            # Place the two ticks on the exact outward diagonal portions of
            # their authored paths, before those paths straighten into
            # Paddington. This preserves topology while giving Royal Oak the
            # same visual breathing room used by the official map.
            circle_port = (1382.062, 1394.063)
            hammersmith_port = (1376.281, 1388.203)
            anchor = average_point([circle_port, hammersmith_port])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [
                    tick_at("circle", circle_port, (1, -1)),
                    tick_at("hammersmith-city", hammersmith_port, (1, -1)),
                ],
            }
        elif station["name"] == "Woodford":
            # Woodford is a through station. The Hainault branch diverges just
            # north of it and must not turn the station into an interchange.
            through_port = max(
                station_ports(selected_segments, station_id, "central"),
                key=lambda port: port[1],
            )
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(through_port),
                "hitRadius": 24,
                "primitives": [tick_at("central", through_port, (0, 1))],
            }
        elif station["name"] == "Barking":
            # District and H&C are compact parallel lanes through one physical
            # station. One centred roundel spans both; no connector is needed.
            shared_port = average_point([
                line_port(selected_segments, station_id, "district"),
                line_port(selected_segments, station_id, "hammersmith-city"),
            ])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(shared_port),
                "hitRadius": 24,
                "primitives": [circle(shared_port)],
            }
        elif station["name"] == "Canary Wharf":
            jubilee_port = line_port(selected_segments, station_id, "jubilee")
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(jubilee_port),
                "hitRadius": 24,
                "primitives": [circle(jubilee_port)],
            }
        elif station["name"] == "North Greenwich":
            jubilee_port = line_port(selected_segments, station_id, "jubilee")
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(jubilee_port),
                "hitRadius": 24,
                "primitives": [tick_at("jubilee", jubilee_port, (1, 0))],
            }
        elif station["name"] == "Canning Town":
            jubilee_port = line_port(selected_segments, station_id, "jubilee")
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(jubilee_port),
                "hitRadius": 24,
                "primitives": [circle(jubilee_port)],
            }
        elif station["name"] == "West Ham":
            jubilee_port = line_port(selected_segments, station_id, "jubilee")
            shared_port = average_point([
                line_port(selected_segments, station_id, "district"),
                line_port(selected_segments, station_id, "hammersmith-city"),
            ])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(jubilee_port),
                "hitRadius": 24,
                "primitives": [
                    connector(jubilee_port, shared_port),
                    circle(jubilee_port),
                    circle(shared_port),
                ],
            }
        elif station["name"] == "Stratford":
            central_port = line_port(selected_segments, station_id, "central")
            jubilee_port = line_port(selected_segments, station_id, "jubilee")
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(central_port),
                "hitRadius": 24,
                "primitives": [
                    connector(central_port, jubilee_port),
                    circle(central_port),
                    circle(jubilee_port),
                ],
            }
        elif station["name"] == "Ruislip Gardens":
            # Build this ordinary stop from the corrected Central-line port;
            # otherwise the source marker candidate remains at the old
            # Piccadilly / Metropolitan crossing after geometry relocation.
            central_port = line_port(selected_segments, station_id, "central")
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(central_port),
                "hitRadius": 24,
                "primitives": [tick_at("central", central_port, (0, 1))],
            }
        elif station["name"] == "Rayners Lane":
            metropolitan_port = line_port(
                selected_segments, station_id, "metropolitan"
            )
            piccadilly_port = line_port(selected_segments, station_id, "piccadilly")
            anchor = average_point([metropolitan_port, piccadilly_port])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                # One roundel spans the compact shared corridor; no connector
                # bar is needed because the two paths remain parallel here.
                "primitives": [circle(anchor)],
            }
        elif station["name"] in UXBRIDGE_SHARED_STATION_TANGENTS:
            tangent = UXBRIDGE_SHARED_STATION_TANGENTS[station["name"]]
            line_ports = [
                (line_id, line_port(selected_segments, station_id, line_id))
                for line_id in ("metropolitan", "piccadilly")
            ]
            anchor = average_point([port for _, port in line_ports])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [
                    tick_at(line_id, port, tangent)
                    for line_id, port in line_ports
                ],
            }
        elif station["name"] in ORDINARY_SHARED_STATION_TANGENTS:
            tangent = ORDINARY_SHARED_STATION_TANGENTS[station["name"]]
            line_ports = [
                (line_id, line_port(selected_segments, station_id, line_id))
                for line_id in line_ids
            ]
            anchor = average_point([port for _, port in line_ports])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [
                    tick_at(line_id, port, tangent)
                    for line_id, port in line_ports
                ],
            }
        elif station["name"] == "Gloucester Road":
            line_ports = [
                (line_id, line_port(selected_segments, station_id, line_id))
                for line_id in ("circle", "district")
            ]
            anchor = average_point([port for _, port in line_ports])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [
                    tick_at(line_id, port, (0, 1))
                    for line_id, port in line_ports
                ],
            }
        elif station["name"] == "South Kensington":
            shared_port = shared_line_port(
                selected_segments, station_id, ("circle", "district")
            )
            piccadilly_port = line_port(selected_segments, station_id, "piccadilly")
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(shared_port),
                "hitRadius": 24,
                "primitives": [
                    connector(piccadilly_port, shared_port),
                    circle(piccadilly_port),
                    circle(shared_port),
                ],
            }
        elif station["name"] == "Victoria":
            shared_actual = shared_line_port(
                selected_segments, station_id, ("circle", "district")
            )
            # Move left along the shared horizontal corridor, matching the
            # official diagonal two-node interchange treatment.
            shared_port = (shared_actual[0] - 20, shared_actual[1])
            victoria_actual = line_port(selected_segments, station_id, "victoria")
            victoria_port = (victoria_actual[0], victoria_actual[1] - 24)
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(shared_port),
                "hitRadius": 24,
                "primitives": [
                    connector(shared_port, victoria_port),
                    circle(shared_port),
                    circle(victoria_port),
                ],
            }
        elif station["name"] == "Embankment":
            shared_port = average_point([
                line_port(selected_segments, station_id, "bakerloo"),
                line_port(selected_segments, station_id, "circle"),
                line_port(selected_segments, station_id, "district"),
            ])
            northern_actual = line_port(selected_segments, station_id, "northern")
            northern_port = (northern_actual[0], northern_actual[1] - 24)
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(shared_port),
                "hitRadius": 24,
                "primitives": [
                    connector(northern_port, shared_port),
                    circle(northern_port),
                    circle(shared_port),
                ],
            }
        elif station["name"] == "Moorgate":
            shared_actual = shared_line_port(
                selected_segments,
                station_id,
                ("circle", "hammersmith-city", "metropolitan"),
            )
            shared_port = (shared_actual[0] - 24, shared_actual[1])
            northern_actual = line_port(selected_segments, station_id, "northern")
            # Keep the Northern node on its vertical route, but lift it above
            # the surface corridor as on the official interchange treatment.
            northern_port = (northern_actual[0], shared_actual[1] - 28)
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(shared_port),
                "hitRadius": 24,
                "primitives": [
                    connector(shared_port, northern_port),
                    circle(shared_port),
                    circle(northern_port),
                ],
            }
        elif station["name"] == "Finsbury Park":
            piccadilly_port = line_port(
                selected_segments, station_id, "piccadilly"
            )
            victoria_port = line_port(selected_segments, station_id, "victoria")
            anchor = average_point([piccadilly_port, victoria_port])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [
                    connector(piccadilly_port, victoria_port),
                    circle(piccadilly_port),
                    circle(victoria_port),
                ],
            }
        elif station["name"] == "Bank":
            central_port = line_port(selected_segments, station_id, "central")
            northern_port = line_port(selected_segments, station_id, "northern")
            waterloo_port = line_port(selected_segments, station_id, "waterloo-city")
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(central_port),
                "hitRadius": 24,
                "primitives": [
                    connector(central_port, northern_port),
                    connector(central_port, waterloo_port),
                    circle(central_port),
                    circle(northern_port),
                    circle(waterloo_port),
                ],
            }
        elif station_id in HEATHROW_VISIBLE_ROUTE:
            visible_route = HEATHROW_VISIBLE_ROUTE[station_id]
            visible_match = next(
                match for route_id, _, match in line_matches if route_id == visible_route
            )
            anchor = visible_match.point
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": [circle(anchor)],
            }
        elif station["name"] == "Liverpool Street":
            central_ports: list[vector.Point] = []
            for segment in selected_segments.values():
                if segment["lineID"] != "central":
                    continue
                if segment["fromStationID"] == station_id and segment.get("fromPort"):
                    port = segment["fromPort"]
                    central_ports.append((port["x"], port["y"]))
                if segment["toStationID"] == station_id and segment.get("toPort"):
                    port = segment["toPort"]
                    central_ports.append((port["x"], port["y"]))
            central_port = vector.unique_points(central_ports, tolerance=5)[0]
            shared_matches = [
                match for _, line_id, match in line_matches
                if line_id in {"circle", "hammersmith-city", "metropolitan"}
            ]
            shared_port = tuple(
                sum(match.point[index] for match in shared_matches) / len(shared_matches)
                for index in (0, 1)
            )
            elbow = (shared_port[0], central_port[1])
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(central_port),
                "hitRadius": 24,
                "primitives": [
                    connector(central_port, elbow),
                    connector(elbow, shared_port),
                    circle(central_port),
                    circle(shared_port),
                ],
            }
        elif marker is None:
            if not line_matches:
                raise ValueError(f"Station {station['name']} has no marker candidate or seam port")
            anchor = seam_points[0]
            interchange = station["interchange"] or len({line for _, line, _ in line_matches}) > 1 or len(seam_points) > 1
            primitives: list[dict]
            if interchange:
                primitives = []
                for port in seam_points[1:]:
                    if math.dist(anchor, port) > 12:
                        primitives.append(connector(anchor, port))
                primitives.extend(circle(port) for port in seam_points)
            else:
                primitives = [tick_primitive(line_matches[0][1], line_matches[0][2])]
            marker = {
                "stationID": station_id,
                "name": station["name"],
                "lineIDs": line_ids,
                "anchor": vector.rounded(anchor),
                "hitRadius": 24,
                "primitives": primitives,
            }
        else:
            marker["lineIDs"] = line_ids
            existing_points = primitive_points(marker)
            anchor = (marker["anchor"]["x"], marker["anchor"]["y"])
            for _, line_id, match in line_matches:
                port = match.point
                if any(math.dist(port, existing) <= 7 for existing in existing_points):
                    continue
                if math.dist(anchor, port) > 12:
                    marker["primitives"].append(connector(anchor, port))
                marker["primitives"].append(circle(port))
                existing_points.append(port)

        markers.append(marker)

        candidates_for_label = label_candidates.get(station_id, [])
        if candidates_for_label:
            _, label = max(candidates_for_label, key=lambda item: (-item[0], item[1]["priority"]))
            label = copy.deepcopy(label)
        else:
            dx, dy, alignment = LABEL_OFFSETS.get(station["name"], (18, 12, "leading"))
            anchor = marker["anchor"]
            label = {
                "id": f"label.{station_id}",
                "stationID": station_id,
                "text": station["name"],
                "position": vector.rounded((anchor["x"] + dx, anchor["y"] + dy)),
                "alignment": alignment,
                "rotationDegrees": 0,
                "priority": 10 if station["interchange"] else 5,
            }
        if station["name"] in HEATHROW_LABEL_TEXT:
            label["text"] = HEATHROW_LABEL_TEXT[station["name"]]
        if station["name"] in LABEL_TEXT_OVERRIDES:
            label["text"] = LABEL_TEXT_OVERRIDES[station["name"]]
        if station["name"] == "Paddington (H&C Line)-Underground":
            label["text"] = "Paddington"
        if station["name"] in LABEL_OVERRIDES:
            dx, dy, alignment = LABEL_OVERRIDES[station["name"]]
            anchor = marker["anchor"]
            label["position"] = vector.rounded((anchor["x"] + dx, anchor["y"] + dy))
            label["alignment"] = alignment
        labels.append(label)

    # Every marker must declare the complete semantic line membership. The
    # renderer still uses its explicit primitives, so this does not invent art.
    for marker in markers:
        marker["lineIDs"] = list(stations_by_id[marker["stationID"]]["lineIDs"])

    rail.append_rail_artwork(
        root, graph, selected_paths, selected_segments, markers, labels, routes
    )
    overground.append_overground_artwork(
        root, graph, selected_paths, selected_segments, markers, labels, routes
    )

    markers_by_id = {marker["stationID"]: marker for marker in markers}
    labels_by_station_id = {label["stationID"]: label for label in labels}

    def replace_marker(
        station_id: str,
        anchor: vector.Point,
        primitives: list[dict],
    ) -> None:
        marker = markers_by_id[station_id]
        marker["anchor"] = vector.rounded(anchor)
        marker["primitives"] = primitives

    def place_label(
        station_id: str,
        anchor: vector.Point,
        offset: vector.Point,
        alignment: str,
    ) -> None:
        label = labels_by_station_id.get(station_id)
        if label is None:
            return
        label["position"] = vector.rounded(
            (anchor[0] + offset[0], anchor[1] + offset[1])
        )
        label["alignment"] = alignment

    def replace_segment_commands(
        segment_id: str,
        commands: list[dict],
    ) -> None:
        """Replace one station-to-station slice without moving stale controls."""
        segment = selected_segments[segment_id]
        selected_paths[segment["pathID"]]["commands"] = commands

    # ------------------------------------------------------------------
    # Compact Overground / Underground interchanges
    # ------------------------------------------------------------------

    # Barking's Suffragette platform sits just above the District/H&C node on
    # the official artwork. Lift the authored endpoint slightly so the short
    # connector clears both route strokes rather than grazing the roundel.
    barking_underground = line_port(selected_segments, "940GZZLUBKG", "district")
    barking_overground = line_port(selected_segments, "910GBARKING", "suffragette")
    barking_overground = (barking_overground[0], barking_overground[1] - 8)
    move_line_port("910GBARKING", "suffragette", barking_overground)
    replace_marker(
        "910GBARKING",
        barking_overground,
        [connector(barking_underground, barking_overground), circle(barking_overground)],
    )

    # The two Weaver source fragments overlap at Cambridge Heath/London
    # Fields. Retaining both sides of that overlap makes the line overshoot to
    # the east and double back before turning north. Author the same official
    # rounded corner as one monotone station-to-station slice.
    replace_segment_commands(
        "weaver:910GCAMHTH:910GLONFLDS",
        [
            {"op": "move", "to": vector.rounded((2789.872, 1379.344))},
            {"op": "line", "to": vector.rounded((2805.114, 1379.344))},
            {
                "op": "cubic",
                "control1": vector.rounded((2819.473, 1379.344)),
                "control2": vector.rounded((2831.114, 1367.703)),
                "to": vector.rounded((2831.114, 1353.344)),
            },
            {"op": "line", "to": vector.rounded((2831.114, 1297.101))},
        ],
    )

    # Hackney Downs is the shared Weaver branch node. The Chingford fragment
    # used to begin east and *below* that node, producing a tiny hook before
    # turning back towards Clapton. Join the shared port with a single smooth,
    # northeast-only contour.
    replace_segment_commands(
        "weaver:910GCLAPTON:910GHAKNYNM",
        [
            {"op": "move", "to": vector.rounded((2831.172, 1175.422))},
            {"op": "line", "to": vector.rounded((2840.500, 1175.422))},
            {
                "op": "cubic",
                "control1": vector.rounded((2848.500, 1175.422)),
                "control2": vector.rounded((2856.200, 1172.200)),
                "to": vector.rounded((2862.000, 1166.400)),
            },
            {"op": "line", "to": vector.rounded((2889.311, 1137.033))},
        ],
    )

    # Seven Sisters uses two distinct nodes on the official map. Keep the
    # Weaver station on its vertical route and put the Victoria roundel just
    # to the right, joined by a short diagonal link.
    seven_weaver = line_port(selected_segments, "910GSEVNSIS", "weaver")
    victoria_north_y = line_port(
        selected_segments, "940GZZLUSVS", "victoria"
    )[1]
    seven_victoria = (seven_weaver[0] + 26, victoria_north_y)
    move_line_port("940GZZLUSVS", "victoria", seven_victoria)
    replace_marker("940GZZLUSVS", seven_victoria, [circle(seven_victoria)])
    replace_marker(
        "910GSEVNSIS",
        seven_weaver,
        [connector(seven_victoria, seven_weaver), circle(seven_weaver)],
    )
    place_label("940GZZLUSVS", seven_victoria, (-20, -18), "trailing")

    # Re-space the remaining northeast Victoria stops in their geographic
    # order, then replace every affected slice. Endpoint-only movement leaves
    # the old Seven Sisters point inside the first path and creates the large
    # backtrack visible in the app.
    tottenham_victoria = (2806.000, victoria_north_y)
    blackhorse_victoria = (2868.000, victoria_north_y)
    walthamstow_victoria = line_port(
        selected_segments, "940GZZLUWWL", "victoria"
    )
    move_line_port("940GZZLUTMH", "victoria", tottenham_victoria)
    move_line_port("940GZZLUBLR", "victoria", blackhorse_victoria)

    for segment_id in (
        "victoria:940GZZLUSVS:940GZZLUTMH",
        "victoria:940GZZLUBLR:940GZZLUTMH",
        "victoria:940GZZLUBLR:940GZZLUWWL",
    ):
        segment = selected_segments[segment_id]
        start = (segment["fromPort"]["x"], segment["fromPort"]["y"])
        end = (segment["toPort"]["x"], segment["toPort"]["y"])
        replace_segment_commands(
            segment_id,
            [
                {"op": "move", "to": vector.rounded(start)},
                {"op": "line", "to": vector.rounded(end)},
            ],
        )

    replace_marker(
        "940GZZLUTMH",
        tottenham_victoria,
        [tick_at("victoria", tottenham_victoria, (1, 0))],
    )
    place_label("940GZZLUTMH", tottenham_victoria, (0, -20), "centre")

    blackhorse_overground = line_port(
        selected_segments, "910GBLCHSRD", "suffragette"
    )
    replace_marker(
        "940GZZLUBLR",
        blackhorse_victoria,
        [circle(blackhorse_victoria)],
    )
    replace_marker(
        "910GBLCHSRD",
        blackhorse_overground,
        [
            connector(blackhorse_victoria, blackhorse_overground),
            circle(blackhorse_overground),
        ],
    )
    place_label("940GZZLUBLR", blackhorse_victoria, (-18, 34), "trailing")

    walthamstow_overground = line_port(
        selected_segments, "910GWLTWCEN", "weaver"
    )
    replace_marker(
        "940GZZLUWWL",
        walthamstow_victoria,
        [circle(walthamstow_victoria)],
    )
    replace_marker(
        "910GWLTWCEN",
        walthamstow_overground,
        [
            connector(walthamstow_victoria, walthamstow_overground),
            circle(walthamstow_overground),
        ],
    )
    place_label("940GZZLUWWL", walthamstow_victoria, (18, 8), "leading")

    # Highbury's Victoria line is vertical in the official artwork. Pulling
    # its station east onto the imported Overground port created two opposing
    # diagonals beneath Finsbury Park. Restore the Victoria x-axis and move the
    # two straight Overground endpoints west to their compact reference stack.
    highbury_mildmay = (2424.000, 1174.976)
    highbury_windrush = (2424.000, 1205.469)
    move_line_port("910GHGHI", "mildmay", highbury_mildmay)
    move_line_port("910GHGHI", "windrush", highbury_windrush)
    highbury_victoria = (2406.132, 1156.976)
    move_line_port("940GZZLUHAI", "victoria", highbury_victoria)
    replace_marker("940GZZLUHAI", highbury_victoria, [circle(highbury_victoria)])
    replace_marker(
        "910GHGHI",
        highbury_mildmay,
        [
            connector(highbury_victoria, highbury_mildmay),
            connector(highbury_mildmay, highbury_windrush),
            circle(highbury_mildmay),
            circle(highbury_windrush),
        ],
    )
    place_label("940GZZLUHAI", highbury_victoria, (-18, -14), "trailing")

    # Caledonian Road must remain between King's Cross and Holloway Road on the
    # Piccadilly line's x+y=3437.578 diagonal. The former target sat beyond
    # Holloway Road and forced both adjacent segments into a triangular
    # reversal. Move it northeast only as far as topology permits, keeping the
    # complete station chain collinear while shortening the interchange link.
    caledonian_overground = line_port(
        selected_segments, "910GCLDNNRB", "mildmay"
    )
    caledonian_piccadilly = (2234.781, 1202.797)
    move_line_port("940GZZLUCAR", "piccadilly", caledonian_piccadilly)
    caledonian_from_kings_cross = selected_segments[
        "piccadilly:940GZZLUCAR:940GZZLUKSX"
    ]
    kings_cross_piccadilly = (
        caledonian_from_kings_cross["fromPort"]["x"],
        caledonian_from_kings_cross["fromPort"]["y"],
    )
    replace_segment_commands(
        caledonian_from_kings_cross["id"],
        [
            {"op": "move", "to": vector.rounded(kings_cross_piccadilly)},
            {"op": "line", "to": vector.rounded((2137.593, 1311.594))},
            {
                "op": "cubic",
                "control1": vector.rounded((2137.593, 1305.203)),
                "control2": vector.rounded((2141.296, 1296.297)),
                "to": vector.rounded((2145.796, 1291.782)),
            },
            {"op": "line", "to": vector.rounded(caledonian_piccadilly)},
        ],
    )
    caledonian_to_holloway = selected_segments[
        "piccadilly:940GZZLUCAR:940GZZLUHWY"
    ]
    holloway_piccadilly = (
        caledonian_to_holloway["toPort"]["x"],
        caledonian_to_holloway["toPort"]["y"],
    )
    replace_segment_commands(
        caledonian_to_holloway["id"],
        [
            {"op": "move", "to": vector.rounded(caledonian_piccadilly)},
            {"op": "line", "to": vector.rounded(holloway_piccadilly)},
        ],
    )
    replace_marker(
        "940GZZLUCAR", caledonian_piccadilly, [circle(caledonian_piccadilly)]
    )
    replace_marker(
        "910GCLDNNRB",
        caledonian_overground,
        [
            connector(caledonian_piccadilly, caledonian_overground),
            circle(caledonian_overground),
        ],
    )
    place_label("940GZZLUCAR", caledonian_piccadilly, (-18, 12), "trailing")

    # West Hampstead's Jubilee node is a roundel just above the Mildmay line,
    # joined by the short diagonal link visible on the standard TfL map.
    west_hampstead_overground = line_port(
        selected_segments, "910GWHMDSTD", "mildmay"
    )
    old_west_hampstead_jubilee = line_port(
        selected_segments, "940GZZLUWHP", "jubilee"
    )
    west_hampstead_jubilee = (
        old_west_hampstead_jubilee[0],
        old_west_hampstead_jubilee[1] - 9,
    )
    move_line_port("940GZZLUWHP", "jubilee", west_hampstead_jubilee)
    replace_marker(
        "940GZZLUWHP", west_hampstead_jubilee, [circle(west_hampstead_jubilee)]
    )
    replace_marker(
        "910GWHMDSTD",
        west_hampstead_overground,
        [
            connector(west_hampstead_jubilee, west_hampstead_overground),
            circle(west_hampstead_overground),
        ],
    )
    place_label(
        "940GZZLUWHP", west_hampstead_jubilee, (18, -14), "leading"
    )

    # The Lioness and Bakerloo lines run as a close pair from Kensal Green to
    # Harrow & Wealdstone. Align their station rows so the interchanges use
    # short horizontal links, not the alternating diagonal ladder produced by
    # independent station interpolation.
    lioness_bakerloo_pairs = (
        ("910GKENSLG", "940GZZLUKSL"),
        ("910GWLSDJHL", "940GZZLUWJN"),
        ("910GHARLSDN", "940GZZLUHSN"),
        ("910GSTNBGPK", "940GZZLUSGP"),
        ("910GWMBY", "940GZZLUWYC"),
        ("910GNWEMBLY", "940GZZLUNWY"),
        ("910GSKENTON", "940GZZLUSKT"),
        ("910GKTON", "940GZZLUKEN"),
        ("910GHROW", "940GZZLUHAW"),
    )
    for overground_id, underground_id in lioness_bakerloo_pairs:
        bakerloo_port = line_port(selected_segments, underground_id, "bakerloo")
        lioness_port = line_port(selected_segments, overground_id, "lioness")
        aligned_lioness = (1155.547, bakerloo_port[1])
        move_line_port(overground_id, "lioness", aligned_lioness)
        replace_marker(
            overground_id,
            aligned_lioness,
            [connector(bakerloo_port, aligned_lioness), circle(aligned_lioness)],
        )

    # Kensal Green and Willesden Junction were both moved onto the parallel
    # north-south corridor, but the old source curve still swept southeast to
    # the former Kensal port before doubling back. That orphaned interior
    # geometry is the apparent "Queen's Park kink". The official corridor is
    # straight here, like every Lioness segment above it.
    kensal_willesden = selected_segments[
        "lioness:910GKENSLG:910GWLSDJHL"
    ]
    kensal_willesden_start = (
        kensal_willesden["fromPort"]["x"],
        kensal_willesden["fromPort"]["y"],
    )
    kensal_willesden_end = (
        kensal_willesden["toPort"]["x"],
        kensal_willesden["toPort"]["y"],
    )
    replace_segment_commands(
        kensal_willesden["id"],
        [
            {"op": "move", "to": vector.rounded(kensal_willesden_start)},
            {"op": "line", "to": vector.rounded(kensal_willesden_end)},
        ],
    )

    # Queen's Park is the branch elbow shared by the two services. Keep the
    # established Bakerloo bend and bring the misplaced Lioness station onto
    # it; moving Bakerloo to the old rail port would pull its two adjacent
    # authored curves into a large triangular detour.
    queens_bakerloo = line_port(selected_segments, "940GZZLUQPS", "bakerloo")
    move_line_port("910GQPRK", "lioness", queens_bakerloo)
    queens_overground = queens_bakerloo
    # The source Lioness slices still contain the former distant station point
    # as interior geometry after an endpoint translation. Replace only the two
    # adjacent semantic slices with clean, gentle curves into the shared elbow
    # so no retraced loop or triangular spur survives the relocation.
    queens_inbound = selected_segments["lioness:910GKLBRNHR:910GQPRK"]
    queens_outbound = selected_segments["lioness:910GKENSLG:910GQPRK"]
    inbound_start = (
        queens_inbound["fromPort"]["x"],
        queens_inbound["fromPort"]["y"],
    )
    outbound_end = (
        queens_outbound["toPort"]["x"],
        queens_outbound["toPort"]["y"],
    )
    selected_paths[queens_inbound["pathID"]]["commands"] = [
        {"op": "move", "to": vector.rounded(inbound_start)},
        {
            "op": "cubic",
            "control1": vector.rounded(
                (inbound_start[0] - 150, inbound_start[1])
            ),
            "control2": vector.rounded(
                (queens_overground[0] + 50, queens_overground[1])
            ),
            "to": vector.rounded(queens_overground),
        },
    ]
    selected_paths[queens_outbound["pathID"]]["commands"] = [
        {"op": "move", "to": vector.rounded(queens_overground)},
        {
            "op": "cubic",
            "control1": vector.rounded(
                (queens_overground[0] - 8, queens_overground[1] - 8)
            ),
            "control2": vector.rounded(
                (outbound_end[0], outbound_end[1] + 14)
            ),
            "to": vector.rounded(outbound_end),
        },
    ]
    # Both semantic records remain independently tappable. Their circles are
    # exactly coincident, so they render as one shared roundel.
    replace_marker("940GZZLUQPS", queens_overground, [circle(queens_overground)])
    replace_marker("910GQPRK", queens_overground, [circle(queens_overground)])
    place_label("910GQPRK", queens_overground, (-18, -18), "trailing")
    place_label("940GZZLUQPS", queens_overground, (-18, 28), "trailing")

    # Willesden Junction owns a second Mildmay port west of the paired
    # Bakerloo/Lioness node. Keep that relationship explicit but compact.
    willesden_bakerloo = line_port(
        selected_segments, "940GZZLUWJN", "bakerloo"
    )
    willesden_lioness = line_port(selected_segments, "910GWLSDJHL", "lioness")
    willesden_mildmay = (willesden_lioness[0] - 42, willesden_lioness[1])
    move_line_port("910GWLSDJHL", "mildmay", willesden_mildmay)
    replace_marker(
        "910GWLSDJHL",
        willesden_lioness,
        [
            connector(willesden_bakerloo, willesden_lioness),
            connector(willesden_lioness, willesden_mildmay),
            circle(willesden_lioness),
            circle(willesden_mildmay),
        ],
    )

    # Stratford has four real service ports but Jubilee and Elizabeth resolve
    # to the same central node. Coalesce those near-overlapping circles and
    # arrange the Central, Mildmay, shared and DLR nodes as a compact cross.
    stratford_central = line_port(selected_segments, "940GZZLUSTD", "central")
    stratford_shared = line_port(selected_segments, "940GZZLUSTD", "jubilee")
    # Keep Jubilee on the established West Ham–Stratford vertical and bring
    # the Elizabeth endpoint the six artwork units onto that same roundel.
    move_line_port("910GSTFD", "elizabeth", stratford_shared)
    stratford_mildmay = line_port(selected_segments, "910GSTFD", "mildmay")
    stratford_dlr = line_port(selected_segments, "940GZZDLSTD", "dlr")
    replace_marker(
        "940GZZLUSTD",
        stratford_central,
        [
            connector(stratford_central, stratford_shared),
            circle(stratford_central),
            circle(stratford_shared),
        ],
    )
    replace_marker(
        "910GSTFD",
        stratford_shared,
        [connector(stratford_mildmay, stratford_shared), circle(stratford_mildmay)],
    )
    replace_marker(
        "940GZZDLSTD",
        stratford_dlr,
        [connector(stratford_shared, stratford_dlr), circle(stratford_dlr)],
    )

    # Canary Wharf's three services retain their distinct authored ports. Join
    # them as one legible interchange chain, then add the documented pedestrian
    # link from West India Quay to the Elizabeth line. Redrawing every endpoint
    # circle after the connectors keeps the roundel rings visually unbroken.
    canary_jubilee = line_port(selected_segments, "940GZZLUCYF", "jubilee")
    canary_dlr = line_port(selected_segments, "940GZZDLCAN", "dlr")
    canary_elizabeth = line_port(
        selected_segments, "910GCANWHRF", "elizabeth"
    )
    west_india_quay = line_port(selected_segments, "940GZZDLWIQ", "dlr")
    canary_marker = markers_by_id["940GZZLUCYF"]
    canary_marker["primitives"] = [
        connector(canary_jubilee, canary_dlr),
        connector(canary_dlr, canary_elizabeth),
        connector(west_india_quay, canary_elizabeth),
        circle(canary_jubilee),
        circle(canary_dlr),
        circle(canary_elizabeth),
        circle(west_india_quay),
    ]

    # Whitechapel's Elizabeth line has a separate physical node northeast of
    # the shared District / H&C roundel. Draw their interchange link beneath
    # both circles so the linework terminates cleanly at each roundel ring.
    whitechapel_marker = markers_by_id["940GZZLUWPL"]
    whitechapel_underground = (
        whitechapel_marker["anchor"]["x"],
        whitechapel_marker["anchor"]["y"],
    )
    whitechapel_elizabeth = line_port(
        selected_segments, "910GWCHAPXR", "elizabeth"
    )
    whitechapel_marker["primitives"].insert(
        1,
        connector(whitechapel_underground, whitechapel_elizabeth),
    )
    whitechapel_marker["primitives"].append(circle(whitechapel_elizabeth))

    # The Circle, H&C, and Metropolitan lanes through Farringdon form one
    # compact shared corridor. One centred roundel spans all three lanes and a
    # short pedestrian link joins it to the separate Elizabeth line roundel.
    farringdon_shared = shared_line_port(
        selected_segments,
        "940GZZLUFCN",
        ("circle", "hammersmith-city", "metropolitan"),
    )
    farringdon_elizabeth = line_port(
        selected_segments, "910GFRNDXR", "elizabeth"
    )
    farringdon_marker = markers_by_id["940GZZLUFCN"]
    farringdon_marker["anchor"] = vector.rounded(farringdon_shared)
    farringdon_marker["primitives"] = [
        connector(farringdon_shared, farringdon_elizabeth),
        circle(farringdon_shared),
        circle(farringdon_elizabeth),
    ]

    # Tottenham Court Road uses one shared Northern / Elizabeth node. Move the
    # Central split west along its own route and connect that distinct roundel
    # diagonally to the shared node, removing the false Central/Northern overlap.
    tottenham_elizabeth = line_port(
        selected_segments, "910GTOTCTRD", "elizabeth"
    )
    move_line_port("940GZZLUTCR", "northern", tottenham_elizabeth)
    original_tottenham_central = line_port(
        selected_segments, "940GZZLUTCR", "central"
    )
    tottenham_central = (
        original_tottenham_central[0] - 24,
        original_tottenham_central[1],
    )
    move_line_port("940GZZLUTCR", "central", tottenham_central)
    tottenham_marker = markers_by_id["940GZZLUTCR"]
    tottenham_marker["anchor"] = vector.rounded(tottenham_central)
    tottenham_marker["primitives"] = [
        connector(tottenham_central, tottenham_elizabeth),
        circle(tottenham_central),
        circle(tottenham_elizabeth),
    ]

    # Bond Street's Elizabeth node is a third physical roundel. Join it to the
    # Central node and redraw that destination circle after the connector so
    # the ring stays visually intact across marker ownership boundaries.
    bond_marker = markers_by_id["940GZZLUBND"]
    bond_central = line_port(selected_segments, "940GZZLUBND", "central")
    bond_elizabeth = line_port(selected_segments, "910GBONDST", "elizabeth")
    bond_marker["primitives"].insert(1, connector(bond_central, bond_elizabeth))
    bond_marker["primitives"].append(circle(bond_elizabeth))

    # Make the Elizabeth roundel the actual elbow at Liverpool Street so both
    # internal links terminate on it instead of stopping just below it.
    liverpool_marker = markers_by_id["940GZZLULVT"]
    liverpool_central = line_port(selected_segments, "940GZZLULVT", "central")
    liverpool_shared = shared_line_port(
        selected_segments,
        "940GZZLULVT",
        ("circle", "hammersmith-city", "metropolitan"),
    )
    liverpool_elizabeth = line_port(
        selected_segments, "910GLIVSTLL", "elizabeth"
    )
    liverpool_marker["primitives"] = [
        connector(liverpool_central, liverpool_elizabeth),
        connector(liverpool_elizabeth, liverpool_shared),
        circle(liverpool_central),
        circle(liverpool_elizabeth),
        circle(liverpool_shared),
    ]

    # Move the DLR terminus clear of the Northern line, then explicitly show
    # both parts of the Bank / Monument pedestrian interchange.
    bank_northern = line_port(selected_segments, "940GZZLUBNK", "northern")
    monument_marker = markers_by_id["940GZZLUMMT"]
    monument_roundel = primitive_points(monument_marker)[0]
    original_dlr_bank = line_port(selected_segments, "940GZZDLBNK", "dlr")
    dlr_bank = (monument_roundel[0], original_dlr_bank[1])
    move_line_port("940GZZDLBNK", "dlr", dlr_bank)
    dlr_bank_marker = markers_by_id["940GZZDLBNK"]
    dlr_bank_marker["anchor"] = vector.rounded(dlr_bank)
    dlr_bank_marker["primitives"] = [
        connector(bank_northern, dlr_bank),
        connector(dlr_bank, monument_roundel),
        circle(dlr_bank),
    ]

    # Shift East India west as one authored unit: both adjoining DLR path
    # endpoints, the roundel, and its label retain their original relationship.
    east_india_station_id = "940GZZDLEIN"
    original_east_india = line_port(
        selected_segments, east_india_station_id, "dlr"
    )
    east_india = (original_east_india[0] - 18, original_east_india[1])
    move_line_port(east_india_station_id, "dlr", east_india)
    east_india_marker = markers_by_id[east_india_station_id]
    east_india_marker["anchor"] = vector.rounded(east_india)
    east_india_marker["primitives"] = [circle(east_india)]
    east_india_label = labels_by_station_id[east_india_station_id]
    east_india_label["position"] = translated_point(
        east_india_label["position"],
        east_india[0] - original_east_india[0],
        east_india[1] - original_east_india[1],
    )

    # Canning Town has one common node where Jubilee crosses the East India
    # DLR corridor and a second node on the Star Lane branch. The official
    # branch knee is an exact point on that DLR path.
    dlr_canning = line_port(selected_segments, "940GZZDLCGT", "dlr")
    jubilee_canning = line_port(selected_segments, "940GZZLUCGT", "jubilee")
    common_canning = (jubilee_canning[0], dlr_canning[1])
    move_line_port("940GZZLUCGT", "jubilee", common_canning)
    underground_canning_marker = markers_by_id["940GZZLUCGT"]
    underground_canning_marker["anchor"] = vector.rounded(common_canning)
    underground_canning_marker["primitives"] = [circle(common_canning)]

    star_lane_branch_roundel = (3289.016, 1726.297)
    dlr_canning_marker = markers_by_id["940GZZDLCGT"]
    dlr_canning_marker["anchor"] = vector.rounded(star_lane_branch_roundel)
    dlr_canning_marker["primitives"] = [
        connector(common_canning, star_lane_branch_roundel),
        circle(star_lane_branch_roundel),
    ]

    return {
        "schemaVersion": {"major": 1, "minor": 2},
        "identifier": "tube-track-uk.beck.full-underground.v1",
        "geometryStatus": "authored",
        "source": {
            "graphSchemaVersion": graph["schemaVersion"],
            "graphGeneratedAt": graph["generatedAt"],
            "note": (
                "Complete London rail artwork compiled offline. Underground geometry uses trace-verified "
                "slices and exact master paths from the April 2026 TfL vector map, including the DLR "
                "Elizabeth line and six named London Overground routes, with distinct interchange ports. "
                "No runtime layout is used."
            ),
        },
        "artworkSize": {"width": ARTWORK_WIDTH, "height": ARTWORK_HEIGHT},
        "styles": {
            "routeStrokeWidth": 8.3,
            "affectedOuterStrokeWidth": 19,
            "affectedKnockoutStrokeWidth": 15,
            "affectedRouteStrokeWidth": 10,
            "primaryLabelFontSize": 18,
            "secondaryLabelFontSize": 16,
            "labelPadding": 2,
        },
        "debugReference": {
            "resourceName": "full-underground-reference-debug",
            "resourceExtension": "png",
            "geometryOpacity": 0.52,
        },
        "paths": sorted(selected_paths.values(), key=lambda value: value["id"]),
        "segments": sorted(selected_segments.values(), key=lambda value: value["id"]),
        "stationMarkers": sorted(markers, key=lambda value: value["stationID"]),
        "labels": sorted(labels, key=lambda value: value["id"]),
        "routes": sorted(routes.values(), key=lambda value: value["id"]),
        "supportedLineIDs": [
            "bakerloo", "central", "circle", "district", "hammersmith-city",
            "jubilee", "metropolitan", "northern", "piccadilly", "victoria",
            "waterloo-city", "dlr", "elizabeth", "liberty", "lioness",
            "mildmay", "suffragette", "weaver", "windrush",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--svg", required=True, type=Path)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--resources", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    document = build(arguments.svg, arguments.graph, arguments.resources)
    arguments.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
