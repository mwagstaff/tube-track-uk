#!/usr/bin/env python3
"""Centre every River Bus pier symbol on the Thames bank edge, as TfL does.

The map draws the river as an 18-unit band with a 3-unit outline, so the bank
edge line runs half the band plus half the outline from the centreline. Each
pier keeps its point along the river (`x`, `y` in RiverSchematic.json, which
lies on the centreline); its marker offset is set perpendicular to the river,
on the bank of the station it is linked to, or on its current bank otherwise.
A linked pier moves along its bank if needed so its walking link stays visible.
Rerunning the tool on its own output changes nothing.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

IOS_ROOT = Path(__file__).resolve().parents[2]
# Pier and roundel radii plus a couple of walking-link dots, centre to centre.
MINIMUM_LINK_SPAN = 34.0


def _segments(document: dict) -> tuple[list[tuple[tuple[float, float], tuple[float, float]]], float]:
    waterway = next(w for w in document["waterways"] if w["id"] == "river-thames")
    path = next(p for p in document["paths"] if p["id"] == waterway["pathID"])
    points = [(c["to"]["x"], c["to"]["y"]) for c in path["commands"] if c["op"] in ("move", "line")]
    edge = waterway["strokeWidth"] / 2 + waterway["outlineWidth"] / 2
    return list(zip(points, points[1:])), edge


def _distance_to_segment(p, a, b) -> float:
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)))
    return math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy)


def _roundel_near(document: dict, station_id: str, point) -> tuple[float, float]:
    marker = next(m for m in document["stationMarkers"] if m["stationID"] == station_id)
    circles = [(p["circle"]["centre"]["x"], p["circle"]["centre"]["y"])
               for p in marker["primitives"] if p["kind"] == "circle"]
    return min(circles or [(marker["anchor"]["x"], marker["anchor"]["y"])],
               key=lambda c: math.dist(c, point))


def place(anchors: list[dict], document: dict) -> list[dict]:
    segments, edge = _segments(document)
    placed = []
    for anchor in anchors:
        river = (anchor["x"], anchor["y"])
        marker = (river[0] + anchor["offsetX"], river[1] + anchor["offsetY"])
        stations = anchor.get("walkingLinkStationIDs") or []
        towards = _roundel_near(document, stations[0], marker) if stations else marker
        # The river segment through the pier's river point, preferring the one
        # whose normal points at the bank the pier belongs on.
        best = None
        for a, b in segments:
            if _distance_to_segment(river, a, b) > 1e-6:
                continue
            length = math.dist(a, b)
            normal = (-(b[1] - a[1]) / length, (b[0] - a[0]) / length)
            side = (towards[0] - river[0]) * normal[0] + (towards[1] - river[1]) * normal[1]
            if best is None or abs(side) > abs(best[0]):
                best = (side, normal)
        if best is None:
            raise ValueError(f"{anchor['id']} does not lie on the river centreline")
        side, normal = best
        sign = 1.0 if side >= 0 else -1.0
        # Leave room for the dotted walking link between the pier and its
        # station roundel, sliding the pier along its bank away from it.
        for station in stations:
            roundel = _roundel_near(document, station, marker)
            a, b = next(s for s in segments if _distance_to_segment(river, *s) <= 1e-6)
            length = math.dist(a, b)
            direction = ((b[0] - a[0]) / length, (b[1] - a[1]) / length)
            away = -1.0 if (roundel[0] - river[0]) * direction[0] + (roundel[1] - river[1]) * direction[1] > 0 else 1.0
            bank = (sign * normal[0] * edge, sign * normal[1] * edge)
            step = 0
            while math.dist((river[0] + bank[0], river[1] + bank[1]), roundel) < MINIMUM_LINK_SPAN - 1e-6:
                step += 1
                river = (round(river[0] + away * direction[0] * 0.05, 3), round(river[1] + away * direction[1] * 0.05, 3))
                if step > 2000 or _distance_to_segment(river, a, b) > 1e-3:
                    raise ValueError(f"{anchor['id']} cannot leave room for its walking link")
        offset = (round(sign * normal[0] * edge, 3) + 0.0, round(sign * normal[1] * edge, 3) + 0.0)
        centre = (river[0] + offset[0], river[1] + offset[1])
        # A pier near a bend must not fall inside another stretch of river.
        if min(_distance_to_segment(centre, a, b) for a, b in segments) < edge - 0.01:
            raise ValueError(f"{anchor['id']} would sit inside the river at a bend")
        updated = dict(anchor)
        updated["x"] = int(river[0]) if river[0] == int(river[0]) else river[0]
        updated["y"] = int(river[1]) if river[1] == int(river[1]) else river[1]
        updated["offsetX"] = int(offset[0]) if offset[0] == int(offset[0]) else offset[0]
        updated["offsetY"] = int(offset[1]) if offset[1] == int(offset[1]) else offset[1]
        placed.append(updated)
    return placed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--document", type=Path,
                        default=IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json")
    parser.add_argument("--anchors", type=Path, default=IOS_ROOT / "TubeTrackUK/Resources/RiverSchematic.json")
    arguments = parser.parse_args()
    document = json.loads(arguments.document.read_text())
    anchors = json.loads(arguments.anchors.read_text())
    placed = place(anchors, document)
    arguments.anchors.write_text(json.dumps(placed, indent=2, ensure_ascii=False) + "\n")
    print(f"Placed {len(placed)} piers on the river banks")


if __name__ == "__main__":
    main()
