#!/usr/bin/env python3
"""Apply source-verified geometry corrections to the compiled Beck map.

Station positions, interchange symbols, walking links and the labels of moved
stations are aligned with the TfL reference by `reference_alignment.py`. It
replaces the earlier station-by-station corrections, which fixed individual
stations from the April 2026 map but left most ticks where the slice compilers
had interpolated them.

The one path correction kept here restores the shared Weaver approach south of
Cambridge Heath: the slice compiler drew the Chingford branch as a bypass across
the neighbouring lane instead of sharing the approach curve.
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

import reference_alignment

Point = tuple[float, float]


def _rounded(value: Point) -> dict[str, float]:
    return {"x": round(value[0], 3), "y": round(value[1], 3)}


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

    port = segment[port_key]
    segment[port_key] = _rounded((float(port["x"]) + dx, float(port["y"]) + dy))
    command = path["commands"][0 if station_is_path_start else -1]
    if command["op"] not in {"move", "line", "cubic"} or "to" not in command:
        raise ValueError(f"Unexpected endpoint command for {segment['id']}")
    command["to"] = _rounded((float(command["to"]["x"]) + dx, float(command["to"]["y"]) + dy))


def _set_line_port(document: dict, station_id: str, line_id: str, target: Point) -> None:
    paths_by_id = {path["id"]: path for path in document["paths"]}
    matched = False
    for segment in document["segments"]:
        if segment["lineID"] != line_id or station_id not in {
            segment["fromStationID"], segment["toStationID"]
        }:
            continue
        port_key = "fromPort" if segment["fromStationID"] == station_id else "toPort"
        current = segment[port_key]
        _translate_station_endpoint(
            segment,
            paths_by_id[segment["pathID"]],
            station_id,
            target[0] - float(current["x"]),
            target[1] - float(current["y"]),
        )
        matched = True
    if not matched:
        raise ValueError(f"No {line_id} segment meets {station_id}")


def _replace_segment_commands(document: dict, segment_id: str, commands: list[dict]) -> None:
    segment = next(segment for segment in document["segments"] if segment["id"] == segment_id)
    path = next(path for path in document["paths"] if path["id"] == segment["pathID"])
    path["commands"] = commands
    start, end = dict(commands[0]["to"]), dict(commands[-1]["to"])
    if segment["pathDirection"] == "forward":
        segment["fromPort"], segment["toPort"] = start, end
    else:
        segment["fromPort"], segment["toPort"] = end, start


def _align_weaver_bethnal_green_bend(document: dict) -> None:
    """Restore the shared 45-degree fork south of Cambridge Heath.

    The source ticks put Bethnal Green on the horizontal approach and
    Cambridge Heath on the western vertical lane. The former synthetic
    bypass swept across that lane instead of sharing the approach curve.
    Both lanes get matching rounded bends, 24.24 units apart as on the TfL
    map, so the Chingford lane reaches Hackney Downs on TfL's stroke.
    """
    bethnal = (2774.922, 1379.344)
    cambridge = (2831.172, 1336.859)
    london_fields = (2831.172, 1297.101)
    for station_id, port in (
        ("910GBTHNLGR", bethnal),
        ("910GCAMHTH", cambridge),
        ("910GLONFLDS", london_fields),
    ):
        _set_line_port(document, station_id, "weaver", port)

    # These source-traced commands are deliberately identical on both
    # semantic routes so the renderer draws one shared horizontal approach.
    shared_approach = [
        {"op": "move", "to": _rounded(bethnal)},
        {"op": "line", "to": _rounded((2797.516, 1379.344))},
        {
            "op": "cubic",
            "control1": _rounded((2803.891, 1379.344)),
            "control2": _rounded((2812.797, 1375.656)),
            "to": _rounded((2817.313, 1371.141)),
        },
    ]
    for segment_id, offset, endpoint in (
        ("weaver:910GBTHNLGR:910GCAMHTH", 0.0, cambridge),
        ("weaver:910GBTHNLGR:910GHAKNYNM", 24.24, (2855.462, 1220.895)),
    ):
        _replace_segment_commands(document, segment_id, [
            *copy.deepcopy(shared_approach),
            {"op": "line", "to": _rounded((2822.969 + offset, 1365.485 - offset))},
            {
                "op": "cubic",
                "control1": _rounded((2827.484 + offset, 1360.985 - offset)),
                "control2": _rounded((2831.172 + offset, 1352.079 - offset)),
                "to": _rounded((2831.172 + offset, 1345.704 - offset)),
            },
            {"op": "line", "to": _rounded(endpoint)},
        ])

    _replace_segment_commands(document, "weaver:910GCAMHTH:910GLONFLDS", [
        {"op": "move", "to": _rounded(cambridge)},
        {"op": "line", "to": _rounded(london_fields)},
    ])


def apply(document: dict, reference: dict | None = None) -> int:
    """Apply deterministic corrections and return 1 when the document changed."""
    before = copy.deepcopy(document)
    _align_weaver_bethnal_green_bend(document)
    reference_alignment.apply(document, reference)
    return int(document != before)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--document", required=True, type=Path)
    parser.add_argument("--reference", type=Path, default=reference_alignment.REFERENCE_PATH)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    document = json.loads(arguments.document.read_text())
    changed = apply(document, json.loads(arguments.reference.read_text()))
    arguments.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"Applied source-verified geometry corrections: {changed}")


if __name__ == "__main__":
    main()
