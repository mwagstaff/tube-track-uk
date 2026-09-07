#!/usr/bin/env python3
"""Compile the western Underground fan from the official TfL vector map."""

from __future__ import annotations

import argparse
import json
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import build_central_core_join as vector


vector.CROP_X = 100.0
vector.CROP_Y = 600.0
vector.ARTWORK_WIDTH = 1900.0
vector.ARTWORK_HEIGHT = 1900.0


def p(x: float, y: float) -> vector.Point:
    """Convert coordinates from the 144 dpi reference render into this crop."""
    return (x * 2 - vector.CROP_X, y * 2 - vector.CROP_Y)


ROUTES = (
    vector.RouteSpec(
        "central.ealing.western-fan.v1", "central", "87.979126%", 4,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Ealing Broadway", (300, 829)), ("West Acton", (402, 842)),
            ("North Acton", (499, 842)), ("East Acton", (529, 842)),
            ("White City", (570, 842)), ("Shepherd's Bush (Central)", (662, 842)),
            ("Holland Park", (690, 842)), ("Notting Hill Gate", (708, 842)),
            ("Queensway", (734, 842)), ("Lancaster Gate", (797, 800)),
            ("Marble Arch", (840, 798)), ("Bond Street", (884, 798)),
            ("Oxford Circus", (900, 798)),
        )),
    ),
    vector.RouteSpec(
        "central.west-ruislip-branch.western-fan.v1", "central", "87.979126%", 5,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("West Ruislip", (234, 364)), ("Ruislip Gardens", (234, 405)),
            ("South Ruislip", (234, 455)), ("Northolt", (234, 510)),
            ("Greenford", (260, 623)), ("Perivale", (300, 675)),
            ("Hanger Lane", (353, 716)), ("North Acton", (499, 842)),
        )),
    ),
    vector.RouteSpec(
        "piccadilly.uxbridge.western-fan.v1", "piccadilly", "17.060852%", 0,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Uxbridge", (80, 402)), ("Hillingdon", (153, 402)),
            ("Ickenham", (200, 402)), ("Ruislip", (235, 402)),
            ("Ruislip Manor", (270, 402)), ("Eastcote", (320, 402)),
            ("Rayners Lane", (334, 428)), ("South Harrow", (334, 500)),
            ("Sudbury Hill", (334, 545)), ("Sudbury Town", (334, 600)),
            ("Alperton", (334, 640)), ("Park Royal", (334, 720)),
            ("North Ealing", (334, 780)), ("Ealing Common", (322, 887)),
            ("Acton Town", (354, 920)),
        )),
    ),
    vector.RouteSpec(
        "piccadilly.trunk.western-fan.v1", "piccadilly", "17.060852%", 1,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Acton Town", (354, 920)),
            ("Turnham Green", (460, 920)),
            ("Hammersmith (Dist&Picc Line)", (586, 920)),
            ("Barons Court", (620, 920)), ("Earl's Court", (688, 920)),
            ("Gloucester Road", (725, 920)), ("South Kensington", (762, 920)),
            ("Knightsbridge", (800, 895)), ("Hyde Park Corner", (840, 870)),
            ("Green Park", (865, 850)),
        )),
    ),
    vector.RouteSpec(
        "district.ealing.western-fan.v1", "district", "8.070374%", 8,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Ealing Broadway", (300, 835)), ("Ealing Common", (322, 887)),
            ("Acton Town", (354, 928)), ("Chiswick Park", (383, 935)),
            ("Turnham Green", (460, 935)), ("Stamford Brook", (500, 935)),
            ("Ravenscourt Park", (542, 935)),
            ("Hammersmith (Dist&Picc Line)", (586, 935)),
            ("Barons Court", (620, 935)), ("West Kensington", (650, 935)),
            ("Earl's Court", (688, 935)), ("Gloucester Road", (725, 935)),
            ("South Kensington", (762, 935)), ("Sloane Square", (822, 935)),
            ("Victoria", (865, 935)), ("St. James's Park", (900, 935)),
            ("Westminster", (937, 935)), ("Embankment", (995, 935)),
        )),
    ),
    vector.RouteSpec(
        "district.richmond-branch.western-fan.v1", "district", "8.070374%", 3,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Richmond", (286, 1075)), ("Kew Gardens", (323, 1048)),
            ("Gunnersbury", (382, 987)), ("Turnham Green", (460, 935)),
        )),
    ),
    vector.RouteSpec(
        "district.olympia-branch.western-fan.v1", "district", "8.070374%", 5,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Kensington (Olympia)", (668, 882)), ("Earl's Court", (688, 935)),
        )),
    ),
    vector.RouteSpec(
        "district.wimbledon-branch.western-fan.v1", "district", "8.070374%", 7,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Earl's Court", (688, 935)), ("West Brompton", (668, 975)),
            ("Fulham Broadway", (668, 1022)), ("Parsons Green", (668, 1062)),
            ("Putney Bridge", (668, 1108)), ("East Putney", (668, 1128)),
            ("Southfields", (668, 1148)), ("Wimbledon Park", (668, 1162)),
            ("Wimbledon", (680, 1175)),
        )),
    ),
    vector.RouteSpec(
        "district.edgware-branch.western-fan.v1", "district", "8.070374%", 4,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Earl's Court", (688, 935)), ("High Street Kensington", (710, 862)),
            ("Notting Hill Gate", (710, 842)), ("Bayswater", (710, 748)),
            ("Paddington", (730, 705)), ("Edgware Road (Circle Line)", (745, 700)),
        )),
    ),
    vector.RouteSpec(
        "circle.western.western-fan.v1", "circle", "98.728943%", 1,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Hammersmith (H&C Line)", (586, 900)), ("Goldhawk Road", (586, 872)),
            ("Shepherd's Bush Market", (586, 852)), ("Wood Lane", (586, 825)),
            ("Latimer Road", (620, 755)), ("Ladbroke Grove", (645, 730)),
            ("Westbourne Park", (670, 705)), ("Royal Oak", (705, 690)),
            ("Paddington (H&C Line)-Underground", (730, 690)),
        )),
    ),
    vector.RouteSpec(
        "circle.edgware-branch.western-fan.v1", "circle", "98.728943%", 1,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Gloucester Road", (725, 932)), ("High Street Kensington", (710, 870)),
            ("Notting Hill Gate", (710, 842)), ("Bayswater", (710, 748)),
            ("Paddington", (730, 705)), ("Edgware Road (Circle Line)", (745, 700)),
        )),
    ),
    vector.RouteSpec(
        "circle.southern-trunk.western-fan.v1", "circle", "98.728943%", 1,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Gloucester Road", (725, 932)), ("South Kensington", (762, 932)),
            ("Sloane Square", (822, 932)), ("Victoria", (865, 932)),
            ("St. James's Park", (900, 932)), ("Westminster", (937, 932)),
            ("Embankment", (995, 932)),
        )),
    ),
    vector.RouteSpec(
        "hammersmith-city.western.western-fan.v1", "hammersmith-city", "93.824768%", 1,
        tuple((name, p(x, y)) for name, (x, y) in (
            ("Hammersmith (H&C Line)", (586, 895)), ("Goldhawk Road", (586, 866)),
            ("Shepherd's Bush Market", (586, 846)), ("Wood Lane", (586, 820)),
            ("Latimer Road", (616, 750)), ("Ladbroke Grove", (641, 725)),
            ("Westbourne Park", (666, 700)), ("Royal Oak", (701, 684)),
            ("Paddington (H&C Line)-Underground", (730, 700)),
        )),
    ),
)


LABEL_OFFSETS: dict[str, tuple[float, float, str]] = {
    "Ealing Broadway": (-10, -22, "trailing"), "West Acton": (0, -22, "centre"),
    "North Acton": (0, 25, "centre"), "East Acton": (0, -22, "centre"),
    "White City": (0, -25, "centre"), "Shepherd's Bush (Central)": (0, -28, "centre"),
    "Holland Park": (0, 25, "centre"), "Notting Hill Gate": (15, -20, "leading"),
    "Queensway": (0, 25, "centre"), "Lancaster Gate": (0, 25, "centre"),
    "Marble Arch": (0, -22, "centre"), "Bond Street": (-15, -25, "trailing"),
    "Oxford Circus": (16, 18, "leading"), "West Ruislip": (-15, 0, "trailing"),
    "Ruislip Gardens": (-15, 0, "trailing"), "South Ruislip": (-15, 0, "trailing"),
    "Northolt": (-15, 0, "trailing"), "Greenford": (15, 0, "leading"),
    "Perivale": (15, 0, "leading"), "Hanger Lane": (15, -12, "leading"),
    "Uxbridge": (-15, 0, "trailing"), "Hillingdon": (0, -22, "centre"),
    "Ickenham": (0, 22, "centre"), "Ruislip": (0, 22, "centre"),
    "Ruislip Manor": (0, -22, "centre"), "Eastcote": (15, 0, "leading"),
    "Rayners Lane": (15, 0, "leading"), "South Harrow": (15, 0, "leading"),
    "Sudbury Hill": (15, 0, "leading"), "Sudbury Town": (15, 0, "leading"),
    "Alperton": (15, 0, "leading"), "Park Royal": (-15, 0, "trailing"),
    "North Ealing": (15, 0, "leading"), "Ealing Common": (-18, 0, "trailing"),
    "Acton Town": (15, 8, "leading"), "Chiswick Park": (0, 23, "centre"),
    "Turnham Green": (0, 23, "centre"), "Stamford Brook": (0, 23, "centre"),
    "Ravenscourt Park": (0, 23, "centre"), "Hammersmith (Dist&Picc Line)": (0, -25, "centre"),
    "Barons Court": (0, -23, "centre"), "West Kensington": (0, 23, "centre"),
    "Earl's Court": (18, 10, "leading"), "Richmond": (0, 24, "centre"),
    "Kew Gardens": (15, 8, "leading"), "Gunnersbury": (15, 0, "leading"),
    "Kensington (Olympia)": (-18, 0, "trailing"), "West Brompton": (-18, 0, "trailing"),
    "Fulham Broadway": (-18, 0, "trailing"), "Parsons Green": (-18, 0, "trailing"),
    "Putney Bridge": (-18, 0, "trailing"), "East Putney": (-18, 0, "trailing"),
    "Southfields": (-18, 0, "trailing"), "Wimbledon Park": (-18, 0, "trailing"),
    "Wimbledon": (-18, 0, "trailing"), "High Street Kensington": (16, 0, "leading"),
    "Gloucester Road": (16, 0, "leading"),
    "South Kensington": (0, 24, "centre"), "Sloane Square": (0, -23, "centre"),
    "Victoria": (-15, -24, "trailing"), "St. James's Park": (0, 23, "centre"),
    "Westminster": (0, -23, "centre"), "Embankment": (-15, 16, "trailing"),
    "Knightsbridge": (15, 0, "leading"), "Hyde Park Corner": (-15, 0, "trailing"),
    "Green Park": (15, -14, "leading"),
    "Bayswater": (16, 0, "leading"), "Paddington": (16, 10, "leading"),
    "Edgware Road (Circle Line)": (16, 0, "leading"), "Hammersmith (H&C Line)": (-18, 0, "trailing"),
    "Goldhawk Road": (16, 0, "leading"), "Shepherd's Bush Market": (16, 0, "leading"),
    "Wood Lane": (16, 0, "leading"), "Latimer Road": (16, 0, "leading"),
    "Ladbroke Grove": (16, 0, "leading"), "Westbourne Park": (16, 0, "leading"),
    "Royal Oak": (-16, -10, "trailing"), "Paddington (H&C Line)-Underground": (16, 18, "leading"),
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

    # The trunk paths are shared by several physical branches. Composite routes
    # preserve real passenger journeys across those authored junctions.
    central_trunk = parts["central.ealing.western-fan.v1"]
    central_ruislip = parts["central.west-ruislip-branch.western-fan.v1"]
    district_trunk = parts["district.ealing.western-fan.v1"]
    district_richmond = parts["district.richmond-branch.western-fan.v1"]
    district_olympia = parts["district.olympia-branch.western-fan.v1"]
    district_wimbledon = parts["district.wimbledon-branch.western-fan.v1"]
    route_parts = {
        "central.ealing.western-fan.v1": central_trunk,
        "central.west-ruislip.western-fan.v1": merge_parts(
            central_ruislip,
            (central_trunk[0][2:], central_trunk[1][2:]),
        ),
        "piccadilly.uxbridge.western-fan.v1": parts["piccadilly.uxbridge.western-fan.v1"],
        "piccadilly.trunk.western-fan.v1": parts["piccadilly.trunk.western-fan.v1"],
        "district.ealing.western-fan.v1": district_trunk,
        "district.richmond.western-fan.v1": merge_parts(district_richmond, (district_trunk[0][4:], district_trunk[1][4:])),
        "district.olympia.western-fan.v1": district_olympia,
        "district.wimbledon.western-fan.v1": district_wimbledon,
        "district.edgware.western-fan.v1": parts["district.edgware-branch.western-fan.v1"],
        "circle.western.western-fan.v1": parts["circle.western.western-fan.v1"],
        "circle.edgware.western-fan.v1": parts["circle.edgware-branch.western-fan.v1"],
        "circle.southern-trunk.western-fan.v1": parts["circle.southern-trunk.western-fan.v1"],
        "hammersmith-city.western.western-fan.v1": parts["hammersmith-city.western.western-fan.v1"],
    }
    routes = [{"id": key, "lineID": key.split(".")[0], "stationIDs": value[0], "segmentIDs": value[1]} for key, value in route_parts.items()]

    markers: list[dict] = []
    labels: list[dict] = []
    ordinary_shared_stations = {
        "Goldhawk Road", "Shepherd's Bush Market", "Latimer Road",
        "Ladbroke Grove", "Westbourne Park", "Royal Oak",
    }

    def tick_primitive(line_id: str, match: vector.Match) -> dict:
        dx, dy = match.tangent
        magnitude = math.hypot(dx, dy) or 1
        normal = (-dy / magnitude * 7, dx / magnitude * 7)
        return {"kind": "tick", "tick": {
            "lineID": line_id,
            "start": vector.rounded((match.point[0] - normal[0], match.point[1] - normal[1])),
            "end": vector.rounded((match.point[0] + normal[0], match.point[1] + normal[1])), "width": 3.2,
        }}

    for name, line_matches in ports.items():
        station = stations_by_name[name]
        line_ids = sorted({line_id for line_id, _ in line_matches})
        points = vector.unique_points((match.point for _, match in line_matches), tolerance=4)
        anchor = points[0]
        interchange = station["interchange"] or len(line_ids) > 1 or len(points) > 1
        primitives: list[dict] = []

        if name == "North Acton":
            # The Ruislip branch joins west of the platform. North Acton itself
            # remains a single Central-line through station.
            line_id, main_match = line_matches[0]
            anchor = main_match.point
            primitives = [tick_primitive(line_id, main_match)]
            interchange = False
        elif name == "Hammersmith (H&C Line)":
            # Circle and Hammersmith & City terminate at one physical station.
            # Centre one roundel across the two compact parallel lanes.
            representatives: dict[str, vector.Match] = {}
            for line_id, match in line_matches:
                representatives.setdefault(line_id, match)
            anchor = tuple(
                sum(match.point[i] for match in representatives.values())
                / len(representatives)
                for i in (0, 1)
            )
            primitives = [{"kind": "circle", "circle": {
                "centre": vector.rounded(anchor), "radius": 8.5, "outlineWidth": 3.5,
            }}]
        elif name in ordinary_shared_stations:
            # Circle and Hammersmith & City share these stations; the parallel
            # artwork does not imply an interchange between separate platforms.
            representatives: dict[str, vector.Match] = {}
            for line_id, match in line_matches:
                representatives.setdefault(line_id, match)
            anchor = tuple(sum(match.point[i] for match in representatives.values()) / len(representatives) for i in (0, 1))
            primitives = [tick_primitive(line_id, match) for line_id, match in representatives.items()]
            interchange = False
        elif name in {"White City", "Wood Lane"}:
            # These are distinct stations connected by an explicitly authored
            # short walking interchange, rather than a shared platform.
            if name == "Wood Lane":
                anchor = tuple(sum(point[i] for point in points) / len(points) for i in (0, 1))
            primitives = [{"kind": "circle", "circle": {
                "centre": vector.rounded(anchor), "radius": 8.5, "outlineWidth": 3.5,
            }}]
            interchange = True
        elif name in {"Turnham Green", "Earl's Court"}:
            # Multiple District branches meet one District platform axis. Keep
            # only one authored port per line for the passenger interchange.
            # At Turnham Green the Richmond branch joins west of the District
            # platform and must remain a hidden topology port.
            representatives: dict[str, vector.Match] = {}
            for line_id, match in line_matches:
                representatives.setdefault(line_id, match)
            representative_points = [match.point for match in representatives.values()]
            anchor = representative_points[0]
            for point in representative_points[1:]:
                primitives.append({"kind": "connector", "connector": {
                    "start": vector.rounded(anchor), "end": vector.rounded(point), "width": 7.5,
                }})
            for point in representative_points:
                primitives.append({"kind": "circle", "circle": {
                    "centre": vector.rounded(point), "radius": 8.5, "outlineWidth": 3.5,
                }})
            interchange = True
        elif interchange:
            for point in points[1:]:
                if math.dist(anchor, point) > 5:
                    primitives.append({"kind": "connector", "connector": {"start": vector.rounded(anchor), "end": vector.rounded(point), "width": 7.5}})
            for point in vector.unique_points([anchor, *points], tolerance=7):
                primitives.append({"kind": "circle", "circle": {"centre": vector.rounded(point), "radius": 8.5, "outlineWidth": 3.5}})
        else:
            line_id, match = line_matches[0]
            primitives.append(tick_primitive(line_id, match))

        if name == "White City":
            wood_lane_matches = ports["Wood Lane"]
            wood_lane_points = vector.unique_points((match.point for _, match in wood_lane_matches), tolerance=4)
            wood_lane_anchor = tuple(sum(point[i] for point in wood_lane_points) / len(wood_lane_points) for i in (0, 1))
            primitives.insert(0, {"kind": "walkingConnector", "walkingConnector": {
                "start": vector.rounded(anchor), "end": vector.rounded(wood_lane_anchor), "width": 4.5,
            }})
        markers.append({"stationID": station["id"], "name": station["name"], "lineIDs": line_ids, "anchor": vector.rounded(anchor), "hitRadius": 24, "primitives": primitives})
        dx, dy, alignment = LABEL_OFFSETS[name]
        labels.append({
            "id": f"label.{station['id']}", "stationID": station["id"], "text": station["name"],
            "position": vector.rounded((anchor[0] + dx, anchor[1] + dy)), "alignment": alignment,
            "rotationDegrees": 0, "priority": 10 if interchange else 5,
        })

    return {
        "schemaVersion": {"major": 1, "minor": 2},
        "identifier": "tube-track-uk.beck.western-fan.v1", "geometryStatus": "authored",
        "source": {"graphSchemaVersion": graph["schemaVersion"], "graphGeneratedAt": graph["generatedAt"], "note": "Exact master paths extracted offline from the April 2026 TfL vector map; western branches manually ported in a fixed 1900x1900 crop."},
        "artworkSize": {"width": 1900, "height": 1900},
        "styles": {"routeStrokeWidth": 8.3, "affectedOuterStrokeWidth": 19, "affectedKnockoutStrokeWidth": 15, "affectedRouteStrokeWidth": 10, "primaryLabelFontSize": 18, "secondaryLabelFontSize": 16, "labelPadding": 2},
        "debugReference": {"resourceName": "western-fan-reference-debug", "resourceExtension": "png", "geometryOpacity": 0.52},
        "paths": paths, "segments": segments, "stationMarkers": markers, "labels": labels, "routes": routes,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--svg", required=True, type=Path)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(build(args.svg, args.graph), indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
