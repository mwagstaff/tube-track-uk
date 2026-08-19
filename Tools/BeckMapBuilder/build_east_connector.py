#!/usr/bin/env python3
"""Build the East Connector from exact paths in the official TfL SVG export."""

from __future__ import annotations

import argparse
import json
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import build_central_core_join as vector


vector.CROP_X = 1200.0
vector.CROP_Y = 600.0
vector.ARTWORK_WIDTH = 2600.0
vector.ARTWORK_HEIGHT = 2000.0


ROUTES = (
    vector.RouteSpec(
        "central.east-connector.v1", "central", "87.979126%", 4,
        (("Holborn", (885, 1012)), ("Chancery Lane", (932, 1048)),
         ("St. Paul's", (1005, 1048)), ("Bank", (1135, 1000)),
         ("Liverpool Street", (1235, 899)), ("Bethnal Green", (1545, 891)),
         ("Mile End", (1710, 915)), ("Stratford", (2020, 636))),
    ),
    vector.RouteSpec(
        "circle.east-connector.v1", "circle", "98.728943%", 1,
        (("Cannon Street", (1062, 1127)), ("Monument", (1193, 1087)),
         ("Tower Hill", (1329, 1087)), ("Aldgate", (1365, 1010)),
         ("Liverpool Street", (1185, 949))),
    ),
    vector.RouteSpec(
        "district.east-connector.v1", "district", "8.070374%", 8,
        (("Cannon Street", (1066, 1136)), ("Monument", (1196, 1096)),
         ("Tower Hill", (1332, 1096)), ("Aldgate East", (1455, 950)),
         ("Whitechapel", (1505, 950)), ("Stepney Green", (1655, 950)),
         ("Mile End", (1710, 950))),
    ),
    vector.RouteSpec(
        "hammersmith-city.east-connector.v1", "hammersmith-city", "93.824768%", 1,
        (("Liverpool Street", (1185, 941)), ("Aldgate East", (1455, 941)),
         ("Whitechapel", (1505, 941)), ("Stepney Green", (1655, 941)),
         ("Mile End", (1710, 941))),
    ),
    vector.RouteSpec(
        "metropolitan.east-connector.v1", "metropolitan", "51.182556%", 2,
        (("Liverpool Street", (1185, 958)), ("Aldgate", (1353, 966))),
    ),
    vector.RouteSpec(
        "northern.bank.east-connector.v1", "northern", "13.729858%", 6,
        (("King's Cross St. Pancras", (937, 757)), ("Angel", (1050, 800)),
         ("Old Street", (1131, 829)), ("Moorgate", (1155, 950)),
         ("Bank", (1155, 1020)), ("London Bridge", (1155, 1235))),
    ),
    vector.RouteSpec(
        "jubilee.east-connector.v1", "jubilee", "45.887756%", 2,
        (("London Bridge", (1155, 1235)), ("Bermondsey", (1370, 1310)),
         ("Canada Water", (1505, 1318)), ("Canary Wharf", (1790, 1338)),
         ("North Greenwich", (1959, 1360))),
    ),
)


MARKER_ANCHORS: dict[str, vector.Point] = {
    "Holborn": (885, 1012), "Chancery Lane": (932, 1048),
    "St. Paul's": (1005, 1048), "Bank": (1145, 1010),
    "Liverpool Street": (1185, 899), "Bethnal Green": (1545, 891),
    "Mile End": (1710, 943), "Stratford": (2020, 636),
    "Cannon Street": (1064, 1131), "Monument": (1195, 1092),
    "Tower Hill": (1330, 1092), "Aldgate": (1359, 988),
    "Aldgate East": (1455, 945), "Whitechapel": (1505, 945),
    "Stepney Green": (1655, 945), "King's Cross St. Pancras": (937, 757),
    "Angel": (1050, 800), "Old Street": (1131, 829),
    "Moorgate": (1155, 950), "London Bridge": (1155, 1235),
    "Bermondsey": (1370, 1310), "Canada Water": (1505, 1318),
    "Canary Wharf": (1790, 1338), "North Greenwich": (1959, 1360),
}


LABELS: dict[str, tuple[str, vector.Point, str]] = {
    "Holborn": ("Holborn", (870, 1004), "trailing"),
    "Chancery Lane": ("Chancery\nLane", (905, 1073), "trailing"),
    "St. Paul's": ("St Paul's", (1013, 1058), "leading"),
    "Bank": ("Bank", (1166, 1026), "leading"),
    "Liverpool Street": ("Liverpool\nStreet", (1241, 850), "leading"),
    "Bethnal Green": ("Bethnal\nGreen", (1546, 854), "leading"),
    "Mile End": ("Mile\nEnd", (1695, 878), "leading"),
    "Stratford": ("Stratford", (2071, 670), "leading"),
    "Cannon Street": ("Cannon\nStreet", (1006, 1098), "trailing"),
    "Monument": ("Monument", (1166, 1103), "leading"),
    "Tower Hill": ("Tower\nHill", (1273, 1112), "leading"),
    "Aldgate": ("Aldgate", (1281, 999), "leading"),
    "Aldgate East": ("Aldgate\nEast", (1436, 969), "leading"),
    "Whitechapel": ("Whitechapel", (1516, 958), "leading"),
    "Stepney Green": ("Stepney\nGreen", (1667, 969), "leading"),
    "King's Cross St. Pancras": ("King's Cross\n& St Pancras", (990, 696), "leading"),
    "Angel": ("Angel", (1031, 771), "trailing"),
    "Old Street": ("Old\nStreet", (1144, 794), "leading"),
    "Moorgate": ("Moorgate", (1135, 970), "trailing"),
    "London Bridge": ("London Bridge", (1165, 1246), "leading"),
    "Bermondsey": ("Bermondsey", (1247, 1304), "trailing"),
    "Canada Water": ("Canada\nWater", (1439, 1333), "trailing"),
    "Canary Wharf": ("Canary Wharf", (1780, 1282), "trailing"),
    "North Greenwich": ("North\nGreenwich", (1966, 1371), "leading"),
}


def tick_primitive(line_id: str, match: vector.Match) -> dict:
    dx, dy = match.tangent
    magnitude = math.hypot(dx, dy) or 1
    normal = (-dy / magnitude * 7, dx / magnitude * 7)
    return {
        "kind": "tick",
        "tick": {
            "lineID": line_id,
            "start": vector.rounded((match.point[0] - normal[0], match.point[1] - normal[1])),
            "end": vector.rounded((match.point[0] + normal[0], match.point[1] + normal[1])),
            "width": 3.2,
        },
    }


def build(svg: Path, graph_path: Path) -> dict:
    root = ET.parse(svg).getroot()
    graph = json.loads(graph_path.read_text())
    stations_by_name = {station["name"]: station for station in graph["stations"]}
    paths: list[dict] = []
    segments: list[dict] = []
    routes: list[dict] = []
    ports_by_station: dict[str, list[tuple[str, vector.Match]]] = {}

    for route in ROUTES:
        master = vector.find_master_path(root, route)
        matches = [(name, vector.nearest_match(master, approximate)) for name, approximate in route.stations]
        station_ids = [stations_by_name[name]["id"] for name, _ in matches]
        segment_ids: list[str] = []
        for name, match in matches:
            ports_by_station.setdefault(name, []).append((route.line_id, match))
        for index, ((from_name, from_match), (to_name, to_match)) in enumerate(zip(matches, matches[1:])):
            from_id = stations_by_name[from_name]["id"]
            to_id = stations_by_name[to_name]["id"]
            semantic = vector.semantic_segment(graph, route.line_id, from_id, to_id)
            path_id = f"beck.v1.path.{route.identifier}.{index}"
            paths.append({
                "id": path_id,
                "commands": vector.path_commands(vector.path_slice(master, from_match, to_match)),
            })
            segments.append({
                "id": semantic["id"], "lineID": route.line_id,
                "fromStationID": from_id, "toStationID": to_id,
                "fromPort": vector.rounded(from_match.point),
                "toPort": vector.rounded(to_match.point),
                "pathID": path_id, "pathDirection": "forward",
                "translation": {"x": 0, "y": 0},
            })
            segment_ids.append(semantic["id"])
        routes.append({
            "id": route.identifier, "lineID": route.line_id,
            "stationIDs": station_ids, "segmentIDs": segment_ids,
        })

    markers: list[dict] = []
    labels: list[dict] = []
    for name, anchor in MARKER_ANCHORS.items():
        station = stations_by_name[name]
        line_matches = ports_by_station[name]
        line_ids = sorted({line_id for line_id, _ in line_matches})
        ports = vector.unique_points((match.point for _, match in line_matches), tolerance=3)
        is_interchange = station["interchange"] or len(line_ids) > 1
        primitives: list[dict] = []
        if name in {"Aldgate", "Aldgate East"}:
            # The official map uses ordinary line ticks here. These stations
            # share parallel Underground lines, but they are not drawn as
            # multi-point internal interchanges with white connector circles.
            anchor = tuple(
                sum(match.point[index] for _, match in line_matches) / len(line_matches)
                for index in (0, 1)
            )
            primitives = [tick_primitive(line_id, match) for line_id, match in line_matches]
            is_interchange = False
        elif name == "Liverpool Street":
            # The official interchange has two visible station points joined
            # by a right-angle internal connector. The bend itself is not a
            # third platform, and the three shared-corridor lanes use one
            # grouped lower station point.
            central_port = next(match.point for line_id, match in line_matches if line_id == "central")
            shared_matches = [
                match for line_id, match in line_matches
                if line_id in {"circle", "hammersmith-city", "metropolitan"}
            ]
            shared_port = tuple(
                sum(match.point[index] for match in shared_matches) / len(shared_matches)
                for index in (0, 1)
            )
            elbow = (shared_port[0], central_port[1])
            anchor = central_port
            primitives = [
                {
                    "kind": "connector",
                    "connector": {
                        "start": vector.rounded(central_port),
                        "end": vector.rounded(elbow),
                        "width": 7.5,
                    },
                },
                {
                    "kind": "connector",
                    "connector": {
                        "start": vector.rounded(elbow),
                        "end": vector.rounded(shared_port),
                        "width": 7.5,
                    },
                },
                {
                    "kind": "circle",
                    "circle": {
                        "centre": vector.rounded(central_port), "radius": 8.5, "outlineWidth": 3.5,
                    },
                },
                {
                    "kind": "circle",
                    "circle": {
                        "centre": vector.rounded(shared_port), "radius": 8.5, "outlineWidth": 3.5,
                    },
                },
            ]
        elif is_interchange:
            for port in ports:
                if math.dist(port, anchor) > 4:
                    primitives.append({
                        "kind": "connector",
                        "connector": {
                            "start": vector.rounded(anchor), "end": vector.rounded(port), "width": 7.5,
                        },
                    })
            for point in vector.unique_points([anchor, *ports], tolerance=7):
                primitives.append({
                    "kind": "circle",
                    "circle": {"centre": vector.rounded(point), "radius": 8.5, "outlineWidth": 3.5},
                })
        else:
            line_id, match = line_matches[0]
            primitives.append(tick_primitive(line_id, match))
        markers.append({
            "stationID": station["id"], "name": station["name"], "lineIDs": line_ids,
            "anchor": vector.rounded(anchor), "hitRadius": 24, "primitives": primitives,
        })
        text, position, alignment = LABELS[name]
        labels.append({
            "id": f"label.{station['id']}", "stationID": station["id"], "text": text,
            "position": vector.rounded(position), "alignment": alignment,
            "rotationDegrees": 0, "priority": 10 if is_interchange else 5,
        })

    return {
        "schemaVersion": {"major": 1, "minor": 2},
        "identifier": "tube-track-uk.beck.east-connector.v1",
        "geometryStatus": "authored",
        "source": {
            "graphSchemaVersion": graph["schemaVersion"],
            "graphGeneratedAt": graph["generatedAt"],
            "note": (
                "Exact master paths extracted offline from the April 2026 TfL vector map; "
                "east London station ports and labels manually identified in a fixed 2600x2000 crop."
            ),
        },
        "artworkSize": {"width": 2600, "height": 2000},
        "styles": {
            "routeStrokeWidth": 8.3, "affectedOuterStrokeWidth": 19,
            "affectedKnockoutStrokeWidth": 15, "affectedRouteStrokeWidth": 10,
            "primaryLabelFontSize": 18, "secondaryLabelFontSize": 16, "labelPadding": 2,
        },
        "debugReference": {
            "resourceName": "east-connector-reference-debug", "resourceExtension": "png",
            "geometryOpacity": 0.52,
        },
        "paths": paths, "segments": segments, "stationMarkers": markers,
        "labels": labels, "routes": routes,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--svg", required=True, type=Path)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    arguments.output.write_text(json.dumps(build(arguments.svg, arguments.graph), indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
