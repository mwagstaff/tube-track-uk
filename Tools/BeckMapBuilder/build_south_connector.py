#!/usr/bin/env python3
"""Compile the south-central Underground fan from the official TfL vector map.

The source paths are copied without simplification.  TubeGraph contributes
stable station and segment identifiers only; it is not used for layout.
"""

from __future__ import annotations

import argparse
import json
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import build_central_core_join as vector


vector.CROP_X = 1250.0
vector.CROP_Y = 1550.0
vector.ARTWORK_WIDTH = 1250.0
vector.ARTWORK_HEIGHT = 1300.0


ROUTES = (
    vector.RouteSpec(
        "northern.charing-cross.south-connector.v1", "northern", "13.729858%", 5,
        (("Waterloo", (717, 420)), ("Kennington", (702, 683)),
         ("Oval", (654, 753)), ("Stockwell", (610, 798)),
         ("Clapham North", (562, 846)), ("Clapham Common", (515, 893)),
         ("Clapham South", (445, 963)), ("Balham", (395, 1013)),
         ("Tooting Bec", (350, 1058)), ("Tooting Broadway", (305, 1103)),
         ("Colliers Wood", (260, 1148)), ("South Wimbledon", (208, 1200)),
         ("Morden", (181, 1227))),
    ),
    vector.RouteSpec(
        "northern.bank.south-connector.v1", "northern", "13.729858%", 6,
        (("Kennington", (658, 750)), ("Elephant & Castle", (811, 621)),
         ("Borough", (950, 481)), ("London Bridge", (1105, 335))),
    ),
    vector.RouteSpec(
        "northern.battersea.south-connector.v1", "northern", "13.729858%", 4,
        (("Battersea Power Station", (313, 639)), ("Nine Elms", (393, 639)),
         ("Kennington", (706, 679))),
    ),
    vector.RouteSpec(
        "victoria.south-connector.v1", "victoria", "17.701721%", 0,
        (("Brixton", (713, 900)), ("Stockwell", (610, 798)),
         ("Vauxhall", (503, 691)), ("Pimlico", (479, 550)),
         ("Victoria", (479, 319))),
    ),
    vector.RouteSpec(
        "bakerloo.south-connector.v1", "bakerloo", "68.330383%", 1,
        (("Elephant & Castle", (811, 621)), ("Lambeth North", (741, 520)),
         ("Waterloo", (741, 420))),
    ),
)


MARKER_ANCHORS: dict[str, vector.Point] = {
    "Waterloo": (728.8, 419.8), "Kennington": (701.7, 682.7),
    "Oval": (654.6, 753.1), "Stockwell": (609.8, 797.8),
    "Clapham North": (562.0, 845.7), "Clapham Common": (514.8, 892.9),
    "Clapham South": (444.9, 962.8), "Balham": (395.2, 1012.5),
    "Tooting Bec": (349.9, 1057.8), "Tooting Broadway": (305.0, 1102.7),
    "Colliers Wood": (259.9, 1147.7), "South Wimbledon": (208.0, 1199.7),
    "Morden": (180.9, 1226.9), "Elephant & Castle": (810.6, 620.7),
    "Borough": (950.0, 481.3), "London Bridge": (1104.7, 334.8),
    "Battersea Power Station": (312.5, 639.1), "Nine Elms": (392.5, 639.1),
    "Brixton": (712.5, 900.4), "Vauxhall": (502.9, 690.7),
    "Pimlico": (479.0, 550.0), "Victoria": (479.2, 319.0),
    "Lambeth North": (741.1, 520.0),
}


# Kennington's Bank-branch master begins at the southern junction before it
# curls into the station.  That path start must remain in the rendered lens,
# but it is not a platform circle.  The official artwork has two platform
# circles: the Charing Cross/Battersea port and the Bank-branch port below it.
MARKER_PORT_OVERRIDES: dict[str, tuple[vector.Point, ...]] = {
    "Kennington": ((701.712, 682.709), (718.8, 712.5)),
}


LABELS: dict[str, tuple[str, vector.Point, str]] = {
    "Waterloo": ("Waterloo", (607, 424), "trailing"),
    "Kennington": ("Kennington", (603, 657), "trailing"),
    "Oval": ("Oval", (664, 758), "leading"),
    "Stockwell": ("Stockwell", (628, 788), "leading"),
    "Clapham North": ("Clapham North", (548, 834), "trailing"),
    "Clapham Common": ("Clapham\nCommon", (535, 889), "leading"),
    "Clapham South": ("Clapham South", (490, 936), "leading"),
    "Balham": ("Balham", (454, 973), "leading"),
    "Tooting Bec": ("Tooting Bec", (418, 1007), "leading"),
    "Tooting Broadway": ("Tooting Broadway", (382, 1043), "leading"),
    "Colliers Wood": ("Colliers\nWood", (276, 1088), "leading"),
    "South Wimbledon": ("South Wimbledon", (295, 1158), "leading"),
    "Morden": ("Morden", (164, 1252), "trailing"),
    "Elephant & Castle": ("Elephant & Castle", (859, 643), "leading"),
    "Borough": ("Borough", (959, 493), "leading"),
    "London Bridge": ("London Bridge", (1115, 296), "leading"),
    "Battersea Power Station": ("Battersea\nPower Station", (274, 652), "centre"),
    "Nine Elms": ("Nine\nElms", (376, 652), "centre"),
    "Brixton": ("Brixton", (678, 907), "trailing"),
    "Vauxhall": ("Vauxhall", (401, 695), "trailing"),
    "Pimlico": ("Pimlico", (464, 517), "trailing"),
    "Victoria": ("Victoria", (398, 283), "trailing"),
    "Lambeth North": ("Lambeth\nNorth", (756, 511), "leading"),
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
        ports = list(MARKER_PORT_OVERRIDES.get(
            name,
            tuple(vector.unique_points((match.point for _, match in line_matches), tolerance=3)),
        ))
        is_interchange = station["interchange"] or len(line_ids) > 1 or len(ports) > 1
        primitives: list[dict] = []
        if is_interchange:
            for port in ports:
                if math.dist(port, anchor) > 4:
                    primitives.append({
                        "kind": "connector",
                        "connector": {"start": vector.rounded(anchor), "end": vector.rounded(port), "width": 7.5},
                    })
            for point in vector.unique_points([anchor, *ports], tolerance=7):
                primitives.append({
                    "kind": "circle",
                    "circle": {"centre": vector.rounded(point), "radius": 8.5, "outlineWidth": 3.5},
                })
        else:
            line_id, match = line_matches[0]
            dx, dy = match.tangent
            magnitude = math.hypot(dx, dy) or 1
            normal = (-dy / magnitude * 7, dx / magnitude * 7)
            primitives.append({
                "kind": "tick",
                "tick": {
                    "lineID": line_id,
                    "start": vector.rounded((anchor[0] - normal[0], anchor[1] - normal[1])),
                    "end": vector.rounded((anchor[0] + normal[0], anchor[1] + normal[1])), "width": 3.2,
                },
            })
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
        "identifier": "tube-track-uk.beck.south-connector.v1",
        "geometryStatus": "authored",
        "source": {
            "graphSchemaVersion": graph["schemaVersion"], "graphGeneratedAt": graph["generatedAt"],
            "note": (
                "Exact master paths extracted offline from the April 2026 TfL vector map; "
                "south-central station ports and labels manually identified in a fixed 1250x1300 crop."
            ),
        },
        "artworkSize": {"width": 1250, "height": 1300},
        "styles": {
            "routeStrokeWidth": 8.3, "affectedOuterStrokeWidth": 19,
            "affectedKnockoutStrokeWidth": 15, "affectedRouteStrokeWidth": 10,
            "primaryLabelFontSize": 18, "secondaryLabelFontSize": 16, "labelPadding": 2,
        },
        "debugReference": {
            "resourceName": "south-connector-reference-debug", "resourceExtension": "png",
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
