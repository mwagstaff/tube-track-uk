#!/usr/bin/env python3
"""Compile DLR and Elizabeth artwork from the official TfL vector paths.

The graph describes service adjacency, not diagram geometry.  This module keeps
those concerns separate: every semantic rail segment is backed by an exact
slice (or an exact, endpoint-joined sequence of slices) from the official map.
"""

from __future__ import annotations

import math
import xml.etree.ElementTree as ET
from dataclasses import dataclass

import build_central_core_join as vector


Point = vector.Point


@dataclass(frozen=True)
class Fingerprint:
    key: int
    curve_count: int
    start: Point
    end: Point


@dataclass(frozen=True)
class PieceSpec:
    master: int
    start: Point
    end: Point


@dataclass(frozen=True)
class PortSpec:
    station_id: str
    approximate: Point


@dataclass(frozen=True)
class TraceSpec:
    identifier: str
    line_id: str
    pieces: tuple[PieceSpec, ...]
    ports: tuple[PortSpec, ...]


DLR_COLOUR = "14.312744%"
ELIZABETH_COLOUR = "40.991211%"
OFFICIAL_OUTER_STROKE_WIDTH = 2.072
JOIN_TOLERANCE = 0.75
PORT_SNAP_TOLERANCE = 10.0


DLR_FINGERPRINTS = (
    Fingerprint(1, 3, (3306.672, 1743.953), (3280.766, 1676.141)),
    Fingerprint(2, 5, (3280.781, 1698.984), (3070.859, 1161.188)),
    Fingerprint(3, 6, (3335.375, 1758.219), (3494.422, 2253.922)),
    Fingerprint(4, 3, (3027.281, 2456.937), (3252.750, 1271.032)),
    Fingerprint(5, 3, (3001.516, 1774.625), (3027.266, 1842.297)),
    Fingerprint(6, 3, (2747.703, 1758.203), (2573.000, 1733.031)),
    Fingerprint(7, 3, (2947.125, 1758.203), (3016.781, 1789.891)),
    Fingerprint(8, 3, (3358.906, 1758.219), (3289.016, 1726.297)),
    Fingerprint(9, 12, (2355.375, 1652.422), (3627.875, 2165.031)),
)


ELIZABETH_FINGERPRINTS = (
    Fingerprint(1, 11, (4009.336, 765.762), (2871.047, 1448.609)),
    Fingerprint(2, 6, (2871.047, 1448.609), (2759.031, 1516.281)),
    Fingerprint(3, 3, (3319.141, 1171.047), (3360.531, 1153.437)),
    Fingerprint(4, 6, (342.719, 1657.188), (160.281, 960.391)),
    Fingerprint(5, 6, (292.016, 2078.172), (176.813, 2287.422)),
    Fingerprint(6, 14, (292.000, 2257.891), (1458.781, 1474.985)),
    Fingerprint(7, 1, (292.000, 1715.891), (292.000, 1685.344)),
    Fingerprint(8, 42, (1452.578, 1474.985), (3563.891, 2319.344)),
    Fingerprint(9, 5, (3005.578, 1849.344), (3060.891, 1867.938)),
)


def p(master: int, start: Point, end: Point) -> PieceSpec:
    return PieceSpec(master, start, end)


def s(station_id: str, x: float, y: float) -> PortSpec:
    return PortSpec(station_id, (x, y))


DLR_TRACES = (
    TraceSpec(
        "dlr.bank-beckton.official.v1", "dlr",
        (p(9, (2355.375, 1652.422), (3627.875, 2165.031)),),
        (
            s("940GZZDLBNK", 2355.375, 1652.422),
            s("940GZZDLSHA", 2747.703, 1758.203),
            s("940GZZDLLIM", 2828.0, 1758.203),
            s("940GZZDLWFE", 2909.0, 1758.203),
            s("940GZZDLPOP", 3027.281, 1758.203),
            s("940GZZDLBLA", 3104.0, 1758.203),
            s("940GZZDLEIN", 3202.0, 1758.203),
            s("940GZZDLCGT", 3254.0, 1758.203),
            s("940GZZDLRVC", 3455.0, 1758.203),
            s("940GZZDLCUS", 3591.0, 1840.594),
            s("940GZZDLPRE", 3627.875, 1912.0),
            s("940GZZDLRAL", 3627.875, 1963.0),
            s("940GZZDLBPK", 3627.875, 2015.0),
            s("940GZZDLCYP", 3627.875, 2066.0),
            s("940GZZDLGAL", 3627.875, 2118.0),
            s("940GZZDLBEC", 3627.875, 2165.031),
        ),
    ),
    TraceSpec(
        "dlr.tower-gateway-shadwell.official.v1", "dlr",
        (p(6, (2573.000, 1733.031), (2747.703, 1758.203)),),
        (
            s("940GZZDLTWG", 2573.000, 1733.031),
            s("940GZZDLSHA", 2747.703, 1758.203),
        ),
    ),
    TraceSpec(
        "dlr.stratford-lewisham.official.v1", "dlr",
        (p(4, (3252.750, 1271.032), (3027.281, 2456.937)),),
        (
            s("940GZZDLSTD", 3252.750, 1271.032),
            s("940GZZDLPUD", 3130.0, 1392.0),
            s("940GZZDLBOW", 3027.297, 1517.0),
            s("940GZZDLDEV", 3027.297, 1614.0),
            s("940GZZDLLDP", 3027.297, 1662.0),
            s("940GZZDLALL", 3027.297, 1704.0),
            s("940GZZDLPOP", 3027.297, 1758.203),
            s("940GZZDLWIQ", 3027.297, 1832.0),
            s("940GZZDLCAN", 3027.297, 1904.0),
            s("940GZZDLHEQ", 3027.297, 2000.0),
            s("940GZZDLSOQ", 3027.297, 2041.0),
            s("940GZZDLCLA", 3027.297, 2083.0),
            s("940GZZDLMUD", 3027.297, 2125.0),
            s("940GZZDLISL", 3027.297, 2165.0),
            s("940GZZDLCUT", 3027.297, 2241.0),
            s("940GZZDLGRE", 3027.297, 2318.0),
            s("940GZZDLDEP", 3027.297, 2367.0),
            s("940GZZDLELV", 3027.297, 2413.0),
            s("940GZZDLLEW", 3027.281, 2456.937),
        ),
    ),
    TraceSpec(
        "dlr.canning-stratford-international.official.v1", "dlr",
        (
            p(9, (3254.0, 1758.203), (3358.906, 1758.219)),
            p(8, (3358.906, 1758.219), (3289.016, 1726.297)),
            p(1, (3289.016, 1726.297), (3280.781, 1698.984)),
            p(2, (3280.781, 1698.984), (3070.859, 1161.188)),
        ),
        (
            s("940GZZDLCGT", 3254.0, 1758.203),
            s("940GZZDLSTL", 3280.781, 1643.0),
            s("940GZZDLWHM", 3280.781, 1546.0),
            s("940GZZDLABR", 3280.781, 1443.0),
            s("940GZZDLSHS", 3280.781, 1360.0),
            s("940GZZDLSTD", 3252.750, 1271.032),
            s("940GZZDLSIT", 3070.859, 1161.188),
        ),
    ),
    TraceSpec(
        "dlr.canning-woolwich.official.v1", "dlr",
        (
            p(9, (3254.0, 1758.203), (3335.375, 1758.219)),
            p(3, (3335.375, 1758.219), (3494.422, 2253.922)),
        ),
        (
            s("940GZZDLCGT", 3254.0, 1758.203),
            s("940GZZDLWSV", 3494.422, 1945.0),
            s("940GZZDLPDK", 3494.422, 2016.0),
            s("940GZZDLLCA", 3494.422, 2085.0),
            s("940GZZDLKGV", 3494.422, 2163.0),
            s("940GZZDLWLA", 3494.422, 2245.0),
        ),
    ),
    TraceSpec(
        "dlr.westferry-canary.official.v1", "dlr",
        (
            p(9, (2909.0, 1758.203), (2947.125, 1758.203)),
            p(7, (2947.125, 1758.203), (3016.781, 1789.891)),
            p(5, (3016.781, 1789.891), (3027.266, 1842.297)),
            p(4, (3027.266, 1842.297), (3027.297, 1904.0)),
        ),
        (
            s("940GZZDLWFE", 2909.0, 1758.203),
            s("940GZZDLCAN", 3027.297, 1904.0),
        ),
    ),
)


ELIZABETH_TRACES = (
    TraceSpec(
        "elizabeth.hayes-reading.official.v1", "elizabeth",
        (p(4, (342.719, 1657.188), (160.281, 960.391)),),
        (
            s("910GHAYESAH", 342.719, 1657.188),
            s("910GWDRYTON", 160.267, 1549.006),
            s("910GIVER", 160.281, 1466.754),
            s("910GLANGLEY", 160.281, 1395.241),
            s("910GSLOUGH", 160.281, 1320.866),
            s("910GBNHAM", 160.281, 1244.776),
            s("910GTAPLOW", 160.281, 1166.969),
            s("910GMDNHEAD", 160.281, 1098.888),
            s("910GTWYFORD", 160.281, 1030.807),
            s("910GRDNGSTN", 160.281, 962.726),
        ),
    ),
    TraceSpec(
        "elizabeth.heathrow-paddington.official.v1", "elizabeth",
        (p(6, (292.000, 2257.891), (1458.781, 1474.985)),),
        (
            s("910GHTRWTM4", 292.000, 2257.891),
            s("910GHTRWAPT", 292.026, 2089.008),
            s("910GHAYESAH", 336.999, 1657.188),
            s("910GSTHALL", 421.123, 1657.203),
            s("910GHANWELL", 466.966, 1657.203),
            s("910GWEALING", 534.132, 1657.203),
            s("910GEALINGB", 597.033, 1657.203),
            s("910GACTONML", 873.971, 1502.933),
            s("910GPADTLL", 1458.781, 1474.985),
        ),
    ),
    TraceSpec(
        "elizabeth.heathrow-terminal-five.official.v1", "elizabeth",
        (p(5, (292.016, 2089.002), (176.813, 2286.980)),),
        (
            s("910GHTRWAPT", 292.016, 2089.002),
            s("910GHTRWTM5", 176.813, 2286.980),
        ),
    ),
    TraceSpec(
        "elizabeth.paddington-abbey-wood.official.v1", "elizabeth",
        (p(8, (1460.011, 1474.984), (3563.892, 2317.980)),),
        (
            s("910GPADTLL", 1460.011, 1474.984),
            s("910GBONDST", 1767.999, 1561.797),
            s("910GTOTCTRD", 1966.983, 1561.804),
            s("910GFRNDXR", 2169.964, 1486.141),
            s("910GLIVSTLL", 2384.986, 1486.094),
            s("910GWCHAPXR", 2735.050, 1516.281),
            s("910GCANWHRF", 3063.096, 1867.937),
            s("910GCUSTMHS", 3544.305, 1886.695),
            s("910GWOLWXR", 3563.904, 2246.017),
            s("910GABWDXR", 3563.892, 2317.980),
        ),
    ),
    TraceSpec(
        "elizabeth.shenfield-stratford.official.v1", "elizabeth",
        (p(1, (4008.964, 766.145), (3223.004, 1267.029)),),
        (
            s("910GSHENFLD", 4008.964, 766.145),
            s("910GBRTWOOD", 3943.698, 831.414),
            s("910GHRLDWOD", 3863.634, 911.482),
            s("910GGIDEAPK", 3818.099, 957.018),
            s("910GROMFORD", 3773.703, 1001.416),
            s("910GCHDWLHT", 3715.647, 1059.474),
            s("910GGODMAYS", 3657.970, 1117.154),
            s("910GSVNKNGS", 3594.918, 1153.437),
            s("910GILFORD", 3546.986, 1153.437),
            s("910GMANRPK", 3477.053, 1153.437),
            s("910GFRSTGT", 3375.951, 1153.437),
            s("910GMRYLAND", 3287.094, 1202.929),
            s("910GSTFD", 3223.004, 1267.029),
        ),
    ),
    TraceSpec(
        "elizabeth.stratford-whitechapel.official.v1", "elizabeth",
        (
            p(1, (3223.004, 1267.029), (2871.047, 1448.609)),
            p(2, (2871.047, 1448.609), (2759.031, 1516.281)),
            p(8, (2759.031, 1516.281), (2735.050, 1516.281)),
        ),
        (
            s("910GSTFD", 3223.004, 1267.029),
            s("910GWCHAPXR", 2735.050, 1516.281),
        ),
    ),
    TraceSpec(
        "elizabeth.stratford-liverpool-mainline.official.v1", "elizabeth",
        (
            p(1, (3223.004, 1267.029), (2871.047, 1448.609)),
            p(2, (2871.047, 1448.609), (2759.031, 1516.281)),
            p(8, (2759.031, 1516.281), (2384.986, 1486.094)),
        ),
        (
            s("910GSTFD", 3223.004, 1267.029),
            s("910GLIVST", 2384.986, 1486.094),
        ),
    ),
    TraceSpec(
        "elizabeth.paddington-mainline-acton.official.v1", "elizabeth",
        (p(6, (1458.781, 1474.985), (873.971, 1502.933)),),
        (
            s("910GPADTON", 1458.781, 1474.985),
            s("910GACTONML", 873.971, 1502.933),
        ),
    ),
)


def _path_candidates(
    root: ET.Element,
    colour_fragment: str,
    expected_count: int = 9,
    outer_stroke_width: float = OFFICIAL_OUTER_STROKE_WIDTH,
) -> list[list[vector.Curve]]:
    elements = [
        element for element in root.iter()
        if element.tag.endswith("path")
        and colour_fragment in element.get("stroke", "")
        and element.get("d")
        and math.isclose(
            float(element.get("stroke-width", "nan")),
            outer_stroke_width,
            abs_tol=0.0001,
        )
    ]
    if len(elements) != expected_count:
        raise ValueError(
            f"Expected {expected_count} official {colour_fragment} rail paths; found {len(elements)}"
        )
    return [
        vector.parse_path(
            element.get("d", ""),
            vector.parse_matrix(element.get("transform")),
        )
        for element in elements
    ]


def _master_paths(
    root: ET.Element,
    colour_fragment: str,
    fingerprints: tuple[Fingerprint, ...],
    outer_stroke_width: float = OFFICIAL_OUTER_STROKE_WIDTH,
) -> dict[int, list[vector.Curve]]:
    candidates = _path_candidates(
        root,
        colour_fragment,
        len(fingerprints),
        outer_stroke_width,
    )
    result: dict[int, list[vector.Curve]] = {}
    used: set[int] = set()
    for fingerprint in fingerprints:
        matches = [
            index for index, curves in enumerate(candidates)
            if index not in used
            and len(curves) == fingerprint.curve_count
            and math.dist(curves[0].start, fingerprint.start) <= 1.0
            and math.dist(curves[-1].end, fingerprint.end) <= 1.0
        ]
        if len(matches) != 1:
            raise ValueError(
                f"Rail master {colour_fragment} fingerprint {fingerprint.key} "
                f"matched candidates {matches}"
            )
        used.add(matches[0])
        result[fingerprint.key] = candidates[matches[0]]
    if len(used) != len(candidates):
        raise ValueError(f"Unmatched official {colour_fragment} rail paths")
    return result


def _checked_match(
    curves: list[vector.Curve],
    approximate: Point,
    context: str,
    tolerance: float = PORT_SNAP_TOLERANCE,
) -> vector.Match:
    match = vector.nearest_match(curves, approximate)
    distance = math.dist(match.point, approximate)
    if distance > tolerance:
        raise ValueError(
            f"{context} is {distance:.3f} artwork units from the official path"
        )
    return match


def _trace_curves(
    masters: dict[int, list[vector.Curve]],
    trace: TraceSpec,
) -> list[vector.Curve]:
    result: list[vector.Curve] = []
    for index, piece in enumerate(trace.pieces):
        master = masters[piece.master]
        start = _checked_match(master, piece.start, f"{trace.identifier} piece {index} start")
        end = _checked_match(master, piece.end, f"{trace.identifier} piece {index} end")
        sliced = vector.path_slice(master, start, end)
        if not sliced or math.dist(sliced[0].start, sliced[-1].end) < 0.001:
            raise ValueError(f"{trace.identifier} piece {index} is empty")
        if result:
            gap = math.dist(result[-1].end, sliced[0].start)
            if gap > JOIN_TOLERANCE:
                raise ValueError(
                    f"{trace.identifier} discontinuity before piece {index}: {gap:.3f}"
                )
        result.extend(sliced)
    return result


def _semantic_segment(
    graph_segments: dict[str, dict],
    line_id: str,
    first_id: str,
    second_id: str,
) -> dict:
    expected = {first_id, second_id}
    matches = [
        segment for segment in graph_segments.values()
        if segment["lineID"] == line_id
        and {segment["fromStationID"], segment["toStationID"]} == expected
    ]
    if len(matches) != 1:
        raise ValueError(
            f"Expected one {line_id} graph segment for {first_id} - {second_id}; "
            f"found {len(matches)}"
        )
    return matches[0]


def _compile_trace(
    trace: TraceSpec,
    masters: dict[int, list[vector.Curve]],
    graph_segments: dict[str, dict],
    selected_paths: dict[str, dict],
    selected_segments: dict[str, dict],
    ports_by_station: dict[str, list[tuple[str, vector.Match]]],
) -> None:
    curves = _trace_curves(masters, trace)
    matches = [
        (
            port.station_id,
            _checked_match(curves, port.approximate, f"{trace.identifier} {port.station_id}"),
        )
        for port in trace.ports
    ]
    scalars = [match.scalar for _, match in matches]
    if any(current >= following for current, following in zip(scalars, scalars[1:])):
        raise ValueError(f"{trace.identifier} station ports are not monotonic")

    for station_id, match in matches:
        ports_by_station.setdefault(station_id, []).append((trace.line_id, match))

    for pair_index, ((first_id, first), (second_id, second)) in enumerate(
        zip(matches, matches[1:])
    ):
        semantic = _semantic_segment(graph_segments, trace.line_id, first_id, second_id)
        segment_curves = vector.path_slice(curves, first, second)
        path_id = f"beck.v1.path.{trace.identifier}.{pair_index}"
        record = {"id": path_id, "commands": vector.path_commands(segment_curves)}

        if semantic["fromStationID"] == first_id:
            from_port = first.point
            to_port = second.point
            direction = "forward"
        else:
            from_port = second.point
            to_port = first.point
            direction = "reverse"

        existing = selected_segments.get(semantic["id"])
        if existing is not None:
            raise ValueError(
                f"Rail semantic segment {semantic['id']} was compiled more than once"
            )
        selected_paths[path_id] = record
        selected_segments[semantic["id"]] = {
            "id": semantic["id"],
            "lineID": trace.line_id,
            "fromStationID": semantic["fromStationID"],
            "toStationID": semantic["toStationID"],
            "fromPort": vector.rounded(from_port),
            "toPort": vector.rounded(to_port),
            "pathID": path_id,
            "pathDirection": direction,
            "translation": {"x": 0, "y": 0},
        }


def _circle(point: Point) -> dict:
    return {
        "kind": "circle",
        "circle": {
            "centre": vector.rounded(point),
            "radius": 8.5,
            "outlineWidth": 3.5,
        },
    }


def _connector(start: Point, end: Point) -> dict:
    return {
        "kind": "connector",
        "connector": {
            "start": vector.rounded(start),
            "end": vector.rounded(end),
            "width": 7.5,
        },
    }


def _unique_points(points: list[Point], tolerance: float = 3.0) -> list[Point]:
    result: list[Point] = []
    for point in points:
        if not any(math.dist(point, existing) <= tolerance for existing in result):
            result.append(point)
    return result


def _append_markers_and_labels(
    graph: dict,
    ports_by_station: dict[str, list[tuple[str, vector.Match]]],
    markers: list[dict],
    labels: list[dict],
) -> None:
    stations_by_id = {station["id"]: station for station in graph["stations"]}
    existing_hubs = {
        stations_by_id[marker["stationID"]].get("hubID")
        or stations_by_id[marker["stationID"]]["id"]
        for marker in markers
    }

    for station_id in sorted(ports_by_station):
        station = stations_by_id[station_id]
        matches = ports_by_station[station_id]
        points = _unique_points([match.point for _, match in matches])
        if not points:
            raise ValueError(f"Rail station {station_id} has no official port")
        anchor = (
            sum(point[0] for point in points) / len(points),
            sum(point[1] for point in points) / len(points),
        )
        primitives: list[dict] = []
        if len(points) > 1:
            primitives.append(_connector(points[0], points[-1]))
        primitives.extend(_circle(point) for point in points)
        markers.append({
            "stationID": station_id,
            "name": station["name"],
            "lineIDs": station["lineIDs"],
            "anchor": vector.rounded(anchor),
            "hitRadius": 14,
            "primitives": primitives,
        })

        hub_id = station.get("hubID") or station_id
        if hub_id in existing_hubs:
            continue
        display_name = station["name"].removesuffix(" DLR Station")
        label_dx = 16 if sum(ord(character) for character in station_id) % 2 == 0 else -16
        labels.append({
            "id": f"label.{station_id}",
            "stationID": station_id,
            "text": display_name,
            "position": vector.rounded((anchor[0] + label_dx, anchor[1] - 18)),
            "alignment": "leading" if label_dx > 0 else "trailing",
            "rotationDegrees": 0,
            "priority": 5,
        })


def _append_graph_routes(graph: dict, routes: dict[str, dict]) -> None:
    graph_segments = {segment["id"]: segment for segment in graph["segments"]}
    segments_by_pair = {
        (segment["lineID"], frozenset((segment["fromStationID"], segment["toStationID"]))): segment["id"]
        for segment in graph["segments"]
    }
    for line_id in ("dlr", "elizabeth"):
        line = next(line for line in graph["lines"] if line["id"] == line_id)
        for route_index, station_ids in enumerate(line["routes"]):
            segment_ids = [
                segments_by_pair[(line_id, frozenset((first, second)))]
                for first, second in zip(station_ids, station_ids[1:])
            ]
            if any(segment_id not in graph_segments for segment_id in segment_ids):
                raise ValueError(f"Unknown graph segment in {line_id} route {route_index}")
            route_id = f"{line_id}.graph-route.{route_index}.v1"
            routes[route_id] = {
                "id": route_id,
                "lineID": line_id,
                "stationIDs": station_ids,
                "segmentIDs": segment_ids,
            }


def append_rail_artwork(
    root: ET.Element,
    graph: dict,
    selected_paths: dict[str, dict],
    selected_segments: dict[str, dict],
    markers: list[dict],
    labels: list[dict],
    routes: dict[str, dict],
) -> None:
    """Append exact official DLR/Elizabeth geometry and graph semantics."""
    graph_segments = {segment["id"]: segment for segment in graph["segments"]}
    expected = {
        segment["id"] for segment in graph["segments"]
        if segment["lineID"] in {"dlr", "elizabeth"}
    }
    preexisting = expected.intersection(selected_segments)
    if preexisting:
        raise ValueError(f"Rail segments already exist before compilation: {sorted(preexisting)}")

    masters_by_line = {
        "dlr": _master_paths(root, DLR_COLOUR, DLR_FINGERPRINTS),
        "elizabeth": _master_paths(root, ELIZABETH_COLOUR, ELIZABETH_FINGERPRINTS),
    }
    ports_by_station: dict[str, list[tuple[str, vector.Match]]] = {}
    for trace in (*DLR_TRACES, *ELIZABETH_TRACES):
        _compile_trace(
            trace,
            masters_by_line[trace.line_id],
            graph_segments,
            selected_paths,
            selected_segments,
            ports_by_station,
        )

    actual = expected.intersection(selected_segments)
    if actual != expected:
        missing = sorted(expected - actual)
        raise ValueError(f"Official rail compilation is missing graph segments: {missing}")
    _append_graph_routes(graph, routes)
    _append_markers_and_labels(graph, ports_by_station, markers, labels)
