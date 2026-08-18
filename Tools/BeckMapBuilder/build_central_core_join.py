#!/usr/bin/env python3
"""Build the Central Core Join from the official TfL vector artwork.

This is an offline authoring tool, not a runtime layout engine. It reads the
coloured master paths exported from the April 2026 TfL PDF, keeps their exact
line/cubic geometry, and splits them at manually identified station ports.
TubeGraph is used only for stable station and segment identifiers.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


CROP_X = 900.0
CROP_Y = 700.0
RASTER_SCALE = 4.0
ARTWORK_WIDTH = 2600.0
ARTWORK_HEIGHT = 2000.0
NUMBER = r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"
TOKENS = re.compile(rf"[A-Za-z]|{NUMBER}")


Point = tuple[float, float]


@dataclass(frozen=True)
class Curve:
    operation: str
    start: Point
    end: Point
    control1: Point | None = None
    control2: Point | None = None

    def point(self, t: float) -> Point:
        if self.operation == "line":
            return lerp(self.start, self.end, t)
        assert self.control1 is not None and self.control2 is not None
        u = 1.0 - t
        return (
            u**3 * self.start[0]
            + 3 * u * u * t * self.control1[0]
            + 3 * u * t * t * self.control2[0]
            + t**3 * self.end[0],
            u**3 * self.start[1]
            + 3 * u * u * t * self.control1[1]
            + 3 * u * t * t * self.control2[1]
            + t**3 * self.end[1],
        )

    def tangent(self, t: float) -> Point:
        if self.operation == "line":
            return subtract(self.end, self.start)
        assert self.control1 is not None and self.control2 is not None
        u = 1.0 - t
        return (
            3 * u * u * (self.control1[0] - self.start[0])
            + 6 * u * t * (self.control2[0] - self.control1[0])
            + 3 * t * t * (self.end[0] - self.control2[0]),
            3 * u * u * (self.control1[1] - self.start[1])
            + 6 * u * t * (self.control2[1] - self.control1[1])
            + 3 * t * t * (self.end[1] - self.control2[1]),
        )

    def split(self, t: float) -> tuple[Curve, Curve]:
        if self.operation == "line":
            middle = lerp(self.start, self.end, t)
            return (
                Curve("line", self.start, middle),
                Curve("line", middle, self.end),
            )
        assert self.control1 is not None and self.control2 is not None
        a = lerp(self.start, self.control1, t)
        b = lerp(self.control1, self.control2, t)
        c = lerp(self.control2, self.end, t)
        d = lerp(a, b, t)
        e = lerp(b, c, t)
        middle = lerp(d, e, t)
        return (
            Curve("cubic", self.start, middle, a, d),
            Curve("cubic", middle, self.end, e, c),
        )

    def reversed(self) -> Curve:
        if self.operation == "line":
            return Curve("line", self.end, self.start)
        return Curve("cubic", self.end, self.start, self.control2, self.control1)


@dataclass(frozen=True)
class Match:
    curve_index: int
    t: float
    point: Point
    tangent: Point

    @property
    def scalar(self) -> float:
        return self.curve_index + self.t


@dataclass(frozen=True)
class RouteSpec:
    identifier: str
    line_id: str
    colour_fragment: str
    path_index: int
    stations: tuple[tuple[str, Point], ...]


ROUTES = (
    RouteSpec(
        "bakerloo.central-core-join.v1",
        "bakerloo",
        "68.330383%",
        1,
        (("Oxford Circus", (900, 895)), ("Piccadilly Circus", (980, 1000)),
         ("Charing Cross", (1067, 1090)), ("Embankment", (1092, 1168)),
         ("Waterloo", (1092, 1270))),
    ),
    RouteSpec(
        "central.central-core-join.v1",
        "central",
        "87.979126%",
        4,
        (("Oxford Circus", (900, 895)), ("Tottenham Court Road", (1067, 895)),
         ("Holborn", (1186, 912))),
    ),
    RouteSpec(
        "circle.central-core-join.v1",
        "circle",
        "98.728943%",
        1,
        (("South Kensington", (624, 1165)), ("Sloane Square", (744, 1165)),
         ("Victoria", (830, 1165)), ("St. James's Park", (900, 1165)),
         ("Westminster", (974, 1165)), ("Embankment", (1092, 1165)),
         ("Temple", (1190, 1165)), ("Blackfriars", (1279, 1111)),
         ("Mansion House", (1327, 1062)), ("Cannon Street", (1363, 1026))),
    ),
    RouteSpec(
        "district.central-core-join.v1",
        "district",
        "8.070374%",
        8,
        (("South Kensington", (625, 1173)), ("Sloane Square", (745, 1173)),
         ("Victoria", (831, 1173)), ("St. James's Park", (901, 1173)),
         ("Westminster", (974, 1173)), ("Embankment", (1091, 1173)),
         ("Temple", (1189, 1173)), ("Blackfriars", (1282, 1119)),
         ("Mansion House", (1330, 1071)), ("Cannon Street", (1366, 1035))),
    ),
    RouteSpec(
        "jubilee.central-core-join.v1",
        "jubilee",
        "45.887756%",
        2,
        (("Green Park", (830, 1000)), ("Westminster", (986, 1156)),
         ("Waterloo", (1043, 1270)), ("Southwark", (1161, 1304)),
         ("London Bridge", (1455, 1135))),
    ),
    RouteSpec(
        "northern.charing-cross.central-core-join.v1",
        "northern",
        "13.729858%",
        5,
        (("Euston", (1096, 620)), ("Warren Street", (1067, 724)),
         ("Goodge Street", (1067, 821)), ("Tottenham Court Road", (1067, 895)),
         ("Leicester Square", (1067, 999)), ("Charing Cross", (1067, 1089)),
         ("Embankment", (1067, 1168)), ("Waterloo", (1067, 1270))),
    ),
    RouteSpec(
        "northern.euston-kings-cross.central-core-join.v1",
        "northern",
        "13.729858%",
        6,
        (("Euston", (1117, 620)), ("King's Cross St. Pancras", (1238, 656))),
    ),
    RouteSpec(
        "piccadilly.central-core-join.v1",
        "piccadilly",
        "17.060852%",
        1,
        (("Green Park", (830, 999)), ("Piccadilly Circus", (980, 999)),
         ("Leicester Square", (1067, 999)), ("Covent Garden", (1129, 969)),
         ("Holborn", (1186, 912)), ("Russell Square", (1238, 790)),
         ("King's Cross St. Pancras", (1238, 656))),
    ),
    RouteSpec(
        "victoria.central-core-join.v1",
        "victoria",
        "17.701721%",
        0,
        (("Green Park", (830, 999)), ("Oxford Circus", (900, 893)),
         ("Warren Street", (1067, 724)), ("Euston", (1096, 620))),
    ),
)


MARKER_ANCHORS: dict[str, Point] = {
    "South Kensington": (624, 1169), "Sloane Square": (744, 1169),
    "Victoria": (830, 1169), "St. James's Park": (900, 1169),
    "Westminster": (974, 1169), "Embankment": (1091, 1169),
    "Temple": (1190, 1169), "Blackfriars": (1280, 1115),
    "Mansion House": (1329, 1067), "Cannon Street": (1365, 1031),
    "Green Park": (830, 999), "Piccadilly Circus": (980, 999),
    "Leicester Square": (1067, 999), "Covent Garden": (1129, 969),
    "Holborn": (1186, 912), "Russell Square": (1238, 790),
    "King's Cross St. Pancras": (1238, 656), "Oxford Circus": (900, 894),
    "Tottenham Court Road": (1067, 894), "Warren Street": (1067, 724),
    "Goodge Street": (1067, 821), "Euston": (1096, 620),
    "Charing Cross": (1067, 1089), "Waterloo": (1067, 1270),
    "Southwark": (1161, 1304), "London Bridge": (1455, 1135),
}


# Positions are traced from PDF text bounds in the same crop coordinate space.
LABELS: dict[str, tuple[str, Point, str]] = {
    "South Kensington": ("South\nKensington", (600, 1192), "trailing"),
    "Sloane Square": ("Sloane\nSquare", (719, 1192), "leading"),
    "Victoria": ("Victoria", (810, 1133), "trailing"),
    "St. James's Park": ("St James's\nPark", (855, 1192), "leading"),
    "Westminster": ("Westminster", (960, 1134), "trailing"),
    "Embankment": ("Embankment", (1102, 1137), "leading"),
    "Temple": ("Temple", (1160, 1190), "leading"),
    "Blackfriars": ("Blackfriars", (1180, 1103), "leading"),
    "Mansion House": ("Mansion\nHouse", (1221, 1060), "leading"),
    "Cannon Street": ("Cannon\nStreet", (1300, 998), "leading"),
    "Green Park": ("Green Park", (840, 972), "leading"),
    "Piccadilly Circus": ("Piccadilly\nCircus", (908, 1021), "leading"),
    "Leicester Square": ("Leicester\nSquare", (984, 962), "trailing"),
    "Covent Garden": ("Covent\nGarden", (1126, 995), "leading"),
    "Holborn": ("Holborn", (1102, 904), "leading"),
    "Russell Square": ("Russell\nSquare", (1165, 742), "leading"),
    "King's Cross St. Pancras": ("King's Cross\n& St Pancras", (1290, 596), "leading"),
    "Oxford Circus": ("Oxford Circus", (910, 900), "leading"),
    "Tottenham Court Road": ("Tottenham\nCourt Road", (1077, 820), "leading"),
    "Warren Street": ("Warren\nStreet", (1081, 742), "leading"),
    "Goodge Street": ("Goodge\nStreet", (1003, 813), "trailing"),
    "Euston": ("Euston", (1024, 608), "trailing"),
    "Charing Cross": ("Charing\nCross", (1078, 1055), "leading"),
    "Waterloo": ("Waterloo", (958, 1274), "trailing"),
    "Southwark": ("Southwark", (1120, 1320), "leading"),
    "London Bridge": ("London Bridge", (1465, 1146), "leading"),
}


def lerp(start: Point, end: Point, t: float) -> Point:
    return (start[0] + (end[0] - start[0]) * t, start[1] + (end[1] - start[1]) * t)


def subtract(left: Point, right: Point) -> Point:
    return (left[0] - right[0], left[1] - right[1])


def rounded(point: Point) -> dict[str, float]:
    return {"x": round(point[0], 3), "y": round(point[1], 3)}


def parse_matrix(value: str | None) -> tuple[float, float, float, float, float, float]:
    numbers = [float(value) for value in re.findall(NUMBER, value or "")]
    return tuple(numbers) if len(numbers) == 6 else (1, 0, 0, 1, 0, 0)


def transform(point: Point, matrix: tuple[float, ...]) -> Point:
    x, y = point
    a, b, c, d, tx, ty = matrix
    return (
        (a * x + c * y + tx) * RASTER_SCALE - CROP_X,
        (b * x + d * y + ty) * RASTER_SCALE - CROP_Y,
    )


def parse_path(data: str, matrix: tuple[float, ...]) -> list[Curve]:
    tokens = TOKENS.findall(data)
    index = 0
    command: str | None = None
    current: Point | None = None
    curves: list[Curve] = []
    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        if command == "M":
            current = transform((float(tokens[index]), float(tokens[index + 1])), matrix)
            index += 2
            command = "L"
        elif command == "L":
            assert current is not None
            end = transform((float(tokens[index]), float(tokens[index + 1])), matrix)
            index += 2
            curves.append(Curve("line", current, end))
            current = end
        elif command == "C":
            assert current is not None
            control1 = transform((float(tokens[index]), float(tokens[index + 1])), matrix)
            control2 = transform((float(tokens[index + 2]), float(tokens[index + 3])), matrix)
            end = transform((float(tokens[index + 4]), float(tokens[index + 5])), matrix)
            index += 6
            curves.append(Curve("cubic", current, end, control1, control2))
            current = end
        elif command in ("Z", "z"):
            break
        else:
            raise ValueError(f"Unsupported SVG path command: {command}")
    return curves


def find_master_path(root: ET.Element, spec: RouteSpec) -> list[Curve]:
    candidates = [
        element for element in root.iter()
        if element.tag.endswith("path")
        and spec.colour_fragment in element.get("stroke", "")
        and element.get("d")
    ]
    element = candidates[spec.path_index]
    return parse_path(element.get("d", ""), parse_matrix(element.get("transform")))


def nearest_match(curves: list[Curve], approximate: Point) -> Match:
    best: tuple[float, int, float, Point] | None = None
    for curve_index, curve in enumerate(curves):
        for sample in range(1001):
            t = sample / 1000
            point = curve.point(t)
            distance = (point[0] - approximate[0]) ** 2 + (point[1] - approximate[1]) ** 2
            if best is None or distance < best[0]:
                best = (distance, curve_index, t, point)
    assert best is not None
    _, curve_index, t, point = best
    return Match(curve_index, t, point, curves[curve_index].tangent(t))


def curve_slice(curve: Curve, start_t: float, end_t: float) -> Curve:
    if start_t == 0 and end_t == 1:
        return curve
    left, _ = curve.split(end_t)
    if start_t == 0:
        return left
    _, result = left.split(start_t / end_t)
    return result


def path_slice(curves: list[Curve], start: Match, end: Match) -> list[Curve]:
    reverse = start.scalar > end.scalar
    low, high = (end, start) if reverse else (start, end)
    result: list[Curve] = []
    for index in range(low.curve_index, high.curve_index + 1):
        start_t = low.t if index == low.curve_index else 0.0
        end_t = high.t if index == high.curve_index else 1.0
        result.append(curve_slice(curves[index], start_t, end_t))
    if reverse:
        return [curve.reversed() for curve in reversed(result)]
    return result


def path_commands(curves: list[Curve]) -> list[dict]:
    commands = [{"op": "move", "to": rounded(curves[0].start)}]
    for curve in curves:
        if curve.operation == "line":
            commands.append({"op": "line", "to": rounded(curve.end)})
        else:
            assert curve.control1 is not None and curve.control2 is not None
            commands.append({
                "op": "cubic",
                "control1": rounded(curve.control1),
                "control2": rounded(curve.control2),
                "to": rounded(curve.end),
            })
    return commands


def semantic_segment(graph: dict, line_id: str, from_id: str, to_id: str) -> dict:
    expected = {from_id, to_id}
    for segment in graph["segments"]:
        if segment["lineID"] == line_id and {segment["fromStationID"], segment["toStationID"]} == expected:
            return segment
    raise KeyError(f"Missing graph segment {line_id}: {from_id} - {to_id}")


def unique_points(points: Iterable[Point], tolerance: float = 3.0) -> list[Point]:
    result: list[Point] = []
    for point in points:
        if not any(math.dist(point, existing) <= tolerance for existing in result):
            result.append(point)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--svg", required=True, type=Path)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    root = ET.parse(arguments.svg).getroot()
    graph = json.loads(arguments.graph.read_text())
    stations_by_name = {station["name"]: station for station in graph["stations"]}

    paths: list[dict] = []
    segments: list[dict] = []
    routes: list[dict] = []
    ports_by_station: dict[str, list[tuple[str, Match]]] = {}

    for route in ROUTES:
        master = find_master_path(root, route)
        matches = [(name, nearest_match(master, approximate)) for name, approximate in route.stations]
        route_station_ids: list[str] = []
        route_segment_ids: list[str] = []
        for name, match in matches:
            route_station_ids.append(stations_by_name[name]["id"])
            ports_by_station.setdefault(name, []).append((route.line_id, match))
        for pair_index, ((from_name, from_match), (to_name, to_match)) in enumerate(zip(matches, matches[1:])):
            from_id = stations_by_name[from_name]["id"]
            to_id = stations_by_name[to_name]["id"]
            graph_segment = semantic_segment(graph, route.line_id, from_id, to_id)
            path_id = f"beck.v1.path.{route.identifier}.{pair_index}"
            paths.append({"id": path_id, "commands": path_commands(path_slice(master, from_match, to_match))})
            segments.append({
                "id": graph_segment["id"],
                "lineID": route.line_id,
                "fromStationID": from_id,
                "toStationID": to_id,
                "fromPort": rounded(from_match.point),
                "toPort": rounded(to_match.point),
                "pathID": path_id,
                "pathDirection": "forward",
                "translation": {"x": 0, "y": 0},
            })
            route_segment_ids.append(graph_segment["id"])
        routes.append({
            "id": route.identifier,
            "lineID": route.line_id,
            "stationIDs": route_station_ids,
            "segmentIDs": route_segment_ids,
        })

    markers: list[dict] = []
    labels: list[dict] = []
    for name in MARKER_ANCHORS:
        station = stations_by_name[name]
        anchor = MARKER_ANCHORS[name]
        line_matches = ports_by_station[name]
        line_ids = sorted({line_id for line_id, _ in line_matches})
        ports = unique_points(match.point for _, match in line_matches)
        is_interchange = station["interchange"] or len(line_ids) > 1
        primitives: list[dict] = []
        if is_interchange:
            for port in ports:
                if math.dist(port, anchor) > 4:
                    primitives.append({
                        "kind": "connector",
                        "connector": {"start": rounded(anchor), "end": rounded(port), "width": 7.5},
                    })
            circle_points = unique_points([anchor, *ports], tolerance=7.0)
            for point in circle_points:
                primitives.append({
                    "kind": "circle",
                    "circle": {"centre": rounded(point), "radius": 8.5, "outlineWidth": 3.5},
                })
        else:
            line_id, match = line_matches[0]
            tangent = match.tangent
            length = math.hypot(*tangent) or 1
            normal = (-tangent[1] / length * 7, tangent[0] / length * 7)
            primitives.append({
                "kind": "tick",
                "tick": {
                    "lineID": line_id,
                    "start": rounded((anchor[0] - normal[0], anchor[1] - normal[1])),
                    "end": rounded((anchor[0] + normal[0], anchor[1] + normal[1])),
                    "width": 3.2,
                },
            })
        markers.append({
            "stationID": station["id"],
            "name": station["name"],
            "lineIDs": line_ids,
            "anchor": rounded(anchor),
            "hitRadius": 24,
            "primitives": primitives,
        })
        text, position, alignment = LABELS[name]
        labels.append({
            "id": f"label.{station['id']}",
            "stationID": station["id"],
            "text": text,
            "position": rounded(position),
            "alignment": alignment,
            "rotationDegrees": 0,
            "priority": 10 if is_interchange else 5,
        })

    document = {
        "schemaVersion": {"major": 1, "minor": 2},
        "identifier": "tube-track-uk.beck.central-core-join.v1",
        "geometryStatus": "authored",
        "source": {
            "graphSchemaVersion": graph["schemaVersion"],
            "graphGeneratedAt": graph["generatedAt"],
            "note": (
                "Exact coloured master paths extracted offline from the April 2026 TfL vector map; "
                "station ports and labels manually identified in the fixed 2600×2000 reference crop."
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
            "resourceName": "central-core-join-reference-debug",
            "resourceExtension": "png",
            "geometryOpacity": 0.52,
        },
        "paths": paths,
        "segments": segments,
        "stationMarkers": markers,
        "labels": labels,
        "routes": routes,
    }
    arguments.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
