#!/usr/bin/env python3
"""Apply source-verified geometry corrections to the compiled Beck map.

These corrections are deliberately station-specific. They reproduce glyph and
connector relationships measured from the locked April 2026 TfL vector map;
they are not a general-purpose schematic layout algorithm.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
from pathlib import Path


Point = tuple[float, float]
TICK_HALF_LENGTH = 7.0
TICK_WIDTH = 3.2
ROUNDEL_RADIUS = 8.5
ROUNDEL_OUTLINE_WIDTH = 3.5
CONNECTOR_WIDTH = 7.5
WALKING_CONNECTOR_WIDTH = 4.5

# The Mildmay centre-line is an exact 45-degree run here. This point is the
# intersection of that source path with the official 45-degree walking link to
# the Central-line roundel.
SHEPHERDS_BUSH_MILDMAY_PORT = (1290.079, 1716.082)

# The northwest Jubilee and Metropolitan lanes run in parallel at 45 degrees.
# These station positions are traced from the locked April 2026 map.  The
# original semantic splits around West Hampstead were attached to intermediate
# points on the Jubilee path, which pulled that otherwise straight run into a
# visible kink and left the interchange bars horizontal or vertical.
NORTHWEST_INTERCHANGE_OFFSET = 19.0
WEST_HAMPSTEAD_JUBILEE_PORT = (1543.9, 1211.9)
WEST_HAMPSTEAD_MILDMAY_PORT = (1580.9, 1174.9)
FINCHLEY_ROAD_JUBILEE_PORT = (1570.0, 1238.0)
FINCHLEY_ROAD_FROGNAL_MILDMAY_PORT = (1633.1, 1174.9)
SWISS_COTTAGE_JUBILEE_PORT = (1622.0, 1290.0)
ST_JOHNS_WOOD_JUBILEE_PORT = (1677.0, 1345.0)

# Label anchors are traced independently from station glyphs. These positions
# preserve the four clear zones used by the official map around the two
# northwest walking interchanges.
NORTHWEST_LABEL_LAYOUTS = {
    "940GZZLUWHP": {
        "text": "West\nHampstead",
        "position": (1554.0, 1141.0),
        "alignment": "centre",
        "priority": 10,
        "visibilityTier": "network",
        "associatedStationIDs": ["910GWHMDSTD"],
    },
    "910GFNCHLYR": {
        "text": "Finchley Road & Frognal",
        "position": (1643.0, 1194.0),
        "alignment": "leading",
        "priority": 5,
        "visibilityTier": "minor",
    },
    "940GZZLUFYR": {
        "text": "Finchley\nRoad",
        "position": (1533.0, 1278.0),
        "alignment": "trailing",
        "priority": 10,
        "visibilityTier": "network",
    },
    "940GZZLUSWC": {
        "text": "Swiss Cottage",
        "position": (1641.0, 1292.0),
        "alignment": "leading",
        "priority": 5,
        "visibilityTier": "local",
    },
}


def _rounded(value: Point) -> dict[str, float]:
    return {"x": round(value[0], 3), "y": round(value[1], 3)}


def _point(value: dict) -> Point:
    return float(value["x"]), float(value["y"])


def _translated(value: dict, dx: float, dy: float) -> dict[str, float]:
    return _rounded((float(value["x"]) + dx, float(value["y"]) + dy))


def _circle(centre: Point) -> dict:
    return {
        "kind": "circle",
        "circle": {
            "centre": _rounded(centre),
            "radius": ROUNDEL_RADIUS,
            "outlineWidth": ROUNDEL_OUTLINE_WIDTH,
        },
    }


def _connector(start: Point, end: Point, *, walking: bool = False) -> dict:
    kind = "walkingConnector" if walking else "connector"
    return {
        "kind": kind,
        kind: {
            "start": _rounded(start),
            "end": _rounded(end),
            "width": WALKING_CONNECTOR_WIDTH if walking else CONNECTOR_WIDTH,
        },
    }


def _tick(line_id: str, centre: Point, tangent: Point) -> dict:
    magnitude = math.hypot(*tangent)
    if magnitude <= 1e-9:
        raise ValueError(f"Cannot build a tick for {line_id} from a zero tangent")
    normal = (
        -tangent[1] / magnitude * TICK_HALF_LENGTH,
        tangent[0] / magnitude * TICK_HALF_LENGTH,
    )
    return {
        "kind": "tick",
        "tick": {
            "lineID": line_id,
            "start": _rounded((centre[0] - normal[0], centre[1] - normal[1])),
            "end": _rounded((centre[0] + normal[0], centre[1] + normal[1])),
            "width": TICK_WIDTH,
        },
    }


def _translate_station_endpoint(
    segment: dict,
    path: dict,
    station_id: str,
    dx: float,
    dy: float,
) -> None:
    if segment["fromStationID"] == station_id:
        port_key = "fromPort"
        station_is_path_start = segment["pathDirection"] == "forward"
    elif segment["toStationID"] == station_id:
        port_key = "toPort"
        station_is_path_start = segment["pathDirection"] == "reverse"
    else:
        raise ValueError(f"Segment {segment['id']} does not meet station {station_id}")

    segment[port_key] = _translated(segment[port_key], dx, dy)
    command = path["commands"][0 if station_is_path_start else -1]
    if command["op"] not in {"move", "line", "cubic"} or "to" not in command:
        raise ValueError(f"Unexpected endpoint command for {segment['id']}")
    command["to"] = _translated(command["to"], dx, dy)


def _line_ports(document: dict, station_id: str, line_id: str) -> list[Point]:
    ports: list[Point] = []
    for segment in document["segments"]:
        if segment["lineID"] != line_id:
            continue
        if segment["fromStationID"] == station_id:
            ports.append(_point(segment["fromPort"]))
        if segment["toStationID"] == station_id:
            ports.append(_point(segment["toPort"]))
    if not ports:
        raise ValueError(f"No {line_id} port for {station_id}")
    return ports


def _line_port(document: dict, station_id: str, line_id: str) -> Point:
    ports = _line_ports(document, station_id, line_id)
    reference = ports[0]
    if any(math.dist(reference, candidate) > 0.01 for candidate in ports[1:]):
        raise ValueError(f"Inconsistent {line_id} ports for {station_id}: {ports}")
    return reference


def _set_line_port(document: dict, station_id: str, line_id: str, target: Point) -> None:
    paths_by_id = {path["id"]: path for path in document["paths"]}
    matched = False
    for segment in document["segments"]:
        if segment["lineID"] != line_id or station_id not in {
            segment["fromStationID"], segment["toStationID"]
        }:
            continue
        port_key = (
            "fromPort" if segment["fromStationID"] == station_id else "toPort"
        )
        current = _point(segment[port_key])
        _translate_station_endpoint(
            segment,
            paths_by_id[segment["pathID"]],
            station_id,
            target[0] - current[0],
            target[1] - current[1],
        )
        matched = True
    if not matched:
        raise ValueError(f"No {line_id} segment meets {station_id}")


def _replace_segment_commands(
    document: dict,
    segment_id: str,
    commands: list[dict],
) -> None:
    segment = next(
        segment for segment in document["segments"]
        if segment["id"] == segment_id
    )
    path = next(
        path for path in document["paths"]
        if path["id"] == segment["pathID"]
    )
    path["commands"] = commands


def _set_label_layout(
    document: dict,
    station_id: str,
    layout: dict,
) -> None:
    label = next(
        label for label in document["labels"]
        if label["stationID"] == station_id
    )
    label["text"] = layout["text"]
    label["position"] = _rounded(layout["position"])
    label["alignment"] = layout["alignment"]
    label["priority"] = layout["priority"]
    label["visibilityTier"] = layout["visibilityTier"]
    if "associatedStationIDs" in layout:
        label["associatedStationIDs"] = layout["associatedStationIDs"]


def _replace_marker(
    document: dict,
    station_id: str,
    anchor: Point,
    primitives: list[dict],
) -> None:
    anchor = _point(_rounded(anchor))
    marker = next(
        marker for marker in document["stationMarkers"]
        if marker["stationID"] == station_id
    )
    previous_anchor = _point(marker["anchor"])
    marker["anchor"] = _rounded(anchor)
    marker["primitives"] = primitives

    for label in document["labels"]:
        if label["stationID"] != station_id:
            continue
        previous_position = _point(label["position"])
        label["position"] = _rounded((
            anchor[0] + previous_position[0] - previous_anchor[0],
            anchor[1] + previous_position[1] - previous_anchor[1],
        ))


def _align_level_interchange(
    document: dict,
    underground_station_id: str,
    underground_line_id: str,
    overground_station_id: str,
) -> None:
    underground = _line_port(document, underground_station_id, underground_line_id)
    overground = _line_port(document, overground_station_id, "mildmay")
    shared_y = (underground[1] + overground[1]) / 2
    underground = underground[0], shared_y
    overground = overground[0], shared_y
    _set_line_port(document, underground_station_id, underground_line_id, underground)
    _set_line_port(document, overground_station_id, "mildmay", overground)
    _replace_marker(document, underground_station_id, underground, [_circle(underground)])
    _replace_marker(
        document,
        overground_station_id,
        overground,
        [_connector(underground, overground), _circle(overground)],
    )


def _northwest_metropolitan_port(jubilee_port: Point) -> Point:
    """Return the lower-left port on the parallel Metropolitan lane."""
    return (
        jubilee_port[0] - NORTHWEST_INTERCHANGE_OFFSET,
        jubilee_port[1] + NORTHWEST_INTERCHANGE_OFFSET,
    )


def _align_northwest_interchange(
    document: dict,
    station_id: str,
    jubilee_port: Point,
) -> None:
    metropolitan_port = _northwest_metropolitan_port(jubilee_port)
    _set_line_port(document, station_id, "jubilee", jubilee_port)
    _set_line_port(document, station_id, "metropolitan", metropolitan_port)
    _replace_marker(
        document,
        station_id,
        jubilee_port,
        [
            _connector(jubilee_port, metropolitan_port),
            _circle(jubilee_port),
            _circle(metropolitan_port),
        ],
    )


def apply(document: dict) -> int:
    """Apply deterministic corrections and return the changed target count."""
    before = copy.deepcopy(document)

    # The official symbols at both stations use level interchange bars. Their
    # route centre-lines land a few units apart because paths and glyphs were
    # extracted independently, so project both ports onto their midpoint row.
    _align_level_interchange(
        document, "940GZZLUKOY", "district", "910GKENOLYM"
    )
    _align_level_interchange(
        document, "940GZZLUWBN", "district", "910GWBRMPTN"
    )

    # Wembley Park, Willesden Green and Finchley Road use matching diagonal
    # interchange bars across two parallel 45-degree lanes. Keep the Jubilee
    # ports as the visual authority at the first two stations, then place the
    # Metropolitan lane by the same perpendicular offset at all three.
    wembley_jubilee = _line_port(document, "940GZZLUWYP", "jubilee")
    willesden_jubilee = _line_port(document, "940GZZLUWIG", "jubilee")
    _align_northwest_interchange(
        document, "940GZZLUWYP", wembley_jubilee
    )
    _align_northwest_interchange(
        document, "940GZZLUWIG", willesden_jubilee
    )
    _align_northwest_interchange(
        document, "940GZZLUFYR", FINCHLEY_ROAD_JUBILEE_PORT
    )

    # The West Hampstead Underground and Mildmay stations are distinct stops
    # joined by the official short walking link. Reattach the Underground stop
    # to its traced point on the straight Jubilee run and put the Mildmay
    # roundel above-right on the horizontal Overground corridor.
    _set_line_port(
        document,
        "940GZZLUWHP",
        "jubilee",
        WEST_HAMPSTEAD_JUBILEE_PORT,
    )
    _set_line_port(
        document,
        "910GWHMDSTD",
        "mildmay",
        WEST_HAMPSTEAD_MILDMAY_PORT,
    )
    _replace_marker(
        document,
        "940GZZLUWHP",
        WEST_HAMPSTEAD_JUBILEE_PORT,
        [_circle(WEST_HAMPSTEAD_JUBILEE_PORT)],
    )
    _replace_marker(
        document,
        "910GWHMDSTD",
        WEST_HAMPSTEAD_MILDMAY_PORT,
        [
            _connector(
                WEST_HAMPSTEAD_JUBILEE_PORT,
                WEST_HAMPSTEAD_MILDMAY_PORT,
                walking=True,
            ),
            _circle(WEST_HAMPSTEAD_MILDMAY_PORT),
        ],
    )

    # Finchley Road & Frognal is the next Mildmay stop to the east. It has its
    # own 45-degree walking link to the Jubilee roundel at Finchley Road; it is
    # not the endpoint of West Hampstead's walking interchange.
    _set_line_port(
        document,
        "910GFNCHLYR",
        "mildmay",
        FINCHLEY_ROAD_FROGNAL_MILDMAY_PORT,
    )
    _replace_marker(
        document,
        "910GFNCHLYR",
        FINCHLEY_ROAD_FROGNAL_MILDMAY_PORT,
        [
            _connector(
                FINCHLEY_ROAD_JUBILEE_PORT,
                FINCHLEY_ROAD_FROGNAL_MILDMAY_PORT,
                walking=True,
            ),
            _circle(FINCHLEY_ROAD_FROGNAL_MILDMAY_PORT),
        ],
    )

    # The source curve into the Hampstead Heath rise originally straddled the
    # incorrectly placed Finchley Road & Frognal split. Keep the whole bend on
    # its eastern segment, then use a single horizontal command between the two
    # Mildmay walking-interchange roundels.
    _replace_segment_commands(
        document,
        "mildmay:910GFNCHLYR:910GHMPSTDH",
        [
            {"op": "move", "to": _rounded((1817.694, 1090.438))},
            {"op": "line", "to": _rounded((1791.5, 1090.438))},
            {
                "op": "cubic",
                "control1": _rounded((1785.125, 1090.438)),
                "control2": _rounded((1776.219, 1094.125)),
                "to": _rounded((1771.703, 1098.625)),
            },
            {"op": "line", "to": _rounded((1742.313, 1128.016))},
            {"op": "line", "to": _rounded((1736.563, 1133.781))},
            {"op": "line", "to": _rounded((1705.62, 1164.71))},
            {"op": "line", "to": _rounded((1703.61, 1166.719))},
            {
                "op": "cubic",
                "control1": _rounded((1699.11, 1171.234)),
                "control2": _rounded((1690.188, 1174.922)),
                "to": _rounded((1683.813, 1174.922)),
            },
            {
                "op": "line",
                "to": _rounded(FINCHLEY_ROAD_FROGNAL_MILDMAY_PORT),
            },
        ],
    )
    _replace_segment_commands(
        document,
        "mildmay:910GFNCHLYR:910GWHMDSTD",
        [
            {
                "op": "move",
                "to": _rounded(FINCHLEY_ROAD_FROGNAL_MILDMAY_PORT),
            },
            {"op": "line", "to": _rounded(WEST_HAMPSTEAD_MILDMAY_PORT)},
        ],
    )

    # The former station splits also consumed the next two Jubilee positions.
    # Restore those authored stops so the line continues cleanly towards Baker
    # Street instead of compressing three stations into the Finchley cluster.
    for station_id, port in (
        ("940GZZLUSWC", SWISS_COTTAGE_JUBILEE_PORT),
        ("940GZZLUSJW", ST_JOHNS_WOOD_JUBILEE_PORT),
    ):
        _set_line_port(document, station_id, "jubilee", port)
        _replace_marker(
            document,
            station_id,
            port,
            [_tick("jubilee", port, (1, 1))],
        )

    for station_id, layout in NORTHWEST_LABEL_LAYOUTS.items():
        _set_label_layout(document, station_id, layout)

    # Shepherd's Bush is an out-of-station walking interchange. Move the
    # Mildmay semantic split to the source-traced point on its existing 45°
    # route and reproduce the official 45° dashed link to the Central roundel.
    central_port = _line_port(document, "940GZZLUSBC", "central")
    _set_line_port(
        document, "910GSHPDSB", "mildmay", SHEPHERDS_BUSH_MILDMAY_PORT
    )
    _replace_marker(
        document,
        "910GSHPDSB",
        SHEPHERDS_BUSH_MILDMAY_PORT,
        [
            _connector(
                central_port, SHEPHERDS_BUSH_MILDMAY_PORT, walking=True
            ),
            _circle(SHEPHERDS_BUSH_MILDMAY_PORT),
        ],
    )

    # Route ports were already aligned by the full-map compiler, but the
    # symbols retained their earlier independent line matches. Rebuild every
    # shared station symbol from the final ports so both lanes use one row.
    for station_id in ("940GZZLUSBM", "940GZZLUGHK"):
        circle_port = _line_port(document, station_id, "circle")
        hammersmith_city_port = _line_port(
            document, station_id, "hammersmith-city"
        )
        shared_y = circle_port[1]
        hammersmith_city_port = hammersmith_city_port[0], shared_y
        _set_line_port(
            document, station_id, "hammersmith-city", hammersmith_city_port
        )
        anchor = (
            (circle_port[0] + hammersmith_city_port[0]) / 2,
            shared_y,
        )
        _replace_marker(
            document,
            station_id,
            anchor,
            [
                _tick("circle", circle_port, (0, 1)),
                _tick("hammersmith-city", hammersmith_city_port, (0, 1)),
            ],
        )

    station_id = "940GZZLUHSC"
    circle_port = _line_port(document, station_id, "circle")
    hammersmith_city_port = _line_port(document, station_id, "hammersmith-city")
    hammersmith_city_port = hammersmith_city_port[0], circle_port[1]
    _set_line_port(document, station_id, "hammersmith-city", hammersmith_city_port)
    anchor = (
        (circle_port[0] + hammersmith_city_port[0]) / 2,
        circle_port[1],
    )
    _replace_marker(
        document,
        station_id,
        anchor,
        # Both services use one physical terminus. The TfL map centres a
        # single roundel across the compact parallel line lanes.
        [_circle(anchor)],
    )

    return int(document != before)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--document", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    document = json.loads(arguments.document.read_text())
    changed = apply(document)
    arguments.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"Applied source-verified geometry corrections: {changed}")


if __name__ == "__main__":
    main()
