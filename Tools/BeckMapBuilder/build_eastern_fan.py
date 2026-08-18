#!/usr/bin/env python3
"""Compile the eastern Underground fan from the official TfL vector map."""

from __future__ import annotations

import argparse
import json
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import build_central_core_join as vector


vector.CROP_X = 2750.0
vector.CROP_Y = 350.0
vector.ARTWORK_WIDTH = 1500.0
vector.ARTWORK_HEIGHT = 1800.0


def p(x: float, y: float) -> vector.Point:
    """Convert a point from the 144 dpi reference render into crop space."""
    return (x * 2 - vector.CROP_X, y * 2 - vector.CROP_Y)


ROUTES = (
    vector.RouteSpec(
        "central.epping.eastern-fan.v1", "central", "87.979126%", 4,
        (("Stratford", p(1610, 635)), ("Leyton", p(1605, 590)),
         ("Leytonstone", p(1660, 534)), ("Snaresbrook", p(1660, 484)),
         ("South Woodford", p(1660, 454)), ("Woodford", p(1660, 405)),
         ("Buckhurst Hill", p(1660, 367)), ("Loughton", p(1673, 331)),
         ("Debden", p(1695, 309)), ("Theydon Bois", p(1715, 289)),
         ("Epping", p(1745, 259))),
    ),
    vector.RouteSpec(
        "central.hainault-loop.eastern-fan.v1", "central", "87.979126%", 3,
        (("Leytonstone", p(1660, 511)), ("Wanstead", p(1680, 503)),
         ("Redbridge", p(1708, 503)), ("Gants Hill", p(1733, 503)),
         ("Newbury Park", p(1759, 494)), ("Barkingside", p(1759, 465)),
         ("Fairlop", p(1759, 435)), ("Hainault", p(1759, 410)),
         ("Grange Hill", p(1735, 383)), ("Chigwell", p(1708, 383)),
         ("Roding Valley", p(1681, 383)), ("Woodford", p(1660, 392))),
    ),
    vector.RouteSpec(
        "district.eastern-fan.v1", "district", "8.070374%", 8,
        (("Mile End", p(1455, 779)), ("Bow Road", p(1510, 779)),
         ("Bromley-by-Bow", p(1580, 779)), ("West Ham", p(1627, 779)),
         ("Plaistow", p(1668, 779)), ("Upton Park", p(1710, 779)),
         ("East Ham", p(1747, 779)), ("Barking", p(1771, 779)),
         ("Upney", p(1814, 753)), ("Becontree", p(1837, 737)),
         ("Dagenham Heathway", p(1857, 713)), ("Dagenham East", p(1883, 687)),
         ("Elm Park", p(1904, 666)), ("Hornchurch", p(1931, 639)),
         ("Upminster Bridge", p(1947, 623)), ("Upminster", p(1969, 601))),
    ),
    vector.RouteSpec(
        "hammersmith-city.eastern-fan.v1", "hammersmith-city", "93.824768%", 1,
        (("Mile End", p(1455, 771)), ("Bow Road", p(1510, 771)),
         ("Bromley-by-Bow", p(1580, 771)), ("West Ham", p(1627, 771)),
         ("Plaistow", p(1668, 771)), ("Upton Park", p(1710, 771)),
         ("East Ham", p(1747, 771)), ("Barking", p(1771, 771))),
    ),
    vector.RouteSpec(
        "jubilee.eastern-fan.v1", "jubilee", "45.887756%", 2,
        (("North Greenwich", p(1570, 984)), ("Canning Town", p(1627, 882)),
         ("West Ham", p(1627, 771)), ("Stratford", p(1627, 635))),
    ),
)


LABEL_OFFSETS: dict[str, tuple[float, float, str]] = {
    "Stratford": (20, 16, "leading"), "Leyton": (-18, 8, "trailing"),
    "Leytonstone": (18, 8, "leading"), "Snaresbrook": (-18, 5, "trailing"),
    "South Woodford": (-18, 5, "trailing"), "Woodford": (-18, 5, "trailing"),
    "Buckhurst Hill": (-18, 5, "trailing"), "Loughton": (-18, 5, "trailing"),
    "Debden": (-18, 5, "trailing"), "Theydon Bois": (-18, 5, "trailing"),
    "Epping": (-18, -12, "trailing"), "Wanstead": (0, 24, "centre"),
    "Redbridge": (0, -20, "centre"), "Gants Hill": (0, 24, "centre"),
    "Newbury Park": (18, 5, "leading"), "Barkingside": (18, 5, "leading"),
    "Fairlop": (18, 5, "leading"), "Hainault": (18, 5, "leading"),
    "Grange Hill": (0, -20, "centre"), "Chigwell": (0, 24, "centre"),
    "Roding Valley": (0, -22, "centre"), "Mile End": (-18, -18, "trailing"),
    "Bow Road": (0, 24, "centre"), "Bromley-by-Bow": (0, 24, "centre"),
    "West Ham": (18, -20, "leading"), "Plaistow": (0, 24, "centre"),
    "Upton Park": (0, -22, "centre"), "East Ham": (10, 24, "leading"),
    "Barking": (0, -22, "centre"), "Upney": (18, 5, "leading"),
    "Becontree": (18, 5, "leading"), "Dagenham Heathway": (18, 5, "leading"),
    "Dagenham East": (18, 5, "leading"), "Elm Park": (18, 5, "leading"),
    "Hornchurch": (18, 5, "leading"), "Upminster Bridge": (18, 5, "leading"),
    "Upminster": (18, 10, "leading"), "North Greenwich": (-18, 5, "trailing"),
    "Canning Town": (18, 5, "leading"),
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
    ports: dict[str, list[tuple[str, vector.Match]]] = {}
    parts: dict[str, tuple[list[str], list[str]]] = {}

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
        parts[route.identifier] = (station_ids, segment_ids)

    main = parts["central.epping.eastern-fan.v1"]
    loop = parts["central.hainault-loop.eastern-fan.v1"]
    names_to_ids = {name: station["id"] for name, station in stations_by_name.items()}
    stratford = names_to_ids["Stratford"]
    leytonstone = names_to_ids["Leytonstone"]
    woodford = names_to_ids["Woodford"]
    hainault = names_to_ids["Hainault"]
    route_parts = {
        "central.epping.eastern-fan.v1": main,
        "central.hainault-via-newbury-park.eastern-fan.v1": merge_parts(
            sliced_part(main, stratford, leytonstone), sliced_part(loop, leytonstone, hainault),
        ),
        "central.hainault-via-woodford.eastern-fan.v1": merge_parts(
            sliced_part(main, stratford, woodford), reversed_part(sliced_part(loop, hainault, woodford)),
        ),
        "district.eastern-fan.v1": parts["district.eastern-fan.v1"],
        "hammersmith-city.eastern-fan.v1": parts["hammersmith-city.eastern-fan.v1"],
        "jubilee.eastern-fan.v1": parts["jubilee.eastern-fan.v1"],
    }
    routes = [
        {"id": key, "lineID": key.split(".")[0], "stationIDs": value[0], "segmentIDs": value[1]}
        for key, value in route_parts.items()
    ]

    ordinary_shared = {"Bow Road", "Bromley-by-Bow", "Plaistow", "Upton Park", "East Ham"}
    forced_interchanges = {"Canning Town", "Upminster"}

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
        interchange = station["interchange"] or len(line_ids) > 1 or len(points) > 1 or name in forced_interchanges
        primitives: list[dict] = []

        if name in ordinary_shared:
            representatives: dict[str, vector.Match] = {}
            for line_id, match in line_matches:
                representatives.setdefault(line_id, match)
            anchor = tuple(sum(match.point[i] for match in representatives.values()) / len(representatives) for i in (0, 1))
            primitives = [tick(line_id, match) for line_id, match in representatives.items()]
            interchange = False
        elif name in {"Leytonstone", "Woodford"}:
            # Each Central branch peels away from the platform after the station.
            # The Central path itself joins the branch port to the platform, so
            # an interchange connector here would be both redundant and wrong.
            # ROUTES authors the Epping trunk before the loop, so its match is
            # the visible station position and the later match is the fork port.
            main_match = line_matches[0][1]
            anchor = main_match.point
            primitives.append({"kind": "circle", "circle": {
                "centre": vector.rounded(anchor), "radius": 8.5, "outlineWidth": 3.5,
            }})
            interchange = True
        elif interchange:
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
        "identifier": "tube-track-uk.beck.eastern-fan.v1", "geometryStatus": "authored",
        "source": {
            "graphSchemaVersion": graph["schemaVersion"], "graphGeneratedAt": graph["generatedAt"],
            "note": "Exact master paths extracted offline from the April 2026 TfL vector map; eastern branches manually ported in a fixed 1500x1800 crop.",
        },
        "artworkSize": {"width": 1500, "height": 1800},
        "styles": {
            "routeStrokeWidth": 8.3, "affectedOuterStrokeWidth": 19,
            "affectedKnockoutStrokeWidth": 15, "affectedRouteStrokeWidth": 10,
            "primaryLabelFontSize": 18, "secondaryLabelFontSize": 16, "labelPadding": 2,
        },
        "debugReference": {
            "resourceName": "eastern-fan-reference-debug", "resourceExtension": "png", "geometryOpacity": 0.52,
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
