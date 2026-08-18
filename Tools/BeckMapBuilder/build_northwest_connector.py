#!/usr/bin/env python3
"""Compile the northwest Underground fan from the official TfL vector map."""

from __future__ import annotations

import argparse
import json
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import build_central_core_join as vector


vector.CROP_X = 100.0
vector.CROP_Y = 300.0
vector.ARTWORK_WIDTH = 1900.0
vector.ARTWORK_HEIGHT = 1200.0


ROUTES = (
    vector.RouteSpec(
        "bakerloo.northwest-connector.v1", "bakerloo", "68.330383%", 1,
        (("Baker Street", (1582, 1130)), ("Marylebone", (1455, 1052)),
         ("Edgware Road (Bakerloo)", (1340, 1052)), ("Paddington", (1270, 1052)),
         ("Warwick Avenue", (1200, 1052)), ("Maida Vale", (1140, 1045)),
         ("Kilburn Park", (1105, 1010)), ("Queen's Park", (1077, 972)),
         ("Kensal Green", (1043, 930)), ("Willesden Junction", (1043, 875)),
         ("Harlesden", (1043, 830)), ("Stonebridge Park", (1043, 790)),
         ("Wembley Central", (1043, 750)), ("North Wembley", (1043, 710)),
         ("South Kenton", (1043, 635)), ("Kenton", (1043, 574)),
         ("Harrow & Wealdstone", (1043, 485))),
    ),
    vector.RouteSpec(
        "jubilee.northwest-connector.v1", "jubilee", "45.887756%", 2,
        (("Stanmore", (1156, 427)), ("Canons Park", (1156, 485)),
         ("Queensbury", (1156, 532)), ("Kingsbury", (1156, 580)),
         ("Wembley Park", (1182, 650)), ("Neasden", (1228, 696)),
         ("Dollis Hill", (1267, 735)), ("Willesden Green", (1307, 775)),
         ("Kilburn", (1355, 823)), ("West Hampstead", (1400, 868)),
         ("Finchley Road", (1446, 914)), ("Swiss Cottage", (1480, 948)),
         ("St. John's Wood", (1530, 998)), ("Baker Street", (1582, 1085))),
    ),
    vector.RouteSpec(
        "metropolitan.uxbridge-main.northwest-connector.v1", "metropolitan", "51.182556%", 2,
        (("Uxbridge", (121, 498)), ("Hillingdon", (207, 498)),
         ("Ickenham", (300, 498)), ("Ruislip", (365, 498)),
         ("Ruislip Manor", (420, 498)), ("Eastcote", (492, 498)),
         ("Rayners Lane", (563, 555)), ("West Harrow", (655, 636)),
         ("Harrow-on-the-Hill", (824, 636)), ("Northwick Park", (987, 636)),
         ("Preston Road", (1090, 636)), ("Wembley Park", (1138, 644)),
         ("Finchley Road", (1446, 952)), ("Baker Street", (1580, 1086))),
    ),
    vector.RouteSpec(
        "metropolitan.amersham-branch.northwest-connector.v1", "metropolitan", "51.182556%", 3,
        (("Harrow-on-the-Hill", (824, 636)), ("North Harrow", (755, 569)),
         ("Pinner", (715, 530)), ("Northwood Hills", (670, 485)),
         ("Northwood", (635, 450)), ("Moor Park", (578, 401)),
         ("Rickmansworth", (530, 350)), ("Chorleywood", (480, 303)),
         ("Chalfont & Latimer", (226, 270)), ("Amersham", (59, 270))),
    ),
    vector.RouteSpec(
        "metropolitan.chesham-spur.northwest-connector.v1", "metropolitan", "51.182556%", 1,
        (("Chalfont & Latimer", (226, 270)), ("Chesham", (149, 204))),
    ),
    vector.RouteSpec(
        "metropolitan.watford-spur.northwest-connector.v1", "metropolitan", "51.182556%", 4,
        (("Moor Park", (578, 401)), ("Croxley", (570, 340)), ("Watford", (570, 284))),
    ),
    vector.RouteSpec(
        "metropolitan.willesden-service.northwest-connector.v1", "metropolitan", "51.182556%", 2,
        (("Wembley Park", (1138, 644)), ("Willesden Green", (1269, 775)),
         ("Finchley Road", (1446, 952))),
    ),
)


LABEL_LAYOUT: dict[str, tuple[str, vector.Point, str]] = {
    "Baker Street": ("Baker Street", (1610, 1058), "leading"),
    "Marylebone": ("Marylebone", (1455, 1028), "centre"),
    "Edgware Road (Bakerloo)": ("Edgware Road\n(Bakerloo)", (1340, 1074), "centre"),
    "Paddington": ("Paddington", (1270, 1074), "centre"),
    "Warwick Avenue": ("Warwick\nAvenue", (1210, 1074), "leading"),
    "Maida Vale": ("Maida Vale", (1125, 1070), "trailing"),
    "Kilburn Park": ("Kilburn Park", (1088, 1025), "trailing"),
    "Queen's Park": ("Queen's Park", (1060, 985), "trailing"),
    "Kensal Green": ("Kensal Green", (1025, 943), "trailing"),
    "Willesden Junction": ("Willesden Junction", (1025, 880), "trailing"),
    "Harlesden": ("Harlesden", (1025, 834), "trailing"),
    "Stonebridge Park": ("Stonebridge Park", (1025, 794), "trailing"),
    "Wembley Central": ("Wembley Central", (1025, 754), "trailing"),
    "North Wembley": ("North Wembley", (1025, 714), "trailing"),
    "South Kenton": ("South Kenton", (1025, 640), "trailing"),
    "Kenton": ("Kenton", (1025, 578), "trailing"),
    "Harrow & Wealdstone": ("Harrow &\nWealdstone", (1025, 489), "trailing"),
    "Stanmore": ("Stanmore", (1175, 427), "leading"),
    "Canons Park": ("Canons Park", (1175, 485), "leading"),
    "Queensbury": ("Queensbury", (1175, 532), "leading"),
    "Kingsbury": ("Kingsbury", (1175, 580), "leading"),
    "Wembley Park": ("Wembley Park", (1195, 625), "leading"),
    "Neasden": ("Neasden", (1245, 680), "leading"),
    "Dollis Hill": ("Dollis Hill", (1284, 720), "leading"),
    "Willesden Green": ("Willesden Green", (1324, 758), "leading"),
    "Kilburn": ("Kilburn", (1372, 808), "leading"),
    "West Hampstead": ("West Hampstead", (1417, 850), "leading"),
    "Finchley Road": ("Finchley Road", (1465, 915), "leading"),
    "Swiss Cottage": ("Swiss Cottage", (1498, 948), "leading"),
    "St. John's Wood": ("St. John's Wood", (1548, 998), "leading"),
    "Uxbridge": ("Uxbridge", (105, 520), "trailing"),
    "Hillingdon": ("Hillingdon", (207, 478), "centre"),
    "Ickenham": ("Ickenham", (300, 520), "centre"),
    "Ruislip": ("Ruislip", (365, 520), "centre"),
    "Ruislip Manor": ("Ruislip Manor", (420, 478), "centre"),
    "Eastcote": ("Eastcote", (492, 478), "centre"),
    "Rayners Lane": ("Rayners\nLane", (545, 575), "trailing"),
    "West Harrow": ("West\nHarrow", (638, 650), "trailing"),
    "Harrow-on-the-Hill": ("Harrow-\non-the-Hill", (824, 652), "centre"),
    "Northwick Park": ("Northwick\nPark", (970, 617), "trailing"),
    "Preston Road": ("Preston\nRoad", (1108, 617), "leading"),
    "North Harrow": ("North Harrow", (772, 555), "leading"),
    "Pinner": ("Pinner", (732, 516), "leading"),
    "Northwood Hills": ("Northwood Hills", (687, 472), "leading"),
    "Northwood": ("Northwood", (652, 436), "leading"),
    "Moor Park": ("Moor Park", (595, 387), "leading"),
    "Rickmansworth": ("Rickmansworth", (513, 366), "trailing"),
    "Chorleywood": ("Chorleywood", (463, 320), "trailing"),
    "Chalfont & Latimer": ("Chalfont &\nLatimer", (226, 246), "centre"),
    "Amersham": ("Amersham", (42, 286), "trailing"),
    "Chesham": ("Chesham", (132, 188), "trailing"),
    "Croxley": ("Croxley", (588, 340), "leading"),
    "Watford": ("Watford", (588, 284), "leading"),
}


def merge_parts(*parts: tuple[list[str], list[str]]) -> tuple[list[str], list[str]]:
    stations: list[str] = []
    segments: list[str] = []
    for part_stations, part_segments in parts:
        if stations:
            assert stations[-1] == part_stations[0]
            stations.extend(part_stations[1:])
        else:
            stations.extend(part_stations)
        segments.extend(part_segments)
    return stations, segments


def reversed_part(part: tuple[list[str], list[str]]) -> tuple[list[str], list[str]]:
    return list(reversed(part[0])), list(reversed(part[1]))


def sliced_part(part: tuple[list[str], list[str]], start: str, end: str) -> tuple[list[str], list[str]]:
    stations, segments = part
    start_index = stations.index(start)
    end_index = stations.index(end)
    if start_index <= end_index:
        return stations[start_index:end_index + 1], segments[start_index:end_index]
    return reversed_part((stations[end_index:start_index + 1], segments[end_index:start_index]))


def build(svg: Path, graph_path: Path) -> dict:
    root = ET.parse(svg).getroot()
    graph = json.loads(graph_path.read_text())
    stations_by_name = {station["name"]: station for station in graph["stations"]}
    paths: list[dict] = []
    segments: list[dict] = []
    ports_by_station: dict[str, list[tuple[str, vector.Match]]] = {}
    parts: dict[str, tuple[list[str], list[str]]] = {}

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
            paths.append({"id": path_id, "commands": vector.path_commands(vector.path_slice(master, from_match, to_match))})
            segments.append({
                "id": semantic["id"], "lineID": route.line_id,
                "fromStationID": from_id, "toStationID": to_id,
                "fromPort": vector.rounded(from_match.point), "toPort": vector.rounded(to_match.point),
                "pathID": path_id, "pathDirection": "forward", "translation": {"x": 0, "y": 0},
            })
            segment_ids.append(semantic["id"])
        parts[route.identifier] = (station_ids, segment_ids)

    names_to_ids = {name: station["id"] for name, station in stations_by_name.items()}
    main = parts["metropolitan.uxbridge-main.northwest-connector.v1"]
    amersham_branch = parts["metropolitan.amersham-branch.northwest-connector.v1"]
    chesham_spur = parts["metropolitan.chesham-spur.northwest-connector.v1"]
    watford_spur = parts["metropolitan.watford-spur.northwest-connector.v1"]
    willesden_service = parts["metropolitan.willesden-service.northwest-connector.v1"]
    harrow = names_to_ids["Harrow-on-the-Hill"]
    wembley = names_to_ids["Wembley Park"]
    finchley = names_to_ids["Finchley Road"]
    baker = names_to_ids["Baker Street"]
    chalfont = names_to_ids["Chalfont & Latimer"]
    moor_park = names_to_ids["Moor Park"]

    direct_tail = sliced_part(main, harrow, baker)
    amersham_tail = merge_parts(
        sliced_part(main, harrow, wembley),
        willesden_service,
        sliced_part(main, finchley, baker),
    )
    route_parts = {
        "bakerloo.northwest-connector.v1": parts["bakerloo.northwest-connector.v1"],
        "jubilee.northwest-connector.v1": parts["jubilee.northwest-connector.v1"],
        "metropolitan.uxbridge.northwest-connector.v1": main,
        "metropolitan.amersham.northwest-connector.v1": merge_parts(reversed_part(amersham_branch), amersham_tail),
        "metropolitan.chesham.northwest-connector.v1": merge_parts(
            reversed_part(chesham_spur),
            reversed_part(sliced_part(amersham_branch, harrow, chalfont)),
            direct_tail,
        ),
        "metropolitan.watford.northwest-connector.v1": merge_parts(
            reversed_part(watford_spur),
            reversed_part(sliced_part(amersham_branch, harrow, moor_park)),
            direct_tail,
        ),
    }
    routes = [
        {"id": identifier, "lineID": identifier.split(".")[0], "stationIDs": value[0], "segmentIDs": value[1]}
        for identifier, value in route_parts.items()
    ]

    markers: list[dict] = []
    labels: list[dict] = []
    for name, line_matches in ports_by_station.items():
        station = stations_by_name[name]
        line_ids = sorted({line_id for line_id, _ in line_matches})
        ports = vector.unique_points((match.point for _, match in line_matches), tolerance=3)
        anchor = ports[0]
        is_interchange = station["interchange"] or len(line_ids) > 1 or len(ports) > 1
        primitives: list[dict] = []
        if is_interchange:
            for port in ports:
                if math.dist(port, anchor) > 4:
                    primitives.append({"kind": "connector", "connector": {
                        "start": vector.rounded(anchor), "end": vector.rounded(port), "width": 7.5,
                    }})
            for point in vector.unique_points([anchor, *ports], tolerance=7):
                primitives.append({"kind": "circle", "circle": {
                    "centre": vector.rounded(point), "radius": 8.5, "outlineWidth": 3.5,
                }})
        else:
            line_id, match = line_matches[0]
            dx, dy = match.tangent
            magnitude = math.hypot(dx, dy) or 1
            normal = (-dy / magnitude * 7, dx / magnitude * 7)
            primitives.append({"kind": "tick", "tick": {
                "lineID": line_id,
                "start": vector.rounded((anchor[0] - normal[0], anchor[1] - normal[1])),
                "end": vector.rounded((anchor[0] + normal[0], anchor[1] + normal[1])), "width": 3.2,
            }})
        markers.append({
            "stationID": station["id"], "name": station["name"], "lineIDs": line_ids,
            "anchor": vector.rounded(anchor), "hitRadius": 24, "primitives": primitives,
        })
        text, position, alignment = LABEL_LAYOUT[name]
        labels.append({
            "id": f"label.{station['id']}", "stationID": station["id"], "text": text,
            "position": vector.rounded(position), "alignment": alignment,
            "rotationDegrees": 0, "priority": 10 if is_interchange else 5,
        })

    return {
        "schemaVersion": {"major": 1, "minor": 2},
        "identifier": "tube-track-uk.beck.northwest-connector.v1", "geometryStatus": "authored",
        "source": {
            "graphSchemaVersion": graph["schemaVersion"], "graphGeneratedAt": graph["generatedAt"],
            "note": "Exact master paths extracted offline from the April 2026 TfL vector map; northwest branches manually ported in a fixed 1900x1200 crop.",
        },
        "artworkSize": {"width": 1900, "height": 1200},
        "styles": {
            "routeStrokeWidth": 8.3, "affectedOuterStrokeWidth": 19,
            "affectedKnockoutStrokeWidth": 15, "affectedRouteStrokeWidth": 10,
            "primaryLabelFontSize": 18, "secondaryLabelFontSize": 16, "labelPadding": 2,
        },
        "debugReference": {
            "resourceName": "northwest-connector-reference-debug", "resourceExtension": "png", "geometryOpacity": 0.52,
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
