#!/usr/bin/env python3
"""Build the north-central Underground fan from the official TfL vector map.

The compiler keeps the source line/cubic geometry unchanged and splits it at
manually identified station ports. TubeGraph supplies identifiers and
adjacency only; it is never used to position the artwork.
"""

from __future__ import annotations

import argparse
import json
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import build_central_core_join as vector


vector.CROP_X = 1250.0
vector.CROP_Y = 450.0
vector.ARTWORK_WIDTH = 1950.0
vector.ARTWORK_HEIGHT = 1050.0


ROUTES = (
    vector.RouteSpec(
        "northern.edgware.north-connector.v1", "northern", "13.729858%", 3,
        (("Edgware", (200, 168)), ("Burnt Oak", (256, 224)),
         ("Colindale", (298, 266)), ("Hendon Central", (380, 349)),
         ("Brent Cross", (433, 401)), ("Golders Green", (471, 439)),
         ("Hampstead", (526, 494)), ("Belsize Park", (593, 561)),
         ("Chalk Farm", (648, 616)), ("Camden Town", (762, 742))),
    ),
    vector.RouteSpec(
        "northern.high-barnet.north-connector.v1", "northern", "13.729858%", 5,
        (("High Barnet", (863, 113)), ("Totteridge & Whetstone", (863, 157)),
         ("Woodside Park", (863, 200)), ("West Finchley", (863, 242)),
         ("Finchley Central", (863, 294)), ("East Finchley", (863, 346)),
         ("Highgate", (863, 392)), ("Archway", (863, 466)),
         ("Tufnell Park", (863, 525)), ("Kentish Town", (863, 599)),
         ("Camden Town", (762, 742)), ("Mornington Crescent", (746, 815)),
         ("Euston", (746, 870))),
    ),
    vector.RouteSpec(
        "northern.mill-hill-east.north-connector.v1", "northern", "13.729858%", 2,
        (("Mill Hill East", (826, 268)), ("Finchley Central", (863, 315))),
    ),
    vector.RouteSpec(
        "northern.bank-join.north-connector.v1", "northern", "13.729858%", 6,
        (("Camden Town", (762, 775)), ("Euston", (778, 850)),
         ("King's Cross St. Pancras", (887, 907))),
    ),
    vector.RouteSpec(
        "piccadilly.north-connector.v1", "piccadilly", "17.060852%", 1,
        (("King's Cross St. Pancras", (888, 906)),
         ("Caledonian Road", (950, 788)), ("Holloway Road", (1015, 723)),
         ("Arsenal", (1075, 663)), ("Finsbury Park", (1143, 595)),
         ("Manor House", (1236, 476)), ("Turnpike Lane", (1236, 375)),
         ("Wood Green", (1236, 312)), ("Bounds Green", (1236, 252)),
         ("Arnos Grove", (1236, 207)), ("Southgate", (1236, 165)),
         ("Oakwood", (1236, 127)), ("Cockfosters", (1236, 84))),
    ),
    vector.RouteSpec(
        "victoria.north-connector.v1", "victoria", "17.701721%", 0,
        (("Euston", (778, 914)), ("King's Cross St. Pancras", (888, 908)),
         ("Highbury & Islington", (1156, 723)), ("Finsbury Park", (1156, 608)),
         ("Seven Sisters", (1335, 510)), ("Tottenham Hale", (1480, 510)),
         ("Blackhorse Road", (1640, 510)), ("Walthamstow Central", (1758, 510))),
    ),
)


MARKER_ANCHORS: dict[str, vector.Point] = {
    "Edgware": (199.8, 167.9), "Burnt Oak": (256.3, 224.4),
    "Colindale": (297.9, 266.0), "Hendon Central": (380.4, 348.6),
    "Brent Cross": (432.5, 400.6), "Golders Green": (470.8, 438.9),
    "Hampstead": (526.2, 494.3), "Belsize Park": (592.7, 560.8),
    "Chalk Farm": (648.1, 616.2), "Camden Town": (762.1, 758.5),
    "High Barnet": (862.6, 113.3), "Totteridge & Whetstone": (862.6, 156.8),
    "Woodside Park": (862.6, 199.9), "West Finchley": (862.6, 241.9),
    "Finchley Central": (862.6, 294.0), "East Finchley": (862.6, 346.1),
    "Highgate": (862.6, 392.2), "Archway": (862.6, 466.0),
    "Tufnell Park": (862.6, 525.3), "Kentish Town": (862.6, 599.1),
    "Mornington Crescent": (745.6, 815.0), "Euston": (745.6, 870.0),
    "Mill Hill East": (825.8, 268.2), "King's Cross St. Pancras": (887.7, 906.8),
    "Caledonian Road": (949.6, 787.9), "Holloway Road": (1014.8, 722.8),
    "Arsenal": (1074.9, 662.6), "Finsbury Park": (1149.5, 601.5),
    "Manor House": (1236.4, 475.8), "Turnpike Lane": (1236.4, 375.2),
    "Wood Green": (1236.4, 311.9), "Bounds Green": (1236.4, 251.8),
    "Arnos Grove": (1236.4, 207.2), "Southgate": (1236.4, 165.0),
    "Oakwood": (1236.4, 126.9), "Cockfosters": (1236.4, 83.8),
    "Highbury & Islington": (1156.1, 723.0), "Seven Sisters": (1334.9, 509.8),
    "Tottenham Hale": (1480.2, 509.8), "Blackhorse Road": (1639.8, 509.8),
    "Walthamstow Central": (1758.0, 509.8),
}


LABELS: dict[str, tuple[str, vector.Point, str]] = {
    "Edgware": ("Edgware", (180, 155), "trailing"),
    "Burnt Oak": ("Burnt Oak", (245, 207), "trailing"),
    "Colindale": ("Colindale", (287, 250), "trailing"),
    "Hendon Central": ("Hendon Central", (397, 334), "leading"),
    "Brent Cross": ("Brent Cross", (447, 385), "leading"),
    "Golders Green": ("Golders Green", (486, 423), "leading"),
    "Hampstead": ("Hampstead", (541, 479), "leading"),
    "Belsize Park": ("Belsize Park", (578, 582), "trailing"),
    "Chalk Farm": ("Chalk Farm", (635, 638), "trailing"),
    "Camden Town": ("Camden Town", (742, 727), "trailing"),
    "High Barnet": ("High Barnet", (848, 96), "trailing"),
    "Totteridge & Whetstone": ("Totteridge & Whetstone", (847, 141), "trailing"),
    "Woodside Park": ("Woodside Park", (847, 184), "trailing"),
    "West Finchley": ("West Finchley", (847, 226), "trailing"),
    "Finchley Central": ("Finchley Central", (847, 278), "trailing"),
    "East Finchley": ("East Finchley", (847, 330), "trailing"),
    "Highgate": ("Highgate", (847, 376), "trailing"),
    "Archway": ("Archway", (847, 450), "trailing"),
    "Tufnell Park": ("Tufnell Park", (878, 512), "leading"),
    "Kentish Town": ("Kentish\nTown", (878, 586), "leading"),
    "Mornington Crescent": ("Mornington\nCrescent", (730, 797), "trailing"),
    "Euston": ("Euston", (713, 851), "trailing"),
    "Mill Hill East": ("Mill Hill East", (810, 252), "trailing"),
    "King's Cross St. Pancras": ("King's Cross\n& St Pancras", (913, 922), "leading"),
    "Caledonian Road": ("Caledonian\nRoad", (967, 779), "leading"),
    "Holloway Road": ("Holloway\nRoad", (1030, 713), "leading"),
    "Arsenal": ("Arsenal", (1089, 647), "leading"),
    "Finsbury Park": ("Finsbury\nPark", (1174, 611), "leading"),
    "Manor House": ("Manor House", (1253, 462), "leading"),
    "Turnpike Lane": ("Turnpike\nLane", (1221, 360), "trailing"),
    "Wood Green": ("Wood Green", (1221, 296), "trailing"),
    "Bounds Green": ("Bounds Green", (1221, 236), "trailing"),
    "Arnos Grove": ("Arnos Grove", (1221, 191), "trailing"),
    "Southgate": ("Southgate", (1221, 149), "trailing"),
    "Oakwood": ("Oakwood", (1221, 111), "trailing"),
    "Cockfosters": ("Cockfosters", (1221, 67), "trailing"),
    "Highbury & Islington": ("Highbury &\nIslington", (1174, 741), "leading"),
    "Seven Sisters": ("Seven\nSisters", (1318, 489), "trailing"),
    "Tottenham Hale": ("Tottenham\nHale", (1480, 535), "centre"),
    "Blackhorse Road": ("Blackhorse\nRoad", (1639, 485), "centre"),
    "Walthamstow Central": ("Walthamstow\nCentral", (1774, 509), "leading"),
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
        is_interchange = station["interchange"] or len(line_ids) > 1 or len(ports) > 1
        primitives: list[dict] = []
        if name in {"Camden Town", "Finchley Central"}:
            # These Northern branches join at the station without creating
            # separate passenger interchange points. Keep every segment port
            # for topology, but render only the visible station point on the
            # shared trunk shown in the official artwork.
            if name == "Camden Town":
                anchor = ports[0]
            primitives.append({
                "kind": "circle",
                "circle": {
                    "centre": vector.rounded(anchor), "radius": 8.5, "outlineWidth": 3.5,
                },
            })
            is_interchange = False
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
            dx, dy = match.tangent
            magnitude = math.hypot(dx, dy) or 1
            normal = (-dy / magnitude * 7, dx / magnitude * 7)
            primitives.append({
                "kind": "tick",
                "tick": {
                    "lineID": line_id,
                    "start": vector.rounded((anchor[0] - normal[0], anchor[1] - normal[1])),
                    "end": vector.rounded((anchor[0] + normal[0], anchor[1] + normal[1])),
                    "width": 3.2,
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
        "identifier": "tube-track-uk.beck.north-connector.v1",
        "geometryStatus": "authored",
        "source": {
            "graphSchemaVersion": graph["schemaVersion"],
            "graphGeneratedAt": graph["generatedAt"],
            "note": (
                "Exact master paths extracted offline from the April 2026 TfL vector map; "
                "north-central station ports and labels manually identified in a fixed 1950x1050 crop."
            ),
        },
        "artworkSize": {"width": 1950, "height": 1050},
        "styles": {
            "routeStrokeWidth": 8.3, "affectedOuterStrokeWidth": 19,
            "affectedKnockoutStrokeWidth": 15, "affectedRouteStrokeWidth": 10,
            "primaryLabelFontSize": 18, "secondaryLabelFontSize": 16, "labelPadding": 2,
        },
        "debugReference": {
            "resourceName": "north-connector-reference-debug", "resourceExtension": "png",
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
