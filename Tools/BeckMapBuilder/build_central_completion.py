#!/usr/bin/env python3
"""Compile the final central Underground joins from the official TfL vector map."""

from __future__ import annotations

import argparse
import json
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import build_central_core_join as vector


vector.CROP_X = 1500.0
vector.CROP_Y = 1250.0
vector.ARTWORK_WIDTH = 500.0
vector.ARTWORK_HEIGHT = 800.0


def p(x: float, y: float) -> vector.Point:
    return (x * 2 - vector.CROP_X, y * 2 - vector.CROP_Y)


ROUTES = (
    vector.RouteSpec(
        "bakerloo.central-completion.v1", "bakerloo", "68.330383%", 1,
        (("Baker Street", p(841, 715)), ("Regent's Park", p(870, 744)),
         ("Oxford Circus", p(899, 797))),
    ),
    vector.RouteSpec(
        "jubilee.central-completion.v1", "jubilee", "45.887756%", 2,
        (("Baker Street", p(841, 693)), ("Bond Street", p(841, 797)),
         ("Green Park", p(865, 850))),
    ),
    vector.RouteSpec(
        "victoria.central-completion.v1", "victoria", "17.701721%", 0,
        (("Victoria", p(865, 934)), ("Green Park", p(865, 850))),
    ),
)


LABEL_OFFSETS: dict[str, tuple[float, float, str]] = {
    "Baker Street": (20, -18, "leading"),
    "Regent's Park": (18, 4, "leading"),
    "Oxford Circus": (20, 18, "leading"),
    "Bond Street": (-18, 5, "trailing"),
    "Green Park": (-18, 18, "trailing"),
    "Victoria": (-18, 5, "trailing"),
}


def build(svg: Path, graph_path: Path) -> dict:
    root = ET.parse(svg).getroot()
    graph = json.loads(graph_path.read_text())
    stations_by_name = {station["name"]: station for station in graph["stations"]}
    paths: list[dict] = []
    segments: list[dict] = []
    routes: list[dict] = []
    ports: dict[str, list[tuple[str, vector.Match]]] = {}

    for route in ROUTES:
        master = vector.find_master_path(root, route)
        matches = [(name, vector.nearest_match(master, approximate)) for name, approximate in route.stations]
        station_ids = [stations_by_name[name]["id"] for name, _ in matches]
        segment_ids: list[str] = []
        for name, match in matches:
            ports.setdefault(name, []).append((route.line_id, match))
        for index, ((from_name, from_match), (to_name, to_match)) in enumerate(zip(matches, matches[1:])):
            from_id = stations_by_name[from_name]["id"]
            to_id = stations_by_name[to_name]["id"]
            semantic = vector.semantic_segment(graph, route.line_id, from_id, to_id)
            path_id = f"beck.v1.path.{route.identifier}.{index}"
            paths.append({"id": path_id, "commands": vector.path_commands(vector.path_slice(master, from_match, to_match))})
            segments.append({
                "id": semantic["id"], "lineID": route.line_id,
                "fromStationID": from_id, "toStationID": to_id,
                "fromPort": vector.rounded(from_match.point), "toPort": vector.rounded(to_match.point),
                "pathID": path_id, "pathDirection": "forward", "translation": {"x": 0, "y": 0},
            })
            segment_ids.append(semantic["id"])
        routes.append({
            "id": route.identifier, "lineID": route.line_id,
            "stationIDs": station_ids, "segmentIDs": segment_ids,
        })

    def tick(line_id: str, match: vector.Match) -> dict:
        dx, dy = match.tangent
        magnitude = math.hypot(dx, dy) or 1
        normal = (-dy / magnitude * 7, dx / magnitude * 7)
        return {"kind": "tick", "tick": {
            "lineID": line_id,
            "start": vector.rounded((match.point[0] - normal[0], match.point[1] - normal[1])),
            "end": vector.rounded((match.point[0] + normal[0], match.point[1] + normal[1])), "width": 3.2,
        }}

    markers: list[dict] = []
    labels: list[dict] = []
    for name, line_matches in ports.items():
        station = stations_by_name[name]
        line_ids = sorted({line_id for line_id, _ in line_matches})
        points = vector.unique_points((match.point for _, match in line_matches), tolerance=4)
        anchor = points[0]
        interchange = station["interchange"] or len(line_ids) > 1 or len(points) > 1
        primitives: list[dict] = []
        if interchange:
            for point in points[1:]:
                if math.dist(anchor, point) > 5:
                    primitives.append({"kind": "connector", "connector": {
                        "start": vector.rounded(anchor), "end": vector.rounded(point), "width": 7.5,
                    }})
            for point in vector.unique_points([anchor, *points], tolerance=7):
                primitives.append({"kind": "circle", "circle": {
                    "centre": vector.rounded(point), "radius": 8.5, "outlineWidth": 3.5,
                }})
        else:
            line_id, match = line_matches[0]
            primitives.append(tick(line_id, match))

        markers.append({
            "stationID": station["id"], "name": station["name"], "lineIDs": line_ids,
            "anchor": vector.rounded(anchor), "hitRadius": 24, "primitives": primitives,
        })
        dx, dy, alignment = LABEL_OFFSETS[name]
        labels.append({
            "id": f"label.{station['id']}", "stationID": station["id"], "text": station["name"],
            "position": vector.rounded((anchor[0] + dx, anchor[1] + dy)), "alignment": alignment,
            "rotationDegrees": 0, "priority": 10 if interchange else 5,
        })

    return {
        "schemaVersion": {"major": 1, "minor": 2},
        "identifier": "tube-track-uk.beck.central-completion.v1", "geometryStatus": "authored",
        "source": {
            "graphSchemaVersion": graph["schemaVersion"], "graphGeneratedAt": graph["generatedAt"],
            "note": "Exact master paths extracted offline from the April 2026 TfL vector map; final central joins manually ported in a fixed 500x800 crop.",
        },
        "artworkSize": {"width": 500, "height": 800},
        "styles": {
            "routeStrokeWidth": 8.3, "affectedOuterStrokeWidth": 19,
            "affectedKnockoutStrokeWidth": 15, "affectedRouteStrokeWidth": 10,
            "primaryLabelFontSize": 18, "secondaryLabelFontSize": 16, "labelPadding": 2,
        },
        "debugReference": {
            "resourceName": "central-completion-reference-debug", "resourceExtension": "png", "geometryOpacity": 0.52,
        },
        "paths": paths, "segments": segments, "stationMarkers": markers, "labels": labels, "routes": routes,
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
