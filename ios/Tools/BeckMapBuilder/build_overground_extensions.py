#!/usr/bin/env python3
"""Compile the six named London Overground lines from TfL's vector map.

The station coordinates below are authoring-time ports projected onto the
official April 2026 coloured centre-lines. They deliberately use NaPTAN IDs:
several Overground stations share a public interchange name while occupying a
separate node on the diagram.
"""

from __future__ import annotations

import math
import xml.etree.ElementTree as ET

import build_central_core_join as vector
import build_rail_extensions as rail


OVERGROUND_LINE_IDS = (
    "liberty", "lioness", "mildmay", "suffragette", "weaver", "windrush",
)

COLOURS = {
    "liberty": "31.069946%",
    "lioness": "97.175598%",
    "mildmay": "13.98468%",
    "suffragette": "35.00061%",
    "weaver": "69.009399%",
    "windrush": "92.900085%",
}

FINGERPRINTS = {
    "liberty": (
        rail.Fingerprint(1, 1, (3940.062, 1171.437), (3772.188, 1003.578)),
    ),
    "lioness": (
        rail.Fingerprint(1, 19, (1155.547, 430.172), (1962.828, 1345.609)),
    ),
    "mildmay": (
        rail.Fingerprint(1, 13, (588.688, 2167.750), (1014.016, 1371.297)),
        rail.Fingerprint(2, 1, (1014.016, 1420.547), (1014.016, 1371.297)),
        rail.Fingerprint(3, 43, (3189.578, 1269.313), (1477.407, 2266.062)),
    ),
    "suffragette": (
        rail.Fingerprint(1, 21, (3582.172, 1527.766), (1957.438, 1048.813)),
        rail.Fingerprint(2, 6, (3782.641, 1617.547), (3582.125, 1527.781)),
    ),
    "weaver": (
        rail.Fingerprint(1, 2, (2708.250, 670.625), (2884.484, 482.797)),
        rail.Fingerprint(2, 4, (2831.172, 1175.422), (2708.250, 553.969)),
        rail.Fingerprint(3, 5, (2838.984, 1349.469), (2407.234, 1464.203)),
        rail.Fingerprint(4, 7, (2986.344, 648.812), (2832.703, 1355.750)),
        rail.Fingerprint(5, 2, (2831.172, 1175.422), (2822.891, 1365.562)),
        rail.Fingerprint(6, 1, (2715.828, 1379.344), (2694.734, 1379.344)),
    ),
    "windrush": (
        rail.Fingerprint(1, 21, (2677.953, 2140.328), (1509.797, 2295.328)),
        rail.Fingerprint(2, 2, (2704.937, 2100.141), (2665.344, 2152.953)),
        rail.Fingerprint(3, 4, (2704.937, 2419.187), (2572.000, 2563.844)),
        rail.Fingerprint(4, 2, (2704.938, 2138.078), (2741.859, 2186.734)),
        rail.Fingerprint(5, 7, (2704.938, 2643.000), (2456.438, 1205.469)),
    ),
}

p = rail.p
s = rail.s

TRACES = (
    rail.TraceSpec(
        "liberty.romford-upminster.official.v1", "liberty",
        (p(1, (3772.188, 1003.578), (3940.062, 1171.437)),),
        (
            s("910GROMFORD", 3772.188, 1003.578),
            s("910GEMRSPKH", 3868.716, 1100.097),
            s("910GUPMNSTR", 3940.062, 1171.437),
        ),
    ),
    rail.TraceSpec(
        "lioness.euston-watford.official.v1", "lioness",
        (p(1, (1962.828, 1345.609), (1155.547, 430.172)),),
        (
            s("910GEUSTON", 1962.828, 1345.609),
            s("910GSHMPSTD", 1737.692, 1254.708),
            s("910GKLBRNHR", 1650.000, 1254.708),
            s("910GQPRK", 1533.200, 1305.156),
            s("910GKENSLG", 1232.100, 1305.156),
            s("910GWLSDJHL", 1155.547, 1159.117),
            s("910GHARLSDN", 1155.547, 1125.584),
            s("910GSTNBGPK", 1155.547, 1089.655),
            s("910GWMBY", 1155.547, 1050.533),
            s("910GNWEMBLY", 1155.547, 1011.411),
            s("910GSKENTON", 1155.547, 974.685),
            s("910GKTON", 1155.547, 899.635),
            s("910GHROW", 1155.547, 783.067),
            s("910GHEDSTNL", 1155.547, 732.768),
            s("910GHTCHEND", 1155.547, 671.291),
            s("910GCRPNDPK", 1155.547, 613.805),
            s("910GBUSHYDC", 1155.547, 551.530),
            s("910GWATFDHS", 1155.547, 487.657),
            s("910GWATFJDC", 1155.547, 430.172),
        ),
    ),
    rail.TraceSpec(
        "mildmay.stratford-clapham.official.v1", "mildmay",
        (p(3, (3189.578, 1269.313), (1477.407, 2266.062)),),
        (
            s("910GSTFD", 3189.578, 1269.313),
            s("910GHACKNYW", 3076.593, 1269.313),
            s("910GHOMRTON", 2990.655, 1269.313),
            s("910GHACKNYC", 2905.590, 1269.313),
            s("910GDALSKLD", 2598.281, 1174.970),
            s("910GCNNB", 2534.490, 1174.973),
            s("910GHGHI", 2467.879, 1174.976),
            s("910GCLDNNRB", 2333.953, 1174.982),
            s("910GCMDNRD", 2104.773, 1175.047),
            s("910GKNTSHTW", 2011.532, 1118.500),
            s("910GGOSPLOK", 1958.713, 1090.408),
            s("910GHMPSTDH", 1817.694, 1090.438),
            s("910GFNCHLYR", 1705.620, 1164.710),
            s("910GWHMDSTD", 1544.828, 1174.922),
            s("910GBRBY", 1405.247, 1174.922),
            s("910GBRBYPK", 1334.264, 1174.922),
            s("910GKENR", 1232.263, 1174.922),
            s("910GWLSDJHL", 1070.759, 1180.501),
            s("910GSHPDSB", 1275.747, 1701.756),
            s("910GKENOLYM", 1306.969, 1766.473),
            s("910GWBRMPTN", 1306.969, 1947.455),
            s("910GCSEAH", 1440.907, 2110.707),
            s("910GCLPHMJC", 1477.407, 2266.062),
        ),
    ),
    rail.TraceSpec(
        "mildmay.willesden-richmond.official.v1", "mildmay",
        (
            p(3, (1070.759, 1180.501), (1014.016, 1420.547)),
            p(2, (1014.016, 1420.547), (1014.016, 1371.297)),
            p(1, (1014.016, 1371.297), (588.688, 2167.750)),
        ),
        (
            s("910GWLSDJHL", 1070.754, 1180.504),
            s("910GACTNCTL", 891.000, 1727.039),
            s("910GSACTON", 891.000, 1779.355),
            s("910GGNRSBRY", 795.465, 1960.973),
            s("910GKEWGRDN", 687.072, 2069.366),
            s("910GRICHMND", 606.363, 2150.075),
        ),
    ),
    rail.TraceSpec(
        "suffragette.gospel-barking-riverside.official.v1", "suffragette",
        (
            p(1, (1957.438, 1048.813), (3582.172, 1527.766)),
            p(2, (3582.125, 1527.781), (3782.641, 1617.547)),
        ),
        (
            s("910GGOSPLOK", 1958.668, 1048.813),
            s("910GUPRHLWY", 2223.615, 887.516),
            s("910GCROUCHH", 2262.918, 887.516),
            s("910GHRGYGL", 2582.145, 887.543),
            s("910GSTOTNHM", 2797.191, 887.662),
            s("910GBLCHSRD", 2893.389, 953.576),
            s("910GWLTHQRD", 2934.622, 994.810),
            s("910GLEYTNMR", 3077.761, 1112.344),
            s("910GLYTNSHR", 3229.876, 1112.344),
            s("910GWNSTDPK", 3408.458, 1223.036),
            s("910GWDGRNPK", 3492.746, 1307.332),
            s("910GBARKING", 3587.523, 1533.187),
            s("910GBARKRIV", 3782.641, 1617.547),
        ),
    ),
    rail.TraceSpec(
        "weaver.liverpool-chingford.official.v1", "weaver",
        (
            p(3, (2407.234, 1464.203), (2838.984, 1349.469)),
            p(5, (2822.891, 1365.562), (2831.172, 1175.422)),
            p(4, (2855.500, 1182.500), (2986.344, 648.812)),
        ),
        (
            s("910GLIVST", 2444.880, 1426.488),
            s("910GBTHNLGR", 2724.905, 1379.344),
            s("910GCAMHTH", 2789.872, 1379.344),
            s("910GLONFLDS", 2831.114, 1297.101),
            # Both Weaver branches use the same Hackney Downs roundel. The
            # Chingford artwork approaches the branch junction from the east;
            # anchoring the semantic stop lower down the shared stem created a
            # second circle, a long vertical connector, and a visible hook.
            s("910GHAKNYNM", 2831.172, 1175.422),
            s("910GCLAPTON", 2889.311, 1137.033),
            s("910GSTJMSST", 2940.215, 1086.129),
            s("910GWLTWCEN", 2986.293, 954.805),
            s("910GWDST", 2986.310, 851.276),
            s("910GHGHMSPK", 2986.327, 748.398),
            s("910GCHINGFD", 2986.344, 648.812),
        ),
    ),
    rail.TraceSpec(
        "weaver.hackney-enfield.official.v1", "weaver",
        (p(2, (2831.172, 1175.422), (2708.250, 553.969)),),
        (
            s("910GHAKNYNM", 2831.172, 1175.422),
            s("910GRCTRYRD", 2765.763, 1098.435),
            s("910GSTKNWNG", 2711.178, 1041.119),
            s("910GSTMFDHL", 2708.250, 1001.757),
            s("910GSEVNSIS", 2708.250, 935.207),
            s("910GBRUCGRV", 2708.250, 820.170),
            s("910GWHHRTLA", 2708.250, 775.011),
            s("910GSIVRST", 2708.250, 729.852),
            s("910GEDMNGRN", 2708.250, 670.432),
            s("910GBHILLPK", 2708.250, 611.487),
            s("910GENFLDTN", 2708.250, 555.395),
        ),
    ),
    rail.TraceSpec(
        "weaver.edmonton-cheshunt.official.v1", "weaver",
        (p(1, (2708.250, 670.625), (2884.484, 482.797)),),
        (
            s("910GEDMNGRN", 2708.250, 670.625),
            s("910GSBURY", 2757.621, 609.660),
            s("910GTURKYST", 2811.895, 555.386),
            s("910GTHBLDSG", 2861.464, 505.817),
            s("910GCHESHNT", 2884.484, 482.797),
        ),
    ),
    rail.TraceSpec(
        "windrush.highbury-west-croydon.official.v1", "windrush",
        (p(5, (2456.438, 1205.469), (2704.938, 2643.000)),),
        (
            s("910GHGHI", 2467.730, 1205.469),
            s("910GCNNB", 2534.278, 1205.469),
            s("910GDALS", 2575.231, 1205.469),
            s("910GHAGGERS", 2661.692, 1248.330),
            s("910GHOXTON", 2704.938, 1323.131),
            s("910GSHRDHST", 2704.938, 1415.589),
            s("910GWCHAPEL", 2704.938, 1567.005),
            s("910GSHADWEL", 2704.938, 1718.422),
            s("910GWAPPING", 2704.938, 1789.440),
            s("910GRTHERHI", 2704.938, 1876.538),
            s("910GCNDAW", 2704.938, 1942.197),
            s("910GSURREYQ", 2704.938, 2007.855),
            s("910GNEWXGTE", 2704.938, 2222.250),
            s("910GBROCKLY", 2704.938, 2293.268),
            s("910GHONROPK", 2704.938, 2332.127),
            s("910GFORESTH", 2704.938, 2369.646),
            s("910GSYDENHM", 2704.938, 2404.486),
            s("910GPENEW", 2704.938, 2452.724),
            s("910GANERLEY", 2704.938, 2492.924),
            s("910GNORWDJ", 2704.938, 2539.822),
            s("910GWCROYDN", 2704.938, 2624.240),
        ),
    ),
    rail.TraceSpec(
        "windrush.surrey-new-cross.official.v1", "windrush",
        (
            p(5, (2704.938, 2007.855), (2704.938, 2138.078)),
            p(4, (2704.938, 2138.078), (2741.859, 2186.734)),
        ),
        (
            s("910GSURREYQ", 2704.938, 2007.855),
            s("910GNWCRELL", 2741.859, 2186.734),
        ),
    ),
    rail.TraceSpec(
        "windrush.sydenham-crystal-palace.official.v1", "windrush",
        (
            p(5, (2704.938, 2404.486), (2704.937, 2419.187)),
            p(3, (2704.937, 2419.187), (2572.000, 2563.844)),
        ),
        (
            s("910GSYDENHM", 2704.938, 2404.486),
            s("910GCRYSTLP", 2572.000, 2563.844),
        ),
    ),
    rail.TraceSpec(
        "windrush.surrey-clapham.official.v1", "windrush",
        (
            p(5, (2704.938, 2007.855), (2704.938, 2140.328)),
            p(1, (2677.953, 2140.328), (1509.797, 2295.328)),
        ),
        (
            s("910GSURREYQ", 2704.938, 2007.855),
            s("910GPCKHMQD", 2459.695, 2224.891),
            s("910GPCKHMRY", 2399.454, 2285.102),
            s("910GDENMRKH", 2264.350, 2308.562),
            s("910GCLPHHS", 1711.588, 2295.328),
            s("910GWNDSWRD", 1679.614, 2295.328),
            s("910GCLPHMJ1", 1509.797, 2295.328),
        ),
    ),
)


def _append_graph_routes(graph: dict, routes: dict[str, dict]) -> None:
    segments_by_pair = {
        (segment["lineID"], frozenset((segment["fromStationID"], segment["toStationID"]))): segment["id"]
        for segment in graph["segments"]
    }
    for line_id in OVERGROUND_LINE_IDS:
        line = next(line for line in graph["lines"] if line["id"] == line_id)
        for route_index, station_ids in enumerate(line["routes"]):
            segment_ids = [
                segments_by_pair[(line_id, frozenset((first, second)))]
                for first, second in zip(station_ids, station_ids[1:])
            ]
            route_id = f"{line_id}.graph-route.{route_index}.v1"
            routes[route_id] = {
                "id": route_id,
                "lineID": line_id,
                "stationIDs": station_ids,
                "segmentIDs": segment_ids,
            }


def append_overground_artwork(
    root: ET.Element,
    graph: dict,
    selected_paths: dict[str, dict],
    selected_segments: dict[str, dict],
    markers: list[dict],
    labels: list[dict],
    routes: dict[str, dict],
) -> None:
    """Append exact Overground centre-lines and all 111 graph semantics."""
    graph_segments = {segment["id"]: segment for segment in graph["segments"]}
    expected = {
        segment["id"] for segment in graph["segments"]
        if segment["lineID"] in OVERGROUND_LINE_IDS
    }
    preexisting = expected.intersection(selected_segments)
    if preexisting:
        raise ValueError(f"Overground segments already exist: {sorted(preexisting)}")

    masters_by_line = {
        line_id: rail._master_paths(root, COLOURS[line_id], FINGERPRINTS[line_id])
        for line_id in OVERGROUND_LINE_IDS
    }
    ports_by_station: dict[str, list[tuple[str, vector.Match]]] = {}
    original_join_tolerance = rail.JOIN_TOLERANCE
    rail.JOIN_TOLERANCE = 40.0
    try:
        for trace in TRACES:
            rail._compile_trace(
                trace,
                masters_by_line[trace.line_id],
                graph_segments,
                selected_paths,
                selected_segments,
                ports_by_station,
            )
    finally:
        rail.JOIN_TOLERANCE = original_join_tolerance

    actual = expected.intersection(selected_segments)
    if actual != expected:
        raise ValueError(
            f"Official Overground compilation is missing graph segments: {sorted(expected - actual)}"
        )

    stations_by_id = {station["id"]: station for station in graph["stations"]}
    existing_marker_by_hub = {
        stations_by_id[marker["stationID"]].get("hubID") or marker["stationID"]: marker
        for marker in markers
    }
    existing_marker_by_station = {marker["stationID"]: marker for marker in markers}
    marker_start = len(markers)
    rail._append_markers_and_labels(graph, ports_by_station, markers, labels)

    # Overground platforms are often offset from their Underground or DLR
    # roundel. Keep both official ports and show the interchange explicitly.
    new_markers = markers[marker_start:]
    del markers[marker_start:]
    for marker in new_markers:
        station = stations_by_id[marker["stationID"]]
        same_station = existing_marker_by_station.get(marker["stationID"])
        if same_station is not None:
            start = (same_station["anchor"]["x"], same_station["anchor"]["y"])
            end = (marker["anchor"]["x"], marker["anchor"]["y"])
            if math.dist(start, end) > 4:
                same_station["primitives"].append(rail._connector(start, end))
            # A station shared with an earlier rail mode can resolve to two
            # near-identical points on parallel source strokes (Romford is
            # about 2.4 artwork units apart). Treat those as one physical
            # roundel instead of drawing two heavy rings on top of each other.
            existing_circles = [
                (
                    primitive["circle"]["centre"]["x"],
                    primitive["circle"]["centre"]["y"],
                )
                for primitive in same_station["primitives"]
                if primitive["kind"] == "circle"
            ]
            for primitive in marker["primitives"]:
                if primitive["kind"] == "circle":
                    centre = (
                        primitive["circle"]["centre"]["x"],
                        primitive["circle"]["centre"]["y"],
                    )
                    if any(math.dist(centre, prior) <= 5 for prior in existing_circles):
                        continue
                    existing_circles.append(centre)
                same_station["primitives"].append(primitive)
            same_station["lineIDs"] = station["lineIDs"]
            continue

        hub_id = station.get("hubID") or station["id"]
        existing = existing_marker_by_hub.get(hub_id)
        if existing is None:
            markers.append(marker)
            # Later markers in this same Overground pass may represent a
            # second physical node in the hub. Clapham Junction is split this
            # way between the Mildmay and Windrush lines.
            existing_marker_by_hub[hub_id] = marker
            continue
        start = (existing["anchor"]["x"], existing["anchor"]["y"])
        end = (marker["anchor"]["x"], marker["anchor"]["y"])
        if 4 < math.dist(start, end) < 180:
            marker["primitives"].insert(0, rail._connector(start, end))
            # Markers render in station-ID order. Redraw an earlier endpoint
            # after its connector so the bar cannot paint through its roundel.
            if existing["stationID"] < marker["stationID"]:
                marker["primitives"].insert(1, rail._circle(start))
        markers.append(marker)

    _append_graph_routes(graph, routes)
