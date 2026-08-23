#!/usr/bin/env python3
"""Compile London Trams from the official TfL standard-map vectors.

TfL's green route is five separate master paths.  Their endpoints are joins,
not necessarily stop centres: the Croydon loop, the Wandle Park chord and the
Elmers End spur all meet the main route just beside a stop symbol.  Segment
ports therefore follow those exact vector joins, while station roundels use
the official stop-symbol centres projected onto the green route.
"""

from __future__ import annotations

import math
import xml.etree.ElementTree as ET

import build_central_core_join as vector
import build_rail_extensions as rail


TRAM_LINE_ID = "tram"
TRAM_COLOUR = "41.191101%"  # rgb(105, 194, 47), #69C22F
TRAM_HEX_COLOUR = "#69C22F"
OFFICIAL_OUTER_STROKE_WIDTH = 2.211
OFFICIAL_INNER_STROKE_WIDTH = 0.692


FINGERPRINTS = (
    rail.Fingerprint(1, 4, (3804.578, 2514.875), (3179.219, 2756.719)),
    rail.Fingerprint(2, 2, (3436.563, 2575.516), (3364.094, 2584.359)),
    rail.Fingerprint(3, 2, (2478.203, 2756.656), (2572.422, 2682.281)),
    rail.Fingerprint(4, 9, (2900.563, 2756.703), (2603.188, 2756.672)),
    rail.Fingerprint(5, 12, (1387.281, 2406.609), (3416.859, 2982.078)),
)


p = rail.p
s = rail.s


# Five non-overlapping traces cover the 40 unique TfL semantic edges.  The
# fourth path is the one-way Croydon loop, including the Centrale-Church Street
# chord; routes remain directional in TubeGraph rather than in this artwork.
TRACES = (
    rail.TraceSpec(
        "tram.wimbledon-new-addington.official.v1",
        TRAM_LINE_ID,
        (p(5, (1387.281, 2406.609), (3416.859, 2982.078)),),
        (
            s("940GZZCRWMB", 1387.281, 2406.609),
            s("940GZZCRDDR", 1387.281, 2480.502),
            s("940GZZCRMTP", 1387.281, 2565.602),
            s("940GZZCRMDN", 1604.717, 2756.578),
            s("940GZZCRPHI", 1697.996, 2756.578),
            s("940GZZCRBGV", 1795.839, 2756.597),
            s("940GZZCRMCH", 1889.901, 2756.607),
            s("940GZZCRMJT", 2035.268, 2756.621),
            s("940GZZCRBED", 2126.887, 2756.631),
            s("940GZZCRTPA", 2217.283, 2756.640),
            s("940GZZCRAMP", 2301.572, 2756.649),
            s("940GZZCRWAD", 2383.418, 2756.657),
            s("940GZZCRWAN", 2461.599, 2756.665),
            s("940GZZCRCHR", 2641.171, 2756.683),
            s("940GZZCRCEN", 2748.670, 2756.694),
            s("940GZZCRECR", 2935.571, 2756.714),
            s("940GZZCRLEB", 3039.713, 2756.719),
            s("940GZZCRSAN", 3140.106, 2756.719),
            s("940GZZCRLOY", 3224.100, 2789.558),
            s("940GZZCRCOO", 3256.328, 2821.747),
            s("940GZZCRGRA", 3285.948, 2851.330),
            s("940GZZCRADV", 3316.621, 2881.965),
            s("940GZZCRFLD", 3347.611, 2912.917),
            s("940GZZCRKGH", 3380.848, 2946.112),
            s("940GZZCRNWA", 3416.859, 2982.078),
        ),
    ),
    rail.TraceSpec(
        "tram.beckenham-sandilands.official.v1",
        TRAM_LINE_ID,
        (p(1, (3804.578, 2514.875), (3179.219, 2756.719)),),
        (
            s("940GZZCRBEK", 3804.578, 2514.875),
            s("940GZZCRBRD", 3709.221, 2514.875),
            s("940GZZCRAVE", 3625.336, 2514.875),
            s("940GZZCRBIR", 3551.488, 2514.875),
            s("940GZZCRHAR", 3466.169, 2514.875),
            s("940GZZCRARA", 3351.430, 2597.013),
            s("940GZZCRWOD", 3317.587, 2630.858),
            s("940GZZCRBLA", 3281.055, 2667.393),
            s("940GZZCRADD", 3238.695, 2709.755),
            # This master joins the main route just east of the Sandilands
            # symbol.  Keeping the join as the semantic port avoids a fake
            # straight bridge across TfL's curved junction.
            s("940GZZCRSAN", 3179.219, 2756.719),
        ),
    ),
    rail.TraceSpec(
        "tram.elmers-end-arena.official.v1",
        TRAM_LINE_ID,
        (p(2, (3436.563, 2575.516), (3364.094, 2584.359)),),
        (
            s("940GZZCRELM", 3434.876, 2575.515),
            s("940GZZCRARA", 3364.094, 2584.359),
        ),
    ),
    rail.TraceSpec(
        "tram.wandle-centrale.official.v1",
        TRAM_LINE_ID,
        (p(3, (2478.203, 2756.656), (2572.422, 2682.281)),),
        (
            s("940GZZCRWAN", 2478.203, 2756.656),
            s("940GZZCRRVC", 2536.805, 2717.878),
            s("940GZZCRCTR", 2572.422, 2682.281),
        ),
    ),
    rail.TraceSpec(
        "tram.east-croydon-church-via-loop.official.v1",
        TRAM_LINE_ID,
        (p(4, (2900.563, 2756.703), (2603.188, 2756.672)),),
        (
            s("940GZZCRECR", 2900.563, 2756.703),
            s("940GZZCRWEL", 2747.860, 2669.516),
            s("940GZZCRWCR", 2670.517, 2669.516),
            s("940GZZCRCTR", 2615.963, 2669.516),
            s("940GZZCRCHR", 2603.188, 2756.672),
        ),
    ),
)


# Official stop-symbol centres.  At branch joins these intentionally differ
# from a semantic port above: TfL places one stop ring on the through route and
# lets the thin green branch meet immediately beside it.
MARKER_ANCHORS: dict[str, vector.Point] = {
    "940GZZCRWMB": (1387.281, 2406.609),
    "940GZZCRDDR": (1387.281, 2480.502),
    "940GZZCRMTP": (1387.281, 2565.602),
    "940GZZCRMDN": (1604.717, 2756.578),
    "940GZZCRPHI": (1697.996, 2756.578),
    "940GZZCRBGV": (1795.839, 2756.597),
    "940GZZCRMCH": (1889.901, 2756.607),
    "940GZZCRMJT": (2035.268, 2756.621),
    "940GZZCRBED": (2126.887, 2756.631),
    "940GZZCRTPA": (2217.283, 2756.640),
    "940GZZCRAMP": (2301.572, 2756.649),
    "940GZZCRWAD": (2383.418, 2756.657),
    "940GZZCRWAN": (2461.599, 2756.665),
    "940GZZCRRVC": (2536.805, 2717.878),
    "940GZZCRCTR": (2615.963, 2669.516),
    "940GZZCRWCR": (2670.517, 2669.516),
    "940GZZCRWEL": (2747.860, 2669.516),
    "940GZZCRCHR": (2641.171, 2756.683),
    "940GZZCRCEN": (2748.670, 2756.694),
    "940GZZCRECR": (2935.571, 2756.714),
    "940GZZCRLEB": (3039.713, 2756.719),
    "940GZZCRSAN": (3140.106, 2756.719),
    "940GZZCRLOY": (3224.100, 2789.558),
    "940GZZCRCOO": (3256.328, 2821.747),
    "940GZZCRGRA": (3285.948, 2851.330),
    "940GZZCRADV": (3316.621, 2881.965),
    "940GZZCRFLD": (3347.611, 2912.917),
    "940GZZCRKGH": (3380.848, 2946.112),
    "940GZZCRNWA": (3416.859, 2982.078),
    "940GZZCRADD": (3238.695, 2709.755),
    "940GZZCRBLA": (3281.055, 2667.393),
    "940GZZCRWOD": (3317.587, 2630.858),
    "940GZZCRARA": (3351.430, 2597.013),
    "940GZZCRHAR": (3466.169, 2514.875),
    "940GZZCRBIR": (3551.488, 2514.875),
    "940GZZCRAVE": (3625.336, 2514.875),
    "940GZZCRBRD": (3709.221, 2514.875),
    "940GZZCRBEK": (3804.578, 2514.875),
    "940GZZCRELM": (3434.876, 2575.515),
}


LABEL_TEXT = {
    "940GZZCRDDR": "Dundonald\nRoad",
    "940GZZCRMTP": "Merton\nPark",
    "940GZZCRMDN": "Morden\nRoad",
    "940GZZCRPHI": "Phipps\nBridge",
    "940GZZCRBGV": "Belgrave\nWalk",
    "940GZZCRMJT": "Mitcham\nJunction",
    "940GZZCRBED": "Beddington\nLane",
    "940GZZCRTPA": "Therapia\nLane",
    "940GZZCRAMP": "Ampere\nWay",
    "940GZZCRWAD": "Waddon\nMarsh",
    "940GZZCRWAN": "Wandle\nPark",
    "940GZZCRRVC": "Reeves\nCorner",
    "940GZZCRWEL": "Wellesley\nRoad",
    "940GZZCRCEN": "George\nStreet",
    "940GZZCRECR": "East\nCroydon",
    "940GZZCRLEB": "Lebanon\nRoad",
    "940GZZCRLOY": "Lloyd Park",
    "940GZZCRCOO": "Coombe Lane",
    "940GZZCRGRA": "Gravel Hill",
    "940GZZCRADV": "Addington Village",
    "940GZZCRFLD": "Fieldway",
    "940GZZCRKGH": "King Henry's Drive",
    "940GZZCRNWA": "New Addington",
    "940GZZCRBLA": "Blackhorse Lane",
    "940GZZCRHAR": "Harrington\nRoad",
    "940GZZCRAVE": "Avenue\nRoad",
    "940GZZCRBRD": "Beckenham\nRoad",
    "940GZZCRBEK": "Beckenham\nJunction",
    "940GZZCRELM": "Elmers End",
}


# Positions follow the same side of each stroke as the standard map.  Dense
# horizontal runs are centred below their stop; branch labels sit outside the
# diagonal so the route remains readable at phone zoom levels.
LABEL_LAYOUTS: dict[str, tuple[float, float, str]] = {
    "940GZZCRDDR": (18, 0, "leading"),
    "940GZZCRMTP": (18, 0, "leading"),
    "940GZZCRMDN": (0, 24, "centre"),
    "940GZZCRPHI": (0, 24, "centre"),
    "940GZZCRBGV": (0, 24, "centre"),
    "940GZZCRMCH": (0, 24, "centre"),
    "940GZZCRMJT": (0, 24, "centre"),
    "940GZZCRBED": (0, 24, "centre"),
    "940GZZCRTPA": (0, 24, "centre"),
    "940GZZCRAMP": (0, 24, "centre"),
    "940GZZCRWAD": (0, 24, "centre"),
    "940GZZCRWAN": (0, 24, "centre"),
    "940GZZCRRVC": (-16, -10, "trailing"),
    "940GZZCRCTR": (0, 21, "centre"),
    "940GZZCRWEL": (0, 22, "centre"),
    "940GZZCRCHR": (0, 24, "centre"),
    "940GZZCRCEN": (0, 24, "centre"),
    "940GZZCRECR": (0, -22, "centre"),
    "940GZZCRLEB": (0, 24, "centre"),
    "940GZZCRSAN": (0, -20, "centre"),
    "940GZZCRLOY": (-17, 7, "trailing"),
    "940GZZCRCOO": (-17, 7, "trailing"),
    "940GZZCRGRA": (-17, 7, "trailing"),
    "940GZZCRADV": (-17, 7, "trailing"),
    "940GZZCRFLD": (-17, 7, "trailing"),
    "940GZZCRKGH": (-17, 7, "trailing"),
    "940GZZCRNWA": (-17, 7, "trailing"),
    "940GZZCRADD": (17, 7, "leading"),
    "940GZZCRBLA": (17, 7, "leading"),
    "940GZZCRWOD": (17, 7, "leading"),
    "940GZZCRARA": (17, 7, "leading"),
    "940GZZCRHAR": (0, 22, "centre"),
    "940GZZCRBIR": (0, 22, "centre"),
    "940GZZCRAVE": (0, 22, "centre"),
    "940GZZCRBRD": (0, 22, "centre"),
    "940GZZCRBEK": (0, 22, "centre"),
    "940GZZCRELM": (0, 22, "centre"),
}


def _append_graph_routes(graph: dict, routes: dict[str, dict]) -> None:
    segments_by_pair = {
        (segment["lineID"], frozenset((segment["fromStationID"], segment["toStationID"]))):
            segment["id"]
        for segment in graph["segments"]
    }
    line = next(line for line in graph["lines"] if line["id"] == TRAM_LINE_ID)
    for route_index, station_ids in enumerate(line["routes"]):
        segment_ids = [
            segments_by_pair[(TRAM_LINE_ID, frozenset((first, second)))]
            for first, second in zip(station_ids, station_ids[1:])
        ]
        route_id = f"tram.graph-route.{route_index}.v1"
        routes[route_id] = {
            "id": route_id,
            "lineID": TRAM_LINE_ID,
            "stationIDs": station_ids,
            "segmentIDs": segment_ids,
        }


def _validate_parallel_source_style(root: ET.Element) -> None:
    """Require TfL's five green strokes and their matching white insets.

    In the current SVG export, the long Wimbledon-New Addington inset omits a
    tiny clipped lead-in curve that remains on the green stroke.  Compare the
    transformed endpoints (and near-equal curve counts) rather than raw SVG
    ``d`` strings so that exporter detail does not masquerade as a style
    change.
    """
    outer = [
        element for element in root.iter()
        if element.tag.endswith("path")
        and TRAM_COLOUR in element.get("stroke", "")
        and element.get("d")
        and math.isclose(
            float(element.get("stroke-width", "nan")),
            OFFICIAL_OUTER_STROKE_WIDTH,
            abs_tol=0.0001,
        )
    ]
    inset_curves = [
        vector.parse_path(
            element.get("d", ""),
            vector.parse_matrix(element.get("transform")),
        )
        for element in root.iter()
        if element.tag.endswith("path")
        and element.get("stroke") == "rgb(100%, 100%, 100%)"
        and element.get("d")
        and math.isclose(
            float(element.get("stroke-width", "nan")),
            OFFICIAL_INNER_STROKE_WIDTH,
            abs_tol=0.0001,
        )
    ]
    missing_insets = []
    for element in outer:
        outer_curves = vector.parse_path(
            element.get("d", ""),
            vector.parse_matrix(element.get("transform")),
        )
        matching_inset = any(
            abs(len(candidate) - len(outer_curves)) <= 1
            and math.dist(candidate[0].start, outer_curves[0].start)
            + math.dist(candidate[-1].end, outer_curves[-1].end) <= 0.05
            for candidate in inset_curves
        )
        if not matching_inset:
            missing_insets.append(element)
    if len(outer) != len(FINGERPRINTS) or missing_insets:
        raise ValueError(
            "London Trams source style changed: expected five #69C22F "
            "2.211-wide masters with matching 0.692 white insets"
        )


def _append_markers_and_labels(
    graph: dict,
    markers: list[dict],
    labels: list[dict],
) -> None:
    stations_by_id = {station["id"]: station for station in graph["stations"]}
    tram_station_ids = {
        station["id"] for station in graph["stations"]
        if TRAM_LINE_ID in station["lineIDs"]
    }
    if set(MARKER_ANCHORS) != tram_station_ids:
        raise ValueError(
            "Official Tram marker inventory differs from TubeGraph: "
            f"missing={sorted(tram_station_ids - set(MARKER_ANCHORS))}, "
            f"extra={sorted(set(MARKER_ANCHORS) - tram_station_ids)}"
        )

    existing_marker_by_hub = {
        stations_by_id[marker["stationID"]].get("hubID") or marker["stationID"]: marker
        for marker in markers
    }
    existing_hubs = set(existing_marker_by_hub)

    for station_id in sorted(MARKER_ANCHORS):
        station = stations_by_id[station_id]
        anchor = MARKER_ANCHORS[station_id]
        primitives = [rail._circle(anchor)]
        hub_id = station.get("hubID") or station_id
        existing = existing_marker_by_hub.get(hub_id)
        if existing is not None:
            existing_anchor = (existing["anchor"]["x"], existing["anchor"]["y"])
            distance = math.dist(existing_anchor, anchor)
            if not 4 < distance < 180:
                raise ValueError(
                    f"Tram interchange {station_id} has implausible connector {distance:.3f}"
                )
            primitives.insert(0, rail._connector(existing_anchor, anchor))

            # Markers are sorted by station ID in the generated document.  At
            # West Croydon the existing Overground marker is therefore drawn
            # before this Tram marker, so its connector would otherwise paint
            # across the earlier roundel.  Redraw that endpoint above the
            # connector; Wimbledon is already safe because its Underground
            # marker sorts after the Tram marker.
            if existing["stationID"] < station_id:
                primitives.insert(1, rail._circle(existing_anchor))

            # Wimbledon is an ordinary District tick in the Underground-only
            # artwork.  Once its separate Tram stop is present, TfL shows two
            # roundels connected across the National Rail platforms.
            if station_id == "940GZZCRWMB":
                preserved = [
                    primitive for primitive in existing["primitives"]
                    if primitive["kind"] not in {"tick", "circle"}
                ]
                existing["primitives"] = [*preserved, rail._circle(existing_anchor)]
                existing["hitRadius"] = 14

        markers.append({
            "stationID": station_id,
            "name": station["name"],
            "lineIDs": station["lineIDs"],
            "anchor": vector.rounded(anchor),
            "hitRadius": 14,
            "primitives": primitives,
        })

        # Wimbledon and West Croydon already have a label owned by the other
        # physical node in their hub.  A second identical label is visual noise.
        if hub_id in existing_hubs:
            continue
        dx, dy, alignment = LABEL_LAYOUTS.get(station_id, (16, -18, "leading"))
        labels.append({
            "id": f"label.{station_id}",
            "stationID": station_id,
            "text": LABEL_TEXT.get(station_id, station["name"]),
            "position": vector.rounded((anchor[0] + dx, anchor[1] + dy)),
            "alignment": alignment,
            "rotationDegrees": 0,
            "priority": 5,
        })


def append_tram_artwork(
    root: ET.Element,
    graph: dict,
    selected_paths: dict[str, dict],
    selected_segments: dict[str, dict],
    markers: list[dict],
    labels: list[dict],
    routes: dict[str, dict],
) -> None:
    """Append exact official London Trams geometry and all 40 graph edges."""
    graph_segments = {segment["id"]: segment for segment in graph["segments"]}
    expected = {
        segment["id"] for segment in graph["segments"]
        if segment["lineID"] == TRAM_LINE_ID
    }
    if len(expected) != 40:
        raise ValueError(f"Expected 40 London Trams graph edges; found {len(expected)}")
    preexisting = expected.intersection(selected_segments)
    if preexisting:
        raise ValueError(f"Tram segments already exist: {sorted(preexisting)}")

    _validate_parallel_source_style(root)
    masters = rail._master_paths(
        root,
        TRAM_COLOUR,
        FINGERPRINTS,
        outer_stroke_width=OFFICIAL_OUTER_STROKE_WIDTH,
    )
    ports_by_station: dict[str, list[tuple[str, vector.Match]]] = {}
    for trace in TRACES:
        rail._compile_trace(
            trace,
            masters,
            graph_segments,
            selected_paths,
            selected_segments,
            ports_by_station,
        )

    actual = expected.intersection(selected_segments)
    if actual != expected:
        raise ValueError(
            f"Official Tram compilation is missing graph segments: {sorted(expected - actual)}"
        )

    _append_markers_and_labels(graph, markers, labels)
    _append_graph_routes(graph, routes)
