#!/usr/bin/env python3
"""Compile Thameslink from the official TfL standard-map vectors.

TfL draws Thameslink as a National Rail route: a pink casing with a dashed
white inset, running off the map with "Towards ..." arrows. The four pink
master paths hold eleven sub-paths (the Wimbledon/Sutton loop, the Catford
loop, the Greenwich line and so on); every graph segment is an exact slice of
them, joined across the few places where TfL breaks one sub-path into the
next (under the Windrush line at Peckham Rye, and at the core's junctions).

Run as a script, this adds Thameslink to an already-composed document in
place, then lets the TfL reference alignment rebuild the stations' symbols.
`build_full_underground.py` calls `append_thameslink_artwork` for full builds.
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


THAMESLINK_LINE_ID = "thameslink"
THAMESLINK_COLOUR = "83.921814%"  # rgb(214, 111, 170), #D66FAA
OFFICIAL_OUTER_STROKE_WIDTH = 2.21
OFFICIAL_INNER_STROKE_WIDTH = 0.782
# TfL leaves a short gap in the pink stroke where another line crosses over
# it. The app draws lines in a fixed order, so a gap is bridged when the two
# sub-paths meet end to end on one straight line.
MAXIMUM_BRIDGE = 15.0

Point = vector.Point
p = rail.p
s = rail.s


@dataclass(frozen=True)
class SubpathFingerprint:
    key: int
    master_curve_count: int
    curve_count: int
    start: Point
    end: Point


# Keys 0-10 are TfL's own sub-paths. Key 3's last curve is the straight run
# up through Mitcham Eastfields, Streatham, Tulse Hill and Herne Hill; it is
# split off as key 11 because the loop leaves and rejoins it at Streatham.
SUBPATHS = (
    SubpathFingerprint(0, 104, 13, (1566.031, 427.141), (2169.625, 1125.484)),
    SubpathFingerprint(1, 104, 7, (2091.562, 2202.671), (2523.734, 2263.531)),
    SubpathFingerprint(2, 104, 12, (2536.844, 2263.531), (3951.953, 2566.031)),
    SubpathFingerprint(3, 104, 37, (2055.828, 2577.718), (2055.859, 2436.312)),
    SubpathFingerprint(4, 104, 1, (4026.999, 2409.749), (3773.499, 2409.593)),
    SubpathFingerprint(5, 104, 18, (2340.140, 1883.015), (2316.765, 2962.968)),
    SubpathFingerprint(6, 104, 6, (3463.968, 2279.625), (4029.202, 2319.906)),
    SubpathFingerprint(7, 104, 10, (2516.078, 2046.593), (3460.640, 2279.500)),
    SubpathFingerprint(8, 24, 24, (2111.234, 2134.578), (2299.391, 436.891)),
    SubpathFingerprint(9, 7, 7, (2055.844, 2442.750), (2111.219, 2117.484)),
    SubpathFingerprint(10, 4, 4, (2212.172, 1860.719), (2340.187, 1883.016)),
)
LOOP_KEY = 3
MITCHAM_EASTFIELDS_RUN_KEY = 11


TRACES = (
    rail.TraceSpec(
        "thameslink.midland-main-line.official.v1",
        THAMESLINK_LINE_ID,
        (
            p(0, (1566.031, 534.320), (2169.625, 1125.484)),
            p(8, (2169.625, 1125.484), (2169.680, 1323.660)),
        ),
        (
            s("910GELTR", 1565.820, 534.320),
            s("910GMLHB", 1566.031, 650.312),
            s("910GHDON", 1566.031, 841.750),
            s("910GBRENTX", 1566.020, 918.050),
            s("910GCRKLWD", 1566.031, 989.938),
            s("910GWHMPSTM", 1639.160, 1116.710),
            s("910GKNTSHTN", 2112.670, 1051.230),
            s("910GSTPXBOX", 2169.680, 1323.660),
        ),
    ),
    rail.TraceSpec(
        "thameslink.core.official.v1",
        THAMESLINK_LINE_ID,
        (
            p(8, (2169.680, 1323.660), (2111.234, 2134.578)),
            p(9, (2111.234, 2134.578), (2091.520, 2201.490)),
        ),
        (
            s("910GSTPXBOX", 2169.680, 1323.660),
            s("910GFRNDNLT", 2169.430, 1486.300),
            s("910GCTMSLNK", 2169.300, 1613.790),
            s("910GBLFR", 2211.410, 1851.920),
            s("910GELPHNAC", 2091.520, 2201.490),
        ),
    ),
    rail.TraceSpec(
        "thameslink.east-coast-main-line.official.v1",
        THAMESLINK_LINE_ID,
        (p(8, (2169.680, 1323.660), (2298.810, 558.830)),),
        (
            s("910GSTPXBOX", 2169.680, 1323.660),
            s("910GFNPK", 2411.383, 981.945),
            s("910GNEWSGAT", 2298.812, 711.203),
            s("910GOKLGHPK", 2299.391, 631.367),
            s("910GNBARNET", 2298.812, 558.830),
        ),
    ),
    rail.TraceSpec(
        "thameslink.brighton-main-line.official.v1",
        THAMESLINK_LINE_ID,
        (
            p(8, (2211.410, 1851.920), (2212.172, 1860.719)),
            p(10, (2212.172, 1860.719), (2340.187, 1883.016)),
            p(5, (2340.140, 1883.015), (2497.940, 2881.040)),
        ),
        (
            s("910GBLFR", 2211.410, 1851.920),
            s("910GLNDNBDC", 2306.360, 1882.880),
            s("910GNORWDJ", 2704.740, 2538.280),
            s("910GECROYDN", 2903.560, 2787.710),
            s("910GSCROYDN", 2783.390, 2881.000),
            s("910GPURLEY", 2627.640, 2881.040),
            s("910GCOLSDNS", 2497.940, 2881.040),
        ),
    ),
    rail.TraceSpec(
        "thameslink.greenwich-line.official.v1",
        THAMESLINK_LINE_ID,
        (
            p(10, (2306.360, 1882.880), (2340.187, 1883.016)),
            p(5, (2340.140, 1883.015), (2516.078, 2046.593)),
            p(7, (2516.078, 2046.593), (3460.640, 2279.500)),
        ),
        (
            s("910GLNDNBDC", 2306.360, 1882.880),
            s("910GDEPTFD", 2863.560, 2252.390),
            s("910GGNWH", 2989.580, 2279.730),
            s("910GMAZEH", 3207.190, 2279.450),
            s("910GWCOMBEP", 3264.410, 2279.450),
            s("910GCRLN", 3323.110, 2279.450),
            s("910GWOLWCHA", 3460.640, 2279.500),
        ),
    ),
    rail.TraceSpec(
        "thameslink.abbey-wood-dartford.official.v1",
        THAMESLINK_LINE_ID,
        (p(6, (3463.968, 2279.625), (3977.160, 2319.740)),),
        (
            s("910GWOLWCHA", 3463.968, 2279.625),
            s("910GPLMS", 3516.760, 2299.780),
            s("910GABWD", 3564.420, 2318.910),
            s("910GSLADEGN", 3862.770, 2320.030),
            s("910GDARTFD", 3977.160, 2319.740),
        ),
    ),
    rail.TraceSpec(
        "thameslink.herne-hill.official.v1",
        THAMESLINK_LINE_ID,
        (p(9, (2091.520, 2201.490), (2056.050, 2438.030)),),
        (
            s("910GELPHNAC", 2091.520, 2201.490),
            s("910GLBGHJN", 2055.844, 2296.312),
            s("910GHERNEH", 2056.050, 2438.030),
        ),
    ),
    rail.TraceSpec(
        "thameslink.tulse-hill.official.v1",
        THAMESLINK_LINE_ID,
        (p(MITCHAM_EASTFIELDS_RUN_KEY, (2056.050, 2438.030), (2055.830, 2549.500)),),
        (
            s("910GHERNEH", 2056.050, 2438.030),
            s("910GTULSEH", 2056.110, 2492.920),
            s("910GSTRETHM", 2055.830, 2549.500),
        ),
    ),
    rail.TraceSpec(
        "thameslink.wimbledon-sutton-loop.official.v1",
        THAMESLINK_LINE_ID,
        (
            p(MITCHAM_EASTFIELDS_RUN_KEY, (2055.830, 2549.500), (2055.828, 2577.718)),
            p(LOOP_KEY, (2055.828, 2577.718), (2055.859, 2683.000)),
            p(MITCHAM_EASTFIELDS_RUN_KEY, (2055.859, 2683.000), (2055.830, 2549.500)),
        ),
        (
            s("910GSTRETHM", 2055.830, 2549.500),
            s("910GTOOTING", 1769.940, 2662.370),
            s("910GHYDNSRD", 1551.344, 2551.418),
            s("910GWIMBLDN", 1362.290, 2374.430),
            s("910GWIMLCHS", 1255.500, 2528.352),
            s("910GSMERTON", 1255.500, 2637.945),
            s("910GMORDENS", 1282.859, 2722.086),
            s("910GSHLIER", 1321.078, 2760.301),
            s("910GSUTTONC", 1418.496, 2857.719),
            s("910GWSUTTON", 1672.555, 2883.430),
            s("910GSUTTON", 1740.590, 2883.430),
            s("910GCRSHLTN", 1826.260, 2883.430),
            s("910GHKBG", 1906.730, 2845.210),
            s("910GMITCHMJ", 2034.880, 2717.480),
            s("910GESTFLDS", 2055.670, 2655.700),
            s("910GSTRETHM", 2055.830, 2549.500),
        ),
    ),
    rail.TraceSpec(
        "thameslink.catford-loop.official.v1",
        THAMESLINK_LINE_ID,
        (
            p(1, (2091.562, 2202.671), (2523.734, 2263.531)),
            p(2, (2536.844, 2263.531), (3951.953, 2566.031)),
        ),
        (
            s("910GELPHNAC", 2091.562, 2202.671),
            s("910GDENMRKH", 2215.297, 2263.414),
            s("910GPCKHMRY", 2420.250, 2263.560),
            s("910GNUNHEAD", 2585.440, 2263.560),
            s("910GCFPK", 3017.610, 2511.980),
            s("910GCATFORD", 3112.810, 2511.980),
            s("910GBELNGHM", 3171.023, 2496.211),
            s("910GBCKNHMH", 3326.830, 2409.770),
            s("910GRBRN", 3418.227, 2409.600),
            s("910GSHRTLND", 3515.480, 2409.370),
            s("910GBROMLYS", 3650.910, 2409.370),
            s("910GBICKLEY", 3770.700, 2409.390),
            s("910GPETSWD", 3816.760, 2430.520),
            s("910GORPNGTN", 3951.953, 2566.031),
        ),
    ),
    rail.TraceSpec(
        "thameslink.swanley.official.v1",
        THAMESLINK_LINE_ID,
        (p(4, (3971.780, 2409.370), (3773.499, 2409.593)),),
        (
            s("910GSWLY", 3971.780, 2409.370),
            s("910GSTMRYC", 3862.500, 2409.370),
            s("910GBICKLEY", 3773.499, 2409.593),
        ),
    ),
)


# pdftotext reads "West Sutton Carshalton" as one line of text: TfL sets the
# three names side by side, so their boxes are measured from the words.
LABEL_OVERRIDES: dict[str, tuple[str, Point, str]] = {
    "910GWSUTTON": ("West\nSutton", (1673.100, 2913.450), "centre"),
    "910GSUTTON": ("Sutton", (1741.600, 2908.000), "centre"),
    "910GCRSHLTN": ("Carshalton", (1826.850, 2908.000), "centre"),
}


@dataclass(frozen=True)
class LineExtensionSpec:
    """A route drawn on past its last mapped station to a "Towards" arrow."""

    station_id: str
    subpath: int
    start: Point
    end: Point
    arrowhead: tuple[Point, ...]
    text: str
    label_position: Point
    label_alignment: str


LINE_EXTENSIONS = (
    LineExtensionSpec(
        "910GELTR", 0, (1565.820, 534.320), (1566.031, 427.141),
        ((1579.297, 439.812), (1579.312, 428.812), (1565.969, 419.078), (1552.750, 428.812),
         (1552.750, 439.812), (1565.969, 430.562)),
        "Towards\nSt Albans City and Luton Airport Parkway", (1590.181, 434.608), "leading",
    ),
    LineExtensionSpec(
        "910GNBARNET", 8, (2298.812, 558.830), (2299.391, 436.891),
        ((2312.781, 445.812), (2312.797, 434.797), (2299.453, 425.078), (2286.234, 434.797),
         (2286.234, 445.812), (2299.453, 436.547)),
        "Towards\nWelwyn Garden\nCity", (2279.142, 439.939), "trailing",
    ),
    LineExtensionSpec(
        "910GCOLSDNS", 5, (2497.940, 2881.040), (2316.765, 2962.968),
        ((2303.500, 2953.641), (2303.484, 2964.641), (2316.828, 2974.375), (2330.047, 2964.641),
         (2330.047, 2953.641), (2316.828, 2962.891)),
        "Towards\nGatwick Airport", (2292.415, 2962.786), "trailing",
    ),
    LineExtensionSpec(
        "910GSWLY", 4, (3971.780, 2409.370), (4026.999, 2409.749),
        ((4018.828, 2423.312), (4029.828, 2423.312), (4039.547, 2409.984), (4029.828, 2396.766),
         (4018.828, 2396.766), (4028.078, 2409.984)),
        "Towards\nSevenoaks", (4041.247, 2451.132), "trailing",
    ),
    LineExtensionSpec(
        "910GDARTFD", 6, (3977.160, 2319.740), (4029.202, 2319.906),
        ((4019.031, 2333.375), (4030.031, 2333.391), (4039.750, 2320.047), (4030.031, 2306.828),
         (4019.031, 2306.828), (4028.281, 2320.047)),
        "Towards\nGravesend", (4041.384, 2280.112), "trailing",
    ),
)


def _subpaths(curves: list[vector.Curve]) -> list[list[vector.Curve]]:
    result: list[list[vector.Curve]] = []
    for curve in curves:
        if result and math.dist(curve.start, result[-1][-1].end) <= 0.01:
            result[-1].append(curve)
        else:
            result.append([curve])
    return result


def _is_outer(element: ET.Element) -> bool:
    return (
        element.tag.endswith("path")
        and THAMESLINK_COLOUR in element.get("stroke", "")
        and bool(element.get("d"))
        and math.isclose(float(element.get("stroke-width", "nan")), OFFICIAL_OUTER_STROKE_WIDTH, abs_tol=0.0001)
    )


def _is_dashed_inset(element: ET.Element) -> bool:
    return (
        element.tag.endswith("path")
        and element.get("stroke") == "rgb(100%, 100%, 100%)"
        and bool(element.get("stroke-dasharray"))
        and bool(element.get("d"))
        and math.isclose(float(element.get("stroke-width", "nan")), OFFICIAL_INNER_STROKE_WIDTH, abs_tol=0.0001)
    )


def master_subpaths(root: ET.Element) -> dict[int, list[vector.Curve]]:
    """TfL's Thameslink sub-paths, keyed as in SUBPATHS, plus the split run."""
    outer = [element for element in root.iter() if _is_outer(element)]
    insets = [
        vector.parse_path(element.get("d", ""), vector.parse_matrix(element.get("transform")))
        for element in root.iter() if _is_dashed_inset(element)
    ]
    candidates: list[tuple[int, list[vector.Curve]]] = []
    for element in outer:
        curves = vector.parse_path(element.get("d", ""), vector.parse_matrix(element.get("transform")))
        candidates.extend((len(curves), subpath) for subpath in _subpaths(curves))

    result: dict[int, list[vector.Curve]] = {}
    used: set[int] = set()
    for fingerprint in SUBPATHS:
        matches = [
            index for index, (master_count, curves) in enumerate(candidates)
            if index not in used
            and master_count == fingerprint.master_curve_count
            and len(curves) == fingerprint.curve_count
            and math.dist(curves[0].start, fingerprint.start) <= 1.0
            and math.dist(curves[-1].end, fingerprint.end) <= 1.0
        ]
        if len(matches) != 1:
            raise ValueError(f"Thameslink sub-path {fingerprint.key} matched candidates {matches}")
        used.add(matches[0])
        result[fingerprint.key] = candidates[matches[0]][1]
    if len(used) != len(candidates):
        raise ValueError("Unmatched official Thameslink sub-paths")
    # Every sub-path carries TfL's National Rail inset, a dashed white stroke
    # down its centre (trimmed short of its ends).
    for key, curves in result.items():
        if not any(
            math.dist(vector.nearest_match(curves, inset[len(inset) // 2].start).point,
                      inset[len(inset) // 2].start) <= 0.5
            for inset in insets if inset
        ):
            raise ValueError(f"Thameslink source style changed: sub-path {key} has no dashed white inset")
    loop = result[LOOP_KEY]
    result[LOOP_KEY] = loop[:-1]
    result[MITCHAM_EASTFIELDS_RUN_KEY] = loop[-1:]
    return result


def _trace_curves(masters: dict[int, list[vector.Curve]], trace: rail.TraceSpec) -> list[vector.Curve]:
    result: list[vector.Curve] = []
    for index, piece in enumerate(trace.pieces):
        master = masters[piece.master]
        start = rail._checked_match(master, piece.start, f"{trace.identifier} piece {index} start")
        end = rail._checked_match(master, piece.end, f"{trace.identifier} piece {index} end")
        sliced = vector.path_slice(master, start, end)
        if not sliced or math.dist(sliced[0].start, sliced[-1].end) < 0.001:
            raise ValueError(f"{trace.identifier} piece {index} is empty")
        if result:
            gap = math.dist(result[-1].end, sliced[0].start)
            if gap > MAXIMUM_BRIDGE:
                raise ValueError(f"{trace.identifier} discontinuity before piece {index}: {gap:.3f}")
            if gap > rail.JOIN_TOLERANCE:
                result.append(vector.Curve("line", result[-1].end, sliced[0].start))
        result.extend(sliced)
    return result


def _sequential_match(
    curves: list[vector.Curve],
    approximate: Point,
    previous: vector.Match | None,
    context: str,
) -> vector.Match:
    """The nearest point after the previous port: the Sutton loop passes
    Streatham twice, once leaving it and once returning."""
    first = previous.curve_index if previous else 0
    offset = vector.nearest_match(curves[first:], approximate)
    match = vector.Match(offset.curve_index + first, offset.t, offset.point, offset.tangent)
    if previous and match.scalar <= previous.scalar and first + 1 < len(curves):
        offset = vector.nearest_match(curves[first + 1:], approximate)
        match = vector.Match(offset.curve_index + first + 1, offset.t, offset.point, offset.tangent)
    distance = math.dist(match.point, approximate)
    if distance > rail.PORT_SNAP_TOLERANCE:
        raise ValueError(f"{context} is {distance:.3f} artwork units from the official path")
    return match


def _compile_trace(
    trace: rail.TraceSpec,
    masters: dict[int, list[vector.Curve]],
    graph_segments: dict[str, dict],
    selected_paths: dict[str, dict],
    selected_segments: dict[str, dict],
) -> dict[str, list[Point]]:
    curves = _trace_curves(masters, trace)
    matches: list[tuple[str, vector.Match]] = []
    for port in trace.ports:
        previous = matches[-1][1] if matches else None
        matches.append((port.station_id, _sequential_match(
            curves, port.approximate, previous, f"{trace.identifier} {port.station_id}"
        )))
    scalars = [match.scalar for _, match in matches]
    if any(current >= following for current, following in zip(scalars, scalars[1:])):
        raise ValueError(f"{trace.identifier} station ports are not monotonic")

    ports: dict[str, list[Point]] = {}
    for pair_index, ((first_id, first), (second_id, second)) in enumerate(zip(matches, matches[1:])):
        semantic = rail._semantic_segment(graph_segments, THAMESLINK_LINE_ID, first_id, second_id)
        path_id = f"beck.v1.path.{trace.identifier}.{pair_index}"
        if semantic["id"] in selected_segments:
            raise ValueError(f"Thameslink segment {semantic['id']} was compiled more than once")
        forward = semantic["fromStationID"] == first_id
        selected_paths[path_id] = {
            "id": path_id,
            "commands": vector.path_commands(vector.path_slice(curves, first, second)),
        }
        selected_segments[semantic["id"]] = {
            "id": semantic["id"],
            "lineID": THAMESLINK_LINE_ID,
            "fromStationID": semantic["fromStationID"],
            "toStationID": semantic["toStationID"],
            "fromPort": vector.rounded(first.point if forward else second.point),
            "toPort": vector.rounded(second.point if forward else first.point),
            "pathID": path_id,
            "pathDirection": "forward" if forward else "reverse",
            "translation": {"x": 0, "y": 0},
        }
        ports.setdefault(first_id, []).append(first.point)
        ports.setdefault(second_id, []).append(second.point)
    return ports


def _line_extensions(masters: dict[int, list[vector.Curve]], selected_paths: dict[str, dict]) -> list[dict]:
    extensions = []
    for spec in LINE_EXTENSIONS:
        master = masters[spec.subpath]
        start = rail._checked_match(master, spec.start, f"{spec.station_id} line extension start")
        end = rail._checked_match(master, spec.end, f"{spec.station_id} line extension end")
        path_id = f"beck.v1.path.thameslink.towards.{spec.station_id}"
        selected_paths[path_id] = {
            "id": path_id,
            "commands": vector.path_commands(vector.path_slice(master, start, end)),
        }
        extensions.append({
            "id": f"thameslink.towards.{spec.station_id}",
            "lineID": THAMESLINK_LINE_ID,
            "stationID": spec.station_id,
            "pathID": path_id,
            "arrowhead": [vector.rounded(point) for point in spec.arrowhead],
        })
    return extensions


def _label_text(reference, box) -> str:
    lines = [
        label for label in reference.data["labels"]
        if label["box"][0] >= box[0] - 0.5 and label["box"][2] <= box[2] + 0.5
        and label["box"][1] >= box[1] - 0.5 and label["box"][3] <= box[3] + 0.5
    ]
    lines.sort(key=lambda label: (label["box"][1], label["box"][0]))
    return "\n".join(label["text"] for label in lines)


def _append_markers_and_labels(
    graph: dict,
    ports: dict[str, list[Point]],
    markers: list[dict],
    labels: list[dict],
    reference,
) -> None:
    stations_by_id = {station["id"]: station for station in graph["stations"]}
    expected = {station["id"] for station in graph["stations"] if THAMESLINK_LINE_ID in station["lineIDs"]}
    if set(ports) != expected:
        raise ValueError(
            "Thameslink ports differ from TubeGraph: "
            f"missing={sorted(expected - set(ports))}, extra={sorted(set(ports) - expected)}"
        )
    existing = {marker["stationID"]: marker for marker in markers}
    labelled = {
        station_id
        for label in labels
        for station_id in (label["stationID"], *label.get("associatedStationIDs", ()))
    }
    hubs_with_labels = {
        stations_by_id[station_id].get("hubID") or station_id
        for station_id in labelled if station_id in stations_by_id
    }

    for station_id in sorted(expected):
        station = stations_by_id[station_id]
        points = rail._unique_points(ports[station_id], tolerance=12.0)
        anchor = (
            sum(point[0] for point in points) / len(points),
            sum(point[1] for point in points) / len(points),
        )
        if station_id in existing:
            # A shared station (Denmark Hill, Peckham Rye...) keeps its symbol;
            # the reference alignment adds Thameslink to it.
            existing[station_id]["lineIDs"] = list(station["lineIDs"])
            continue
        markers.append({
            "stationID": station_id,
            "name": station["name"],
            "lineIDs": list(station["lineIDs"]),
            "anchor": vector.rounded(anchor),
            "hitRadius": 14,
            "primitives": [rail._circle(anchor)],
        })

        hub_id = station.get("hubID") or station_id
        # One label names a physical interchange, except where TfL itself
        # names the Thameslink station separately (West Hampstead Thameslink).
        if hub_id in hubs_with_labels and station_id != "910GWHMPSTM":
            continue
        if station_id in LABEL_OVERRIDES:
            text, position, alignment = LABEL_OVERRIDES[station_id]
            labels.append({
                "id": f"label.{station_id}",
                "stationID": station_id,
                "text": text,
                "position": vector.rounded(position),
                "alignment": alignment,
                "rotationDegrees": 0,
                "priority": 5,
            })
            continue
        boxes = [box for box in reference.label_boxes(station["name"]) if rail_box_distance(anchor, box) <= 110]
        if not boxes:
            raise ValueError(f"No TfL label found for Thameslink station {station['name']}")
        box = min(boxes, key=lambda candidate: (rail_box_distance(anchor, candidate), candidate))
        middle = (box[1] + box[3]) / 2
        if box[0] >= anchor[0] + 3:
            alignment, position = "leading", (box[0], middle)
        elif box[2] <= anchor[0] - 3:
            alignment, position = "trailing", (box[2], middle)
        else:
            alignment, position = "centre", ((box[0] + box[2]) / 2, middle)
        labels.append({
            "id": f"label.{station_id}",
            "stationID": station_id,
            "text": _label_text(reference, box) or station["name"],
            "position": vector.rounded(position),
            "alignment": alignment,
            "rotationDegrees": 0,
            "priority": 5,
        })


def rail_box_distance(point: Point, box) -> float:
    dx = max(box[0] - point[0], 0, point[0] - box[2])
    dy = max(box[1] - point[1], 0, point[1] - box[3])
    return math.hypot(dx, dy)


def _append_extension_labels(labels: list[dict]) -> None:
    for spec in LINE_EXTENSIONS:
        labels.append({
            "id": f"label.thameslink.towards.{spec.station_id}",
            "stationID": spec.station_id,
            "text": spec.text,
            "position": vector.rounded(spec.label_position),
            "alignment": spec.label_alignment,
            "rotationDegrees": 0,
            "priority": 3,
            "visibilityTier": "local",
        })


def _append_graph_routes(graph: dict, routes: dict[str, dict]) -> None:
    segments_by_pair = {
        frozenset((segment["fromStationID"], segment["toStationID"])): segment["id"]
        for segment in graph["segments"] if segment["lineID"] == THAMESLINK_LINE_ID
    }
    line = next(line for line in graph["lines"] if line["id"] == THAMESLINK_LINE_ID)
    for route_index, station_ids in enumerate(line["routes"]):
        route_id = f"thameslink.graph-route.{route_index}.v1"
        routes[route_id] = {
            "id": route_id,
            "lineID": THAMESLINK_LINE_ID,
            "stationIDs": station_ids,
            "segmentIDs": [
                segments_by_pair[frozenset(pair)] for pair in zip(station_ids, station_ids[1:])
            ],
        }


def append_thameslink_artwork(
    root: ET.Element,
    graph: dict,
    selected_paths: dict[str, dict],
    selected_segments: dict[str, dict],
    markers: list[dict],
    labels: list[dict],
    routes: dict[str, dict],
    reference,
) -> list[dict]:
    """Append exact Thameslink geometry for every graph edge.

    Returns the "Towards" line extensions for the document's `lineExtensions`.
    """
    graph_segments = {segment["id"]: segment for segment in graph["segments"]}
    expected = {segment["id"] for segment in graph["segments"] if segment["lineID"] == THAMESLINK_LINE_ID}
    preexisting = expected.intersection(selected_segments)
    if preexisting:
        raise ValueError(f"Thameslink segments already exist: {sorted(preexisting)}")

    masters = master_subpaths(root)
    ports: dict[str, list[Point]] = {}
    for trace in TRACES:
        for station_id, points in _compile_trace(
            trace, masters, graph_segments, selected_paths, selected_segments
        ).items():
            ports.setdefault(station_id, []).extend(points)

    missing = expected - set(selected_segments)
    if missing:
        raise ValueError(f"Official Thameslink compilation is missing graph segments: {sorted(missing)}")

    _append_markers_and_labels(graph, ports, markers, labels, reference)
    _append_extension_labels(labels)
    _append_graph_routes(graph, routes)
    return _line_extensions(masters, selected_paths)


def apply_to_document(document: dict, graph: dict, root: ET.Element, reference_data: dict) -> dict:
    """Add Thameslink to a composed document without recomposing the rest."""
    import build_full_underground
    import reference_alignment

    if THAMESLINK_LINE_ID in document.get("supportedLineIDs", []):
        raise ValueError("The document already contains Thameslink")
    result = copy.deepcopy(document)
    paths = {path["id"]: path for path in result["paths"]}
    segments = {segment["id"]: segment for segment in result["segments"]}
    routes = {route["id"]: route for route in result["routes"]}
    markers = result["stationMarkers"]
    new_labels: list[dict] = []
    reference = reference_alignment.Reference(reference_data)

    labels_before = copy.deepcopy(result["labels"])
    extensions = append_thameslink_artwork(
        root, graph, paths, segments, markers, labels_before, routes, reference
    )
    known_label_ids = {label["id"] for label in result["labels"]}
    new_labels = [label for label in labels_before if label["id"] not in known_label_ids]
    # Tier the new labels with the composer's rules, leaving authored ones alone.
    build_full_underground.apply_label_presentation_metadata(
        {"stationMarkers": markers, "labels": [label for label in new_labels if "visibilityTier" not in label]}
    )

    result["paths"] = sorted(paths.values(), key=lambda value: value["id"])
    result["segments"] = sorted(segments.values(), key=lambda value: value["id"])
    result["stationMarkers"] = sorted(markers, key=lambda value: value["stationID"])
    result["labels"] = sorted(result["labels"] + new_labels, key=lambda value: value["id"])
    result["routes"] = sorted(routes.values(), key=lambda value: value["id"])
    result["lineExtensions"] = sorted(
        result.get("lineExtensions", []) + extensions, key=lambda value: value["id"]
    )
    result["supportedLineIDs"] = [*result["supportedLineIDs"], THAMESLINK_LINE_ID]
    result["source"]["graphGeneratedAt"] = graph["generatedAt"]
    reference_alignment.apply(result, reference_data)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--svg", required=True, type=Path)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--document", required=True, type=Path)
    parser.add_argument("--reference", type=Path, default=None)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    import reference_alignment

    vector.CROP_X = 0.0
    vector.CROP_Y = 0.0
    reference_path = arguments.reference or reference_alignment.REFERENCE_PATH
    document = apply_to_document(
        json.loads(arguments.document.read_text()),
        json.loads(arguments.graph.read_text()),
        ET.parse(arguments.svg).getroot(),
        json.loads(Path(reference_path).read_text()),
    )
    arguments.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"Added Thameslink: {sum(1 for s in document['segments'] if s['lineID'] == THAMESLINK_LINE_ID)} segments")


if __name__ == "__main__":
    main()
