#!/usr/bin/env python3
"""Align station symbols and interchanges with the TfL reference map.

The compiled artwork reuses TfL's traced line paths, but several slices placed
stations by interpolation, so ticks drifted along their lines, interchange
roundels sat off their TfL positions and many walking interchanges were never
drawn. This pass reads a reference file written by `extract_tfl_reference.py`
and, without inventing layout:

* pairs every station on every route with its TfL tick, roundel or step-free
  disc, using the order of stations along the route and the position of each
  station's own TfL label;
* moves each station split along its existing path to that symbol, re-splitting
  the neighbouring station-to-station paths so the route artwork is unchanged;
* re-traces the few runs whose paths were hand-authored away from the TfL
  strokes (Jubilee east of Canada Water, the sub-surface lanes between Euston
  Square and Moorgate, the Central line and Waterloo & City at Bank, the
  Northern and Victoria lines through King's Cross, the Circle at Edgware Road,
  the Metropolitan into Baker Street, the Elizabeth line through Stratford,
  the Suffragette line at Barking and the Windrush line's Peckham branch);
* rebuilds station markers in the TfL grammar: one-sided ticks, bars across
  termini, roundels at TfL positions, interchange bars and dotted walking links;
* places labels on TfL's label boxes for stations whose symbols moved.

Every step is skipped when the document already matches, so rerunning the pass
on its own output changes nothing.
"""

from __future__ import annotations

import argparse
import collections
import copy
import json
import math
import re
from pathlib import Path

import build_central_core_join as vector
from map_geometry import path_end, path_end_tangent, path_start, path_start_tangent

Point = tuple[float, float]

REFERENCE_PATH = (
    Path(__file__).resolve().parents[2]
    / "design_brief/beck_map/tfl-standard-map-2026-09-reference.json"
)

# TfL station grammar, measured on the reference in artwork units.
ROUNDEL_RADIUS = 10.36          # ring centre-line; the white disc has radius 8.29
ROUNDEL_OUTLINE_WIDTH = 4.14
CONNECTOR_WIDTH = 12.4          # the renderer draws a white core a third as wide
WALKING_CONNECTOR_WIDTH = 5.3   # square dots, drawn with a half-width gap
TICK_LENGTH = 9.77              # from the line centre outwards
TICK_WIDTH = 5.47

SERVE_TOLERANCE = 9.5           # a line passing this close runs under the symbol
MOVE_EPSILON = 0.05             # smaller moves are invisible and only churn geometry
ADJACENT_SYMBOLS = 36.0
CORRIDOR_PROBE = 60.0

# Runs whose station-to-station paths are replaced by slices of the TfL line
# stroke through the given TfL symbol positions (line, stations, targets, the
# largest allowed target offset from the stroke).
RETRACE_RUNS: tuple[tuple[str, tuple[str, ...], tuple[Point, ...], float], ...] = (
    ("jubilee", ("940GZZLUCWR", "940GZZLUCYF", "940GZZLUNGW", "940GZZLUCGT", "940GZZLUWHM", "940GZZLUSTD"),
     ((2704.94, 1918.0), (2991.0, 1939.0), (3169.0, 1949.0), (3253.3, 1758.2), (3253.1, 1517.8), (3253.2, 1269.0)), 4.5),
    ("central", ("940GZZLUSPU", "940GZZLUBNK", "940GZZLULVT", "940GZZLUBLG"),
     ((2205.1, 1647.5), (2322.0, 1620.07), (2385.1, 1549.2), (2775.0, 1486.0)), 9.0),
    ("northern", ("940GZZLUMTC", "940GZZLUEUS", "940GZZLUWRR"),
     ((1994.9, 1265.0), (1995.17, 1318.37), (1967.0, 1420.0)), 6.0),
    ("northern", ("940GZZLUWRR", "940GZZLUGDG", "940GZZLUTCR"),
     ((1965.98, 1424.68), (1961.78, 1521.36), (1966.56, 1561.88)), 6.0),
    ("northern", ("940GZZLUEUS", "940GZZLUKSX", "940GZZLUAGL"),
     ((2028.195, 1318.773), (2137.66, 1356.66), (2252.93, 1395.54)), 6.0),
    ("victoria", ("940GZZLUEUS", "940GZZLUKSX", "940GZZLUHAI"),
     ((2034.02, 1357.4), (2137.66, 1356.66), (2405.01, 1156.27)), 6.0),
    ("circle", ("940GZZLUERC", "940GZZLUPAC"), ((1491.9, 1410.8), (1414.35, 1429.65)), 6.0),
    ("metropolitan", ("940GZZLUFYR", "940GZZLUBST"), ((1550.17, 1256.23), (1725.29, 1394.12)), 6.0),
    # The Uxbridge branch: TfL keeps the Metropolitan and Piccadilly lanes
    # 11.6 units apart, and both lanes run at 45 degrees into Rayners Lane.
    ("metropolitan", ("940GZZLUUXB", "940GZZLUHGD", "940GZZLUICK", "940GZZLURSP", "940GZZLURSM",
                      "940GZZLUEAE", "940GZZLURYL", "940GZZLUWHW"),
     ((215.29, 803.34), (307.2, 803.24), (400.93, 803.24), (519.25, 802.5), (566.35, 792.75),
      (633.08, 818.97), (655.04, 855.55), (828.88, 940.48)), 9.0),
    ("piccadilly", ("940GZZLURSM", "940GZZLUEAE", "940GZZLURYL", "940GZZLUSHH"),
     ((566.31, 804.34), (625.0, 826.98), (655.04, 855.55), (672.48, 1020.36)), 6.0),
    ("waterloo-city", ("940GZZLUWLO", "940GZZLUBNK"), ((1991.06, 1968.9), (2322.0, 1620.07)), 6.0),
    ("elizabeth", ("910GWCHAPXR", "910GSTFD", "910GMRYLAND"),
     ((2735.14, 1516.26), (3220.77, 1268.99), (3284.88, 1205.25)), 6.0),
    ("elizabeth", ("910GLIVST", "910GSTFD"), ((2385.1, 1486.0), (3220.77, 1268.99)), 6.0),
    ("weaver", ("910GHAKNYNM", "910GCLAPTON", "910GSTJMSST"),
     ((2855.462, 1220.895), (2880.35, 1152.71), (2933.5, 1099.56)), 6.0),
    ("suffragette", ("910GWDGRNPK", "910GBARKING", "910GBARKRIV"),
     ((3478.38, 1285.29), (3574.74, 1520.92), (3785.25, 1617.56)), 6.0),
    ("windrush", ("910GPCKHMQD", "910GSURREYQ"), ((2481.79, 2203.34), (2704.91, 2008.19)), 6.0),
    *(
        (line, ("940GZZLUESQ", "940GZZLUKSX", "940GZZLUFCN", "940GZZLUBBN", "940GZZLUMGT"),
         ((1926.7, 1385.9), (2107.19, 1385.97), (2201.82, 1453.39), barbican, (2321.93, 1549.41)), 9.0)
        for line, barbican in (
            ("circle", (2266.0, 1524.0)),
            ("hammersmith-city", (2272.0, 1518.0)),
            ("metropolitan", (2260.0, 1530.0)),
        )
    ),
)

# The label-ordered pairing needs help where a label sits beside the wrong
# station: Baker Street's name is printed above Great Portland Street's ticks,
# and Mile End's H&C lane shares the Stepney Green label corridor.
TICK_OVERRIDES: dict[tuple[str, str], Point | None] = {
    ("940GZZLUBST", "hammersmith-city"): None,
    ("940GZZLUGPS", "hammersmith-city"): (1802.617, 1382.609),
    ("940GZZLUSGN", "hammersmith-city"): (2898.143, 1546.996),
}
# The Weaver terminus at Liverpool Street stops short of its TfL disc.
MANUAL_OWNERS: dict[tuple[str, str], Point] = {
    ("910GLIVST", "weaver"): (2422.82, 1448.35),
}
# Canning Town's Stratford-branch platforms have their own TfL disc on the DLR
# curve; the semantic port stays on the shared Canning Town node.
DISPLAY_ONLY_OWNERS: dict[tuple[str, str], Point] = {
    ("940GZZDLCGT", "dlr"): (3287.99, 1724.25),
}
# Kennington's Charing Cross and Bank branches reach it through separate TfL
# roundels and merge south of the station; its traced branch ports are kept.
FIXED_PORTS = {("940GZZLUKNG", "northern")}
# Cable-car terminals are drawn by the cable-car layer, not this document.
CABLE_CAR_STATION_NAMES = {"North Greenwich", "Royal Victoria DLR Station"}

LABEL_ALIASES = {
    "kings cross st pancras": "kings cross and st pancras",
    "paddington hc line": "paddington", "edgware road circle line": "edgware road",
    "edgware road bakerloo": "edgware road", "hammersmith dist and picc line": "hammersmith",
    "hammersmith hc line": "hammersmith", "shepherds bush central": "shepherds bush",
    "cutty sark": "cutty sark for maritime greenwich", "custom house": "custom house for excel",
    "new cross ell": "new cross", "bank dlr": "bank", "london liverpool street": "liverpool street",
    "london euston": "euston",
}


# ---------------------------------------------------------------- geometry
def _point(value: dict) -> Point:
    return float(value["x"]), float(value["y"])


def _rounded(value: Point) -> dict[str, float]:
    return {"x": round(value[0], 3), "y": round(value[1], 3)}


def _curves(commands: list[dict]) -> list[vector.Curve]:
    curves: list[vector.Curve] = []
    current: Point | None = None
    for command in commands:
        if command["op"] == "move":
            current = _point(command["to"])
        elif command["op"] == "line":
            end = _point(command["to"])
            if math.dist(current, end) > 1e-6:
                curves.append(vector.Curve("line", current, end))
            current = end
        elif command["op"] == "cubic":
            end = _point(command["to"])
            curves.append(vector.Curve(
                "cubic", current, end, _point(command["control1"]), _point(command["control2"])
            ))
            current = end
    return curves


def _nearest(curves: list[vector.Curve], target: Point, samples: int = 400) -> vector.Match:
    best = None
    for index, curve in enumerate(curves):
        for sample in range(samples + 1):
            t = sample / samples
            p = curve.point(t)
            d = (p[0] - target[0]) ** 2 + (p[1] - target[1]) ** 2
            if best is None or d < best[0]:
                best = (d, index, t)
    _, index, t = best
    low, high = max(0.0, t - 1 / samples), min(1.0, t + 1 / samples)
    for _ in range(40):
        a, b = low + (high - low) / 3, high - (high - low) / 3
        if math.dist(curves[index].point(a), target) < math.dist(curves[index].point(b), target):
            high = b
        else:
            low = a
    t = (low + high) / 2
    return vector.Match(index, t, curves[index].point(t), curves[index].tangent(t))


def _slice(curves: list[vector.Curve], start: vector.Match, end: vector.Match) -> list[vector.Curve]:
    if start.scalar > end.scalar:
        return [c.reversed() for c in reversed(_slice(curves, end, start))]
    result = []
    for index in range(start.curve_index, end.curve_index + 1):
        low = start.t if index == start.curve_index else 0.0
        high = end.t if index == end.curve_index else 1.0
        if high - low > 1e-9:
            piece = vector.curve_slice(curves[index], low, high)
            if _extent(piece) > 1e-3:
                result.append(piece)
    if not result:
        raise ValueError("Empty path slice")
    return result


def _extent(curve: vector.Curve) -> float:
    points = [curve.start, curve.end] + ([curve.control1, curve.control2] if curve.operation == "cubic" else [])
    return max(math.dist(points[0], p) for p in points[1:])


def _unit(vector_: Point) -> Point | None:
    length = math.hypot(*vector_)
    return None if length < 1e-9 else (vector_[0] / length, vector_[1] / length)


def _unhook(curves: list[vector.Curve]) -> list[vector.Curve]:
    """Drop back-steps, where a piece doubles back over the piece before it.

    Some slice compilers drew a line past a fork or station and back again.
    That is invisible in the full map but shows as a spur when the segment is
    highlighted for a disruption or a journey."""
    curves = list(curves)
    index = 0
    while index < len(curves) - 1:
        a, b = curves[index], curves[index + 1]
        ta, tb = _unit(a.tangent(1.0)), _unit(b.tangent(0.0))
        if ta is not None and tb is not None and ta[0] * tb[0] + ta[1] * tb[1] < -0.98:
            back = _nearest([a], b.end)
            if math.dist(back.point, b.end) <= 0.5 and back.t > 1e-6:
                # b returns along a: stop a where b ends
                curves[index:index + 2] = [vector.curve_slice(a, 0.0, back.t)]
                index = max(index - 1, 0)
                continue
            ahead = _nearest([b], a.start)
            if math.dist(ahead.point, a.start) <= 0.5 and ahead.t < 1 - 1e-6:
                # b runs back past a's start: keep b from there
                curves[index:index + 2] = [vector.curve_slice(b, ahead.t, 1.0)]
                index = max(index - 1, 0)
                continue
        index += 1
    return curves


def _begin(curves):
    return vector.Match(0, 0.0, curves[0].start, curves[0].tangent(0.0))


def _finish(curves):
    last = len(curves) - 1
    return vector.Match(last, 1.0, curves[last].end, curves[last].tangent(1.0))


class Artwork:
    """Station-to-station paths of the document, oriented per station."""

    def __init__(self, document: dict):
        self.document = document
        self.paths = {path["id"]: path for path in document["paths"]}

    def segments(self, line_id: str, station_id: str | None = None) -> list[dict]:
        return [
            s for s in self.document["segments"]
            if s["lineID"] == line_id
            and (station_id is None or station_id in (s["fromStationID"], s["toStationID"]))
        ]

    @staticmethod
    def starts_at(segment: dict, station_id: str) -> bool:
        return (segment["fromStationID"] == station_id) == (segment["pathDirection"] == "forward")

    def oriented(self, segment: dict, station_id: str) -> list[vector.Curve]:
        curves = _curves(self.paths[segment["pathID"]]["commands"])
        return curves if self.starts_at(segment, station_id) else [c.reversed() for c in reversed(curves)]

    def write(self, segment: dict, curves: list[vector.Curve], station_id: str) -> None:
        curves = [c for c in curves if _extent(c) > 1e-3] or curves[:1]
        if not self.starts_at(segment, station_id):
            curves = [c.reversed() for c in reversed(curves)]
        commands = vector.path_commands(curves)
        self.paths[segment["pathID"]]["commands"] = commands
        start, end = commands[0]["to"], commands[-1]["to"]
        if segment["pathDirection"] == "forward":
            segment["fromPort"], segment["toPort"] = dict(start), dict(end)
        else:
            segment["fromPort"], segment["toPort"] = dict(end), dict(start)

    @staticmethod
    def port(segment: dict, station_id: str) -> Point:
        return _point(segment["fromPort"] if segment["fromStationID"] == station_id else segment["toPort"])

    def ports(self, line_id: str, station_id: str) -> list[Point]:
        return [self.port(s, station_id) for s in self.segments(line_id, station_id)]

    def degree(self, line_id: str, station_id: str) -> int:
        return len(self.segments(line_id, station_id))

    def port_groups(self, line_id: str, station_id: str) -> list[list[dict]]:
        """Segments grouped by shared station port, the station's own group first.

        Where a branch diverges beyond the station its segment starts at the
        divergence point; the group shared by the most segments is the stop.
        """
        groups: list[list[dict]] = []
        for segment in sorted(self.segments(line_id, station_id), key=lambda s: s["id"]):
            port = self.port(segment, station_id)
            group = next((g for g in groups if math.dist(self.port(g[0], station_id), port) <= 1.0), None)
            if group is None:
                groups.append([segment])
            else:
                group.append(segment)
        return sorted(groups, key=lambda g: (-len(g), g[0]["id"]))

    def runs(self, line_id: str):
        adjacency = collections.defaultdict(list)
        for segment in self.segments(line_id):
            adjacency[segment["fromStationID"]].append(segment)
            adjacency[segment["toStationID"]].append(segment)
        anchors = sorted(station for station, links in adjacency.items() if len(links) != 2)
        visited = set()
        for anchor in anchors:
            for first in sorted(adjacency[anchor], key=lambda s: s["id"]):
                if first["id"] in visited:
                    continue
                stations, segments, segment, current = [anchor], [], first, anchor
                while True:
                    visited.add(segment["id"])
                    segments.append(segment)
                    current = segment["toStationID"] if segment["fromStationID"] == current else segment["fromStationID"]
                    stations.append(current)
                    if current in anchors:
                        break
                    segment = next(s for s in adjacency[current] if s["id"] != segment["id"])
                yield stations, segments

    def resplit(self, line_id: str, targets: dict[str, Point]) -> int:
        """Move interior ports of degree-two stations along their joined run."""
        changed = 0
        for stations, segments in self.runs(line_id):
            interior = stations[1:-1]
            if not any(
                station in targets and math.dist(self.port(segments[i], station), targets[station]) > MOVE_EPSILON
                for i, station in enumerate(interior)
            ):
                continue
            curves: list[vector.Curve] = []
            boundaries = [0]
            for index, segment in enumerate(segments):
                curves.extend(self.oriented(segment, stations[index]))
                boundaries.append(len(curves))
            matches = [_begin(curves)]
            for index in range(1, len(stations) - 1):
                station = stations[index]
                if station in targets:
                    match = _nearest(curves, targets[station])
                    if math.dist(match.point, targets[station]) > 6:
                        raise ValueError(f"{line_id} {station}: target is off its route")
                else:
                    ci = boundaries[index]
                    match = vector.Match(ci, 0.0, curves[ci].start, curves[ci].tangent(0.0))
                matches.append(match)
            matches.append(_finish(curves))
            scalars = [m.scalar for m in matches]
            if any(b <= a + 1e-6 for a, b in zip(scalars, scalars[1:])):
                raise ValueError(f"{line_id}: station order would change along {stations}")
            for index, segment in enumerate(segments):
                self.write(segment, _slice(curves, matches[index], matches[index + 1]), stations[index])
            changed += len(segments)
        return changed

    def move_terminus(self, line_id: str, station_id: str, target: Point) -> bool:
        (segment,) = self.segments(line_id, station_id)
        if math.dist(self.port(segment, station_id), target) <= MOVE_EPSILON:
            return False
        curves = self.oriented(segment, station_id)
        match = _nearest(curves, target)
        if match.curve_index == 0 and match.t <= 1e-6:
            # the TfL symbol lies beyond the traced end: extend along the end tangent
            start = curves[0].start
            probe = next(c.point(t) for c in curves for t in (0.02, 0.1, 0.5, 1.0) if math.dist(c.point(t), start) > 0.5)
            length = math.dist(probe, start)
            u = ((start[0] - probe[0]) / length, (start[1] - probe[1]) / length)
            along = (target[0] - start[0]) * u[0] + (target[1] - start[1]) * u[1]
            end = (start[0] + u[0] * along, start[1] + u[1] * along)
            if math.dist(end, start) <= MOVE_EPSILON:
                return False
            new = [vector.Curve("line", end, start)] + curves
        else:
            new = _slice(curves, match, _finish(curves))
        self.write(segment, new, station_id)
        return True

    def move_junction(self, line_id: str, station_id: str, target: Point, only: list[dict] | None = None) -> bool:
        segments = only if only is not None else self.segments(line_id, station_id)
        oriented = {s["id"]: self.oriented(s, station_id) for s in segments}
        # A junction with separate platform ports (Euston's two Northern line
        # branches) already satisfies a target that one of its ports occupies.
        if any(math.dist(curves[0].start, target) <= MOVE_EPSILON for curves in oriented.values()):
            return False
        candidates = []
        for segment in segments:
            match = _nearest(oriented[segment["id"]], target)
            candidates.append((math.dist(match.point, target), segment["id"], segment, match))
        distance, _, host, match = min(candidates)
        if distance > 6:
            raise ValueError(f"{station_id} {line_id}: junction target is off its segments")
        curves = oriented[host["id"]]
        carried = _slice(curves, _begin(curves), match)
        self.write(host, _slice(curves, match, _finish(curves)), station_id)
        back = [c.reversed() for c in reversed(carried)]
        for segment in segments:
            if segment["id"] != host["id"]:
                self.attach(segment, station_id, match.point, back)
        return True

    def attach(self, segment: dict, station_id: str, port: Point, bridge: list[vector.Curve] | None = None) -> bool:
        """Start the segment's station end at `port`.

        A segment that already passes through the port (a branch sharing the
        moved piece of line) is trimmed there; any other segment is extended by
        `bridge`, which runs from the port to its current end, or by a line.
        """
        curves = self.oriented(segment, station_id)
        if math.dist(curves[0].start, port) <= MOVE_EPSILON:
            return False
        match = _nearest(curves, port)
        if math.dist(match.point, port) <= 0.5 and not (match.curve_index == 0 and match.t <= 1e-6):
            trimmed = _slice(curves, match, _finish(curves))
            if math.dist(match.point, port) > 1e-3:
                trimmed = [vector.Curve("line", port, match.point)] + trimmed
            self.write(segment, trimmed, station_id)
        else:
            self.write(segment, (bridge or [vector.Curve("line", port, curves[0].start)]) + curves, station_id)
        return True

    def move(self, line_id: str, station_id: str, target: Point) -> bool:
        degree = self.degree(line_id, station_id)
        if degree == 1:
            return self.move_terminus(line_id, station_id, target)
        if degree == 2:
            return bool(self.resplit(line_id, {station_id: target}))
        # At a junction, branches that diverge beyond the station keep their
        # own divergence ports; only the station's own port group moves.
        groups = self.port_groups(line_id, station_id)
        if len(groups) == 1:
            return self.move_junction(line_id, station_id, target)
        group = groups[0]
        if math.dist(self.port(group[0], station_id), target) <= MOVE_EPSILON:
            return False
        if len(group) == 2:
            return self._resplit_pair(group, station_id, target)
        if len(group) == 1:
            return self._move_endpoint(group[0], station_id, target)
        return self.move_junction(line_id, station_id, target, only=group)

    def _resplit_pair(self, pair: list[dict], station_id: str, target: Point) -> bool:
        first, second = pair
        incoming = [c.reversed() for c in reversed(self.oriented(first, station_id))]
        outgoing = self.oriented(second, station_id)
        curves = incoming + outgoing
        match = _nearest(curves, target)
        if math.dist(match.point, target) > 6:
            return False
        head = _slice(curves, _begin(curves), match)
        tail = _slice(curves, match, _finish(curves))
        self.write(first, [c.reversed() for c in reversed(head)], station_id)
        self.write(second, tail, station_id)
        return True

    def _move_endpoint(self, segment: dict, station_id: str, target: Point) -> bool:
        curves = self.oriented(segment, station_id)
        match = _nearest(curves, target)
        if math.dist(match.point, target) > 6 or (match.curve_index == 0 and match.t <= 1e-6):
            return False
        self.write(segment, _slice(curves, match, _finish(curves)), station_id)
        return True

    def samples(self, line_id: str | None = None):
        for segment in self.document["segments"]:
            if line_id is None or segment["lineID"] == line_id:
                curves = _curves(self.paths[segment["pathID"]]["commands"])
                yield segment, [c.point(k / 16) for c in curves for k in range(17)]


def _project(point: Point, polyline: list[Point]) -> tuple[float, Point]:
    best = (math.inf, point)
    for a, b in zip(polyline, polyline[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = dx * dx + dy * dy
        t = 0.0 if length == 0 else max(0.0, min(1.0, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length))
        q = (a[0] + t * dx, a[1] + t * dy)
        d = math.dist(point, q)
        if d < best[0]:
            best = (d, q)
    return best


# ---------------------------------------------------------------- reference
class Reference:
    def __init__(self, data: dict):
        self.data = data
        self.symbols = [dict(s) for s in data["symbols"]]
        self.ticks = data["ticks"]
        self._strokes: dict[str, list[list[vector.Curve]]] = {}
        self._junctions: dict[str, list[list[vector.Curve]]] = {}
        self._spans = collections.defaultdict(list)
        blocks = collections.defaultdict(list)
        for label in data["labels"]:
            blocks[label["block"]].append(label)
        for lines in blocks.values():
            for start in range(len(lines)):
                for count in range(1, 4):
                    chosen = lines[start:start + count]
                    if len(chosen) < count:
                        break
                    text = self.normalise(" ".join(label["text"] for label in chosen))
                    self._spans[text].append((
                        min(l["box"][0] for l in chosen), min(l["box"][1] for l in chosen),
                        max(l["box"][2] for l in chosen), max(l["box"][3] for l in chosen),
                    ))

    @staticmethod
    def normalise(text: str) -> str:
        text = text.lower().replace("’", "'").replace("‘", "'")
        for pattern in (
            r"\(for maritime greenwich\)", r"\bdlr station\b", r"\bstation\b", r"\(london\)",
            r"\(berks\)", r"\(h&c line\)", r"\(circle line\)", r"\(bakerloo\)", r"\(dist&picc line\)",
            r"\(central\)", r"\bell\b", r"\bfor excel\b", r"\bfor maritime greenwich\b",
            r"\binternational\b", r"\blondon\b", r"-underground", r"\bunderground\b",
        ):
            text = re.sub(pattern, " ", text)
        text = text.replace("st.", "st").replace("&", " and ").replace("-", " ")
        return " ".join(re.sub(r"[^a-z0-9 ]", "", text).split())

    def label_boxes(self, name: str) -> list[tuple]:
        key = self.normalise(name)
        key = LABEL_ALIASES.get(key, key)
        found = list(self._spans.get(key, []))
        if not found and key:
            for text in sorted(self._spans):
                if f" {key} " in f" {text} " and len(text) < len(key) + 25:
                    found.extend(self._spans[text])
        return found

    def line_strokes(self, line_id: str) -> list[list[vector.Curve]]:
        if line_id not in self._strokes:
            self._strokes[line_id] = self._merged_strokes(line_id)
        return self._strokes[line_id]

    def junction_strokes(self, line_id: str) -> list[list[vector.Curve]]:
        """Strokes continued through up to two T-junctions.

        TfL ends some strokes on the line they join: the Elizabeth line's
        Shenfield stroke stops on the core east of Whitechapel, and the Windrush
        Peckham branch reaches the East London trunk through a short connector.
        """
        if line_id in self._junctions:
            return self._junctions[line_id]
        strokes = self.line_strokes(line_id)
        result, frontier = [], strokes
        for _ in range(2):
            grown = []
            for stroke in frontier:
                for oriented in (stroke, _reversed(stroke)):
                    end = oriented[-1].end
                    for other in strokes:
                        match = _nearest(other, end, samples=24)
                        if (
                            math.dist(match.point, end) > 1.0
                            or math.dist(match.point, other[0].start) <= 1.0
                            or math.dist(match.point, other[-1].end) <= 1.0
                        ):
                            continue
                        bridge = [vector.Curve("line", end, match.point)] if math.dist(end, match.point) > 1e-3 else []
                        for tail in (_slice(other, match, _finish(other)), _slice(other, match, _begin(other))):
                            grown.append(oriented + bridge + tail)
            result.extend(grown)
            frontier = grown
        self._junctions[line_id] = result
        return result

    def _merged_strokes(self, line_id: str) -> list[list[vector.Curve]]:
        strokes = [_curves(commands) for commands in self.data["lineStrokes"].get(line_id, [])]
        strokes = [s for s in strokes if s]
        merged = True
        while merged:
            merged = False
            for i in range(len(strokes)):
                for j in range(len(strokes)):
                    if i == j:
                        continue
                    a, b = strokes[i], strokes[j]
                    joined = None
                    if math.dist(a[-1].end, b[0].start) < 0.8:
                        joined = a + b
                    elif math.dist(a[-1].end, b[-1].end) < 0.8:
                        joined = a + [c.reversed() for c in reversed(b)]
                    elif math.dist(a[0].start, b[0].start) < 0.8:
                        joined = [c.reversed() for c in reversed(b)] + a
                    if joined is not None:
                        strokes[i] = joined
                        del strokes[j]
                        merged = True
                        break
                if merged:
                    break
        return strokes


def _box_distance(point: Point, box) -> float:
    dx = max(box[0] - point[0], 0, point[0] - box[2])
    dy = max(box[1] - point[1], 0, point[1] - box[3])
    return math.hypot(dx, dy)


def _colour_matches(tick: dict, line_id: str) -> bool:
    return line_id in tick["lines"]


# ---------------------------------------------------------------- 1. retrace
def _run_stroke(reference: Reference, line_id: str, stations, targets, tolerance: float):
    """The TfL stroke that passes every target in order, and where it does."""
    for candidates in (reference.line_strokes(line_id), reference.junction_strokes(line_id)):
        best = None
        for stroke in candidates:
            if any(_coarse_distance(stroke, target) > tolerance + 3 for target in targets):
                continue
            matches = [_nearest(stroke, target, samples=80) for target in targets]
            offsets = [math.dist(m.point, t) for m, t in zip(matches, targets)]
            steps = [b.scalar - a.scalar for a, b in zip(matches, matches[1:])]
            ordered = all(step > 0 for step in steps) or all(step < 0 for step in steps)
            if max(offsets) <= tolerance and ordered and (best is None or sum(offsets) < best[0] - 1e-9):
                best = (sum(offsets), stroke, matches)
        if best is not None:
            return best[1], best[2]
    raise ValueError(f"{line_id}: no TfL stroke passes {stations}")


def _coarse_distance(curves: list[vector.Curve], target: Point) -> float:
    """Distance to the stroke: exact on straight pieces, sampled on the short bends."""
    best = math.inf
    for curve in curves:
        if curve.operation == "line":
            best = min(best, _project(target, [curve.start, curve.end])[0])
        else:
            best = min(best, min(math.dist(curve.point(k / 8), target) for k in range(9)))
    return best


def _extended(curves: list[vector.Curve], target: Point) -> list[vector.Curve]:
    """Continue a line end straight on to the target's projection.

    TfL stops a stroke under the edge of its terminus disc; the app ends the
    line at the disc centre, as the terminus pass in `ownership` expects."""
    end = curves[-1].end
    probe = next(c.point(t) for c in reversed(curves) for t in (0.98, 0.9, 0.5, 0.0) if math.dist(c.point(t), end) > 0.5)
    length = math.dist(probe, end)
    u = ((end[0] - probe[0]) / length, (end[1] - probe[1]) / length)
    along = (target[0] - end[0]) * u[0] + (target[1] - end[1]) * u[1]
    if along <= MOVE_EPSILON:
        return curves
    return curves + [vector.Curve("line", end, (end[0] + u[0] * along, end[1] + u[1] * along))]


def _reversed(curves: list[vector.Curve]) -> list[vector.Curve]:
    return [c.reversed() for c in reversed(curves)]


def retrace(artwork: Artwork, reference: Reference) -> int:
    changed = 0
    for line_id, stations, targets, tolerance in RETRACE_RUNS:
        stroke, matches = _run_stroke(reference, line_id, stations, targets, tolerance)
        run = []
        old_ends = {}
        for (a, b), (ma, mb) in zip(zip(stations, stations[1:]), zip(matches, matches[1:])):
            segment = next(
                s for s in artwork.segments(line_id)
                if {s["fromStationID"], s["toStationID"]} == {a, b}
            )
            run.append(segment["id"])
            for station in {a, b} & {stations[0], stations[-1]}:
                old_ends[station] = artwork.port(segment, station)
            piece = _slice(stroke, ma, mb)
            if b == stations[-1] and artwork.degree(line_id, b) == 1:
                piece = _extended(piece, targets[-1])
            if a == stations[0] and artwork.degree(line_id, a) == 1:
                piece = _reversed(_extended(_reversed(piece), targets[0]))
            current = artwork.oriented(segment, a)
            if (
                math.dist(current[0].start, piece[0].start) <= MOVE_EPSILON
                and math.dist(current[-1].end, piece[-1].end) <= MOVE_EPSILON
                and len(current) == len(piece)
            ):
                continue
            artwork.write(segment, piece, a)
            changed += 1
        # Segments that shared a run end's old port follow it to the new one,
        # bridged along the TfL stroke where the old port lies on it.
        for station, match in ((stations[0], matches[0]), (stations[-1], matches[-1])):
            for segment in artwork.segments(line_id, station):
                old = artwork.port(segment, station)
                if (
                    segment["id"] in run
                    or math.dist(old, old_ends[station]) > 1.0
                    or math.dist(old, match.point) <= MOVE_EPSILON
                ):
                    continue
                on_stroke = _nearest(stroke, old, samples=80)
                bridge = None
                if math.dist(on_stroke.point, old) <= 0.5 and math.dist(on_stroke.point, match.point) > MOVE_EPSILON:
                    bridge = _slice(stroke, match, on_stroke)
                    if _length(bridge) > 1.5 * math.dist(match.point, old) + 1.0:
                        bridge = None
                changed += artwork.attach(segment, station, match.point, bridge)
    return changed


def _length(curves: list[vector.Curve]) -> float:
    return sum(math.dist(c.point(k / 16), c.point((k + 1) / 16)) for c in curves for k in range(16))


# ---------------------------------------------------------------- 2. pairing
def _route_polyline(artwork: Artwork, route: dict):
    stations = route["stationIDs"]
    polyline: list[Point] = []
    for index, segment_id in enumerate(route["segmentIDs"]):
        segment = next(s for s in artwork.document["segments"] if s["id"] == segment_id)
        curves = artwork.oriented(segment, stations[index])
        points = [c.point(k / 10) for c in curves for k in range(11)]
        if polyline and math.dist(polyline[-1], points[0]) < 0.5:
            points = points[1:]
        polyline.extend(points)
    cumulative = [0.0]
    for a, b in zip(polyline, polyline[1:]):
        cumulative.append(cumulative[-1] + math.dist(a, b))
    return polyline, cumulative


def _arc_position(point: Point, polyline: list[Point], cumulative: list[float]) -> tuple[float, float]:
    best = (math.inf, 0.0)
    for index, (a, b) in enumerate(zip(polyline, polyline[1:])):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = dx * dx + dy * dy
        t = 0.0 if length == 0 else max(0.0, min(1.0, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length))
        q = (a[0] + t * dx, a[1] + t * dy)
        d = math.dist(point, q)
        if d < best[0]:
            best = (d, cumulative[index] + t * math.sqrt(length))
    return best


def pair_routes(artwork: Artwork, reference: Reference, names: dict[str, str]):
    """Order-preserving, label-guided pairing of route stations with TfL symbols."""
    pairs = collections.defaultdict(list)       # (station, line) -> [(kind, index)]
    candidates_by_kind = [("tick", i, t) for i, t in enumerate(reference.ticks)] + [
        ("symbol", i, s) for i, s in enumerate(reference.symbols) if s["kind"] != "pier"
    ]
    for route in sorted(artwork.document["routes"], key=lambda r: r["id"]):
        line_id, stations = route["lineID"], route["stationIDs"]
        polyline, cumulative = _route_polyline(artwork, route)
        found = []
        for kind, index, item in candidates_by_kind:
            if kind == "tick" and not _colour_matches(item, line_id):
                continue
            tolerance = 13 if kind == "tick" else 17
            point = (item["x"], item["y"])
            if not (min(p[0] for p in polyline) - tolerance <= point[0] <= max(p[0] for p in polyline) + tolerance):
                continue
            distance, arc = _arc_position(point, polyline, cumulative)
            if distance <= tolerance:
                found.append((arc, kind, index, distance))
        found.sort()
        deduplicated = []
        for entry in found:
            if deduplicated and abs(entry[0] - deduplicated[-1][0]) < 5:
                if entry[3] < deduplicated[-1][3]:
                    deduplicated[-1] = entry
            else:
                deduplicated.append(entry)
        spans = [reference.label_boxes(names[s]) for s in stations]
        app_arcs = []
        for index, station in enumerate(stations):
            segment_id = route["segmentIDs"][0 if index == 0 else index - 1]
            segment = next(s for s in artwork.document["segments"] if s["id"] == segment_id)
            app_arcs.append(_arc_position(artwork.port(segment, station), polyline, cumulative)[1])
        n, m = len(stations), len(deduplicated)
        infinity = float("inf")
        cost = [[infinity] * (m + 1) for _ in range(n + 1)]
        back = [[None] * (m + 1) for _ in range(n + 1)]
        cost[0][0] = 0.0
        for i in range(n + 1):
            for j in range(m + 1):
                if cost[i][j] == infinity:
                    continue
                if i < n and j < m:
                    kind, index = deduplicated[j][1], deduplicated[j][2]
                    item = reference.ticks[index] if kind == "tick" else reference.symbols[index]
                    if spans[i]:
                        step = min(60.0, min(_box_distance((item["x"], item["y"]), box) for box in spans[i]))
                    else:
                        step = min(60.0, abs(app_arcs[i] - deduplicated[j][0]))
                    if cost[i][j] + step < cost[i + 1][j + 1]:
                        cost[i + 1][j + 1] = cost[i][j] + step
                        back[i + 1][j + 1] = (i, j, True)
                if i < n and cost[i][j] + 60.0 < cost[i + 1][j]:
                    cost[i + 1][j] = cost[i][j] + 60.0
                    back[i + 1][j] = (i, j, False)
                if j < m and cost[i][j] + 25.0 < cost[i][j + 1]:
                    cost[i][j + 1] = cost[i][j] + 25.0
                    back[i][j + 1] = (i, j, False)
        i, j = n, m
        while (i, j) != (0, 0):
            pi, pj, paired = back[i][j]
            if paired:
                pairs[(stations[pi], line_id)].append((deduplicated[pj][1], deduplicated[pj][2]))
            i, j = pi, pj
    return pairs


# ---------------------------------------------------------------- 3. targets
def _line_projection(artwork: Artwork, line_id: str, point: Point) -> tuple[float, Point]:
    """Exact nearest point on the line's paths (coarse search, then refinement)."""
    coarse = []
    for segment, samples in artwork.samples(line_id):
        coarse.append((_project(point, samples)[0], segment["id"], segment))
    if not coarse:
        return math.inf, point
    coarse.sort()
    best = (math.inf, point)
    for distance, _, segment in coarse:
        if distance > coarse[0][0] + 3:
            break
        curves = _curves(artwork.paths[segment["pathID"]]["commands"])
        match = _nearest(curves, point)
        exact = math.dist(match.point, point)
        if exact < best[0] - 1e-9:
            best = (exact, match.point)
    return best


def station_targets(artwork, reference, pairs, names, markers):
    """Ports for ordinary stations, keyed by (station, line).

    A station paired with exactly one TfL tick, or with one disc drawn on its
    line, moves to that symbol. Interchanges are left to `ownership`, and a move
    of four units or more also needs the station's own TfL label beside it.
    """
    claims = collections.defaultdict(set)
    for (station, line_id), found in pairs.items():
        for kind, index in found:
            claims[(kind, index, line_id)].add(station)
    targets: dict[tuple[str, str], tuple[Point, str, int]] = {}
    for key in sorted(pairs):
        station, line_id = key
        found = sorted(set(pairs[key]))
        if len(found) != 1:
            continue
        kind, index = found[0]
        if len(claims[(kind, index, line_id)]) != 1:
            continue
        if any(p["kind"] != "tick" for p in markers[station]["primitives"]) and not _only_ticks_expected(station, pairs):
            continue
        item = reference.ticks[index] if kind == "tick" else reference.symbols[index]
        distance, target = _line_projection(artwork, line_id, (item["x"], item["y"]))
        if distance > (13 if kind == "tick" else 4.6):
            continue
        if math.dist(artwork.ports(line_id, station)[0], target) >= 4:
            spans = reference.label_boxes(names[station])
            if not spans or min(_box_distance((item["x"], item["y"]), box) for box in spans) > 45:
                continue
        targets[key] = (target, kind, index)
    for key, centre in TICK_OVERRIDES.items():
        targets.pop(key, None)
        if centre is not None:
            index = min(range(len(reference.ticks)), key=lambda i: math.dist(centre, (reference.ticks[i]["x"], reference.ticks[i]["y"])))
            tick = reference.ticks[index]
            targets[key] = (_line_projection(artwork, key[1], (tick["x"], tick["y"]))[1], "tick", index)
    return targets


def tick_side_references(reference, pairs):
    """TfL tick centres that show which side of its line each station's tick sits."""
    sides = {}
    for key in sorted(pairs):
        ticks = sorted({index for kind, index in pairs[key] if kind == "tick"})
        if len(ticks) == 1:
            sides[key] = (reference.ticks[ticks[0]]["x"], reference.ticks[ticks[0]]["y"])
    for key, centre in TICK_OVERRIDES.items():
        sides.pop(key, None)
        if centre is not None:
            sides[key] = centre
    return sides


def _only_ticks_expected(station, pairs):
    return all(kind == "tick" for key, found in pairs.items() if key[0] == station for kind, _ in found)


# ---------------------------------------------------------------- 4. ownership
def _terminal_end(artwork: Artwork, line_id: str, station: str) -> tuple[Point, Point]:
    """A terminus port and the unit direction pointing out of the line end."""
    (segment,) = artwork.segments(line_id, station)
    curves = artwork.oriented(segment, station)
    end = curves[0].start
    probe = next(c.point(t) for c in curves for t in (0.05, 0.5, 1.0) if math.dist(c.point(t), end) > 0.5)
    length = math.dist(probe, end)
    return end, ((end[0] - probe[0]) / length, (end[1] - probe[1]) / length)

def ownership(artwork, reference, pairs, names):
    """TfL roundels, discs and piers owned by (station, line), with the port on the line."""
    symbols = reference.symbols
    owners: dict[int, dict[tuple[str, str], Point]] = collections.defaultdict(dict)
    claimed: set[tuple[str, str]] = set()
    for key in sorted(pairs):
        station, line_id = key
        for kind, index in sorted(set(pairs[key])):
            if kind != "symbol":
                continue
            symbol = symbols[index]
            centre = (symbol["x"], symbol["y"])
            if artwork.degree(line_id, station) == 1:
                end, u = _terminal_end(artwork, line_id, station)
                v = (centre[0] - end[0], centre[1] - end[1])
                along = v[0] * u[0] + v[1] * u[1]
                if abs(-v[0] * u[1] + v[1] * u[0]) <= SERVE_TOLERANCE and abs(along) <= 20:
                    owners[index][key] = (end[0] + u[0] * along, end[1] + u[1] * along)
                    claimed.add(key)
                continue
            distance, point = _line_projection(artwork, line_id, centre)
            if distance <= SERVE_TOLERANCE:
                owners[index][key] = point
                claimed.add(key)
    line_ports = collections.defaultdict(dict)
    for segment in artwork.document["segments"]:
        for station in (segment["fromStationID"], segment["toStationID"]):
            line_ports[segment["lineID"]][station] = artwork.port(segment, station)
    samples = list(artwork.samples())
    for index, symbol in enumerate(symbols):
        if symbol["kind"] == "pier" or symbol.get("diameter", 0) >= 29:
            continue
        centre = (symbol["x"], symbol["y"])
        nearest_by_line = {}
        for segment, points in samples:
            if min(abs(points[0][0] - centre[0]), abs(points[-1][0] - centre[0])) > 600:
                continue
            distance, point = _project(centre, points)
            line_id = segment["lineID"]
            if distance <= SERVE_TOLERANCE and (line_id not in nearest_by_line or distance < nearest_by_line[line_id][0]):
                nearest_by_line[line_id] = (distance, point)
        for line_id in sorted(nearest_by_line):
            if any(k[1] == line_id for k in owners[index]):
                continue
            _, point = nearest_by_line[line_id]
            nearest = sorted((math.dist(p, point), station) for station, p in line_ports[line_id].items())
            if not nearest or nearest[0][0] > 40 or (nearest[0][1], line_id) in claimed:
                continue
            owners[index][(nearest[0][1], line_id)] = point
            claimed.add((nearest[0][1], line_id))
    # termini whose TfL symbol lies just past (or before) the traced line end
    for segment in sorted(artwork.document["segments"], key=lambda s: s["id"]):
        for station in (segment["fromStationID"], segment["toStationID"]):
            key = (station, segment["lineID"])
            if key in claimed or artwork.degree(segment["lineID"], station) != 1:
                continue
            end, u = _terminal_end(artwork, segment["lineID"], station)
            for index, symbol in enumerate(symbols):
                if symbol["kind"] == "pier":
                    continue
                v = (symbol["x"] - end[0], symbol["y"] - end[1])
                along = v[0] * u[0] + v[1] * u[1]
                if abs(along) <= 20 and abs(-v[0] * u[1] + v[1] * u[0]) <= 4.5 and math.hypot(*v) <= 20:
                    owners[index][key] = (end[0] + u[0] * along, end[1] + u[1] * along)
                    claimed.add(key)
                    break
    for key, centre in {**MANUAL_OWNERS, **DISPLAY_ONLY_OWNERS}.items():
        index = min(range(len(symbols)), key=lambda i: math.dist(centre, (symbols[i]["x"], symbols[i]["y"])))
        owners[index][key] = (symbols[index]["x"], symbols[index]["y"])
    return owners


# ---------------------------------------------------------------- 5. markers
def _circle(centre: Point) -> dict:
    return {"kind": "circle", "circle": {
        "centre": _rounded(centre), "radius": ROUNDEL_RADIUS, "outlineWidth": ROUNDEL_OUTLINE_WIDTH,
    }}


def _canonical(start: Point, end: Point) -> tuple[Point, Point]:
    """TfL draws interchange bars and walking links horizontally, vertically or
    at 45 degrees even where its symbol centres sit a unit or two off that axis.
    Within three degrees, keep the midpoint and put both ends on the axis."""
    dx, dy = end[0] - start[0], end[1] - start[1]
    angle = math.degrees(math.atan2(dy, dx))
    nearest_axis = round(angle / 45.0) * 45.0
    if abs(angle - nearest_axis) > 3.0 or abs(angle - nearest_axis) < 1e-6:
        return start, end
    # Unit steps along the axis, and the half-length measured along it.
    steps = [0 if abs(c) < 1e-9 else (1 if c > 0 else -1)
             for c in (math.cos(math.radians(nearest_axis)), math.sin(math.radians(nearest_axis)))]
    along = (dx * steps[0] + dy * steps[1]) / (2 if 0 in steps else 4)
    # Round the middle and the per-axis half-extent once, so the stored ends
    # stay exactly on the axis after the document's three-decimal rounding.
    middle = (round((start[0] + end[0]) / 2, 3), round((start[1] + end[1]) / 2, 3))
    extent = round(along, 3)
    half = (steps[0] * extent, steps[1] * extent)
    return (middle[0] - half[0], middle[1] - half[1]), (middle[0] + half[0], middle[1] + half[1])


def _connector(start: Point, end: Point, walking: bool = False) -> dict:
    start, end = _canonical(start, end)
    kind = "walkingConnector" if walking else "connector"
    return {"kind": kind, kind: {
        "start": _rounded(start), "end": _rounded(end),
        "width": WALKING_CONNECTOR_WIDTH if walking else CONNECTOR_WIDTH,
    }}


def _port_and_tangent(artwork: Artwork, station: str, line_id: str):
    """The station port and the unit line direction there.

    Like the fidelity audit, the direction comes from the exact end tangent of
    the first segment (by ID) that meets the station.
    """
    groups = artwork.port_groups(line_id, station)
    for segment in groups[0] if groups else []:
        commands = artwork.paths[segment["pathID"]]["commands"]
        at_start = artwork.starts_at(segment, station)
        tangent = path_start_tangent(commands) if at_start else path_end_tangent(commands)
        if tangent is None:
            continue
        port = path_start(commands) if at_start else path_end(commands)
        length = math.hypot(*tangent)
        return port, (tangent[0] / length, tangent[1] / length)
    return None, None


def _tick(line_id: str, start: Point, end: Point) -> dict:
    return {"kind": "tick", "tick": {
        "lineID": line_id, "start": _rounded(start), "end": _rounded(end), "width": TICK_WIDTH,
    }}


def build_markers(artwork, reference, pairs, owners, targets, side_references):
    document = artwork.document
    symbols = reference.symbols
    names = {m["stationID"]: m["name"] for m in document["stationMarkers"]}
    previous = {m["stationID"]: copy.deepcopy(m) for m in document["stationMarkers"]}

    def centre(i):
        return (symbols[i]["x"], symbols[i]["y"])

    in_scope = {i for i, own in owners.items() if own}
    edges: set[tuple[int, int]] = set()
    for bar in reference.data["connectors"]:
        u = (math.cos(math.radians(bar["angle"])), math.sin(math.radians(bar["angle"])))
        on_axis = []
        for i, symbol in enumerate(symbols):
            v = (symbol["x"] - bar["centre"][0], symbol["y"] - bar["centre"][1])
            along = v[0] * u[0] + v[1] * u[1]
            if abs(-v[0] * u[1] + v[1] * u[0]) <= 3.0 and abs(along) <= bar["length"] / 2 + 14 and i in in_scope:
                on_axis.append((along, i))
        on_axis.sort()
        for (_, a), (_, b) in zip(on_axis, on_axis[1:]):
            edges.add((min(a, b), max(a, b)))
    hub = {sid: name.replace(" DLR Station", "").replace(" (London)", "").split(" (")[0] for sid, name in names.items()}
    ordered_scope = sorted(in_scope)
    for x, a in enumerate(ordered_scope):
        for b in ordered_scope[x + 1:]:
            if math.dist(centre(a), centre(b)) <= ADJACENT_SYMBOLS and (
                {hub[k[0]] for k in owners[a]} & {hub[k[0]] for k in owners[b]}
            ):
                edges.add((a, b))
    walks: set[tuple[int, int]] = set()
    for link in reference.data["walkingLinks"]:
        a = min(range(len(symbols)), key=lambda i: math.dist(link["a"], centre(i)))
        b = min(range(len(symbols)), key=lambda i: math.dist(link["b"], centre(i)))
        if a != b:
            walks.add((min(a, b), max(a, b)))
    cable_car = set()
    for a, b in sorted(walks):
        for i, j in ((a, b), (b, a)):
            if i not in in_scope and symbols[i]["kind"] != "pier" and j in in_scope and (
                {names[k[0]] for k in owners[j]} & CABLE_CAR_STATION_NAMES
            ):
                cable_car.add(i)

    def branch_points(station, line_id, near, distance):
        points = []
        for segment in artwork.segments(line_id, station):
            curves = artwork.oriented(segment, station)
            if math.dist(curves[0].start, near) > 12:
                continue
            remaining, previous_point, found = distance, curves[0].start, None
            for curve in curves:
                for k in range(1, 21):
                    q = curve.point(k / 20)
                    step = math.dist(previous_point, q)
                    if step >= remaining:
                        found = q
                        break
                    remaining -= step
                    previous_point = q
                if found:
                    break
            points.append(found or previous_point)
        return points

    line_samples = {}

    def near_line(point, line_id, tolerance):
        if line_id not in line_samples:
            line_samples[line_id] = [p for _, pts in artwork.samples(line_id) for p in pts]
        return any(math.dist(point, q) < tolerance for q in line_samples[line_id]
                   if abs(q[0] - point[0]) < tolerance and abs(q[1] - point[1]) < tolerance)

    def shared_corridor(i):
        own = owners[i]
        lines = {k[1] for k in own}
        if len(lines) < 2:
            return True
        for (station, line_id), point in sorted(own.items()):
            for probe in branch_points(station, line_id, point, CORRIDOR_PROBE):
                if not all(near_line(probe, other, 16) for other in sorted(lines - {line_id})):
                    return False
        return True

    def qualifies(i, station):
        if symbols[i]["kind"] == "roundel":
            return True
        if any(i in edge for edge in edges):
            return True
        for a, b in walks:
            if i in (a, b):
                j = b if a == i else a
                if j in in_scope or symbols[j]["kind"] == "pier" or j in cable_car:
                    return True
        own = owners[i]
        if (len({k[0] for k in own}) >= 2 or len({k[1] for k in own}) >= 2) and not shared_corridor(i):
            return True
        # A step-free disc does not say whether TfL treats the stop as an
        # interchange; keep an existing interchange roundel in that case.
        return any(
            p["kind"] == "circle" and math.dist(_point(p["circle"]["centre"]), centre(i)) < 40
            for p in previous[station]["primitives"]
        )

    tick_keys = set(side_references)

    def label_side_point(station, port):
        boxes = [b for b in reference.label_boxes(names[station]) if _box_distance(port, b) <= 110]
        if not boxes:
            return None
        box = min(boxes, key=lambda b: (_box_distance(port, b), b))
        return ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
    segment_counts = collections.Counter(
        station for s in document["segments"] for station in (s["fromStationID"], s["toStationID"])
    )

    def owner_of(stations):
        # A shared bar or walking link belongs to a through station where there
        # is one, so a terminus never draws an interchange it cannot route.
        through = sorted(s for s in stations if segment_counts[s] >= 2)
        return through[0] if through else sorted(stations)[0]

    edge_owner = {e: owner_of({k[0] for k in owners[e[0]]} | {k[0] for k in owners[e[1]]}) for e in sorted(edges)}
    walk_owner = {}
    external = []
    for a, b in sorted(walks):
        if a in in_scope and b in in_scope:
            walk_owner[(a, b)] = owner_of({k[0] for k in owners[a]} | {k[0] for k in owners[b]})
        elif a in in_scope or b in in_scope:
            s, o = (a, b) if a in in_scope else (b, a)
            kind = "pier" if symbols[o]["kind"] == "pier" else ("cableCar" if o in cable_car else None)
            if kind:
                for station in sorted({k[0] for k in owners[s]}):
                    external.append({"stationID": station, "kind": kind, "station": centre(s), "other": centre(o)})
    owned = collections.defaultdict(set)
    for i, own in owners.items():
        for station, _ in own:
            owned[station].add(i)

    def tick_for(station, line_id):
        port, tangent = _port_and_tangent(artwork, station, line_id)
        if port is None:
            return None
        normal = (-tangent[1], tangent[0])
        if artwork.degree(line_id, station) == 1:
            return _tick(line_id,
                         (port[0] - normal[0] * TICK_LENGTH, port[1] - normal[1] * TICK_LENGTH),
                         (port[0] + normal[0] * TICK_LENGTH, port[1] + normal[1] * TICK_LENGTH))
        side_point = side_references.get((station, line_id))
        if side_point is None or math.dist(side_point, port) >= 14:
            side_point = label_side_point(station, port) or (port[0] + normal[0], port[1] + normal[1])
        side = 1 if (side_point[0] - port[0]) * normal[0] + (side_point[1] - port[1]) * normal[1] >= 0 else -1
        return _tick(line_id, port, (port[0] + side * normal[0] * TICK_LENGTH, port[1] + side * normal[1] * TICK_LENGTH))

    changed = 0
    for marker in document["stationMarkers"]:
        station = marker["stationID"]
        mine = sorted(owned.get(station, ()))
        status = {}
        for line_id in marker["lineIDs"]:
            if any((station, line_id) in owners[i] for i in mine):
                status[line_id] = "symbol"
            elif (station, line_id) in tick_keys:
                status[line_id] = "tick"
            else:
                port, _ = _port_and_tangent(artwork, station, line_id)
                known = bool(mine) or any((station, other) in tick_keys for other in marker["lineIDs"])
                nothing_near = port is not None and not any(
                    math.dist(port, (item["x"], item["y"])) < 12 for item in list(symbols) + list(reference.ticks)
                )
                status[line_id] = "none" if known and nothing_near else "unknown"
        if all(value == "unknown" for value in status.values()):
            restyled = []
            for primitive in marker["primitives"]:
                if primitive["kind"] == "circle":
                    restyled.append(_circle(_point(primitive["circle"]["centre"])))
                elif primitive["kind"] == "tick":
                    tick = tick_for(station, primitive["tick"]["lineID"])
                    restyled.append(tick or primitive)
                else:
                    restyled.append(primitive)
            if restyled != marker["primitives"]:
                marker["primitives"] = restyled
                changed += 1
            continue
        interchange = any(qualifies(i, station) for i in mine)
        primitives, circles = [], []
        if interchange:
            for (a, b), owner in sorted(edge_owner.items()):
                if owner == station:
                    primitives.append(_connector(centre(a), centre(b)))
            for (a, b), owner in sorted(walk_owner.items()):
                if owner == station:
                    primitives.append(_connector(centre(a), centre(b), walking=True))
            for i in mine:
                primitives.append(_circle(centre(i)))
                circles.append(centre(i))
        for line_id in marker["lineIDs"]:
            if status[line_id] == "none" or (interchange and status[line_id] == "symbol"):
                continue
            tick = tick_for(station, line_id)
            if tick:
                primitives.append(tick)
        if not primitives:
            continue
        ports = [p for line_id in marker["lineIDs"] for p in [_port_and_tangent(artwork, station, line_id)[0]] if p]
        mean = (sum(p[0] for p in ports) / len(ports), sum(p[1] for p in ports) / len(ports)) if ports else circles[0]
        anchor = min(circles, key=lambda c: math.dist(c, mean)) if circles else mean
        if marker["primitives"] != primitives or marker["anchor"] != _rounded(anchor):
            marker["primitives"] = primitives
            marker["anchor"] = _rounded(anchor)
            changed += 1
    return changed, external


# ---------------------------------------------------------------- 6. labels
def place_labels(artwork, reference, previous_anchors) -> int:
    """Anchor moved stations' labels on the matching TfL label box."""
    document = artwork.document
    markers = {m["stationID"]: m for m in document["stationMarkers"]}
    changed = 0
    for label in document["labels"]:
        marker = markers.get(label["stationID"])
        if marker is None:
            continue
        anchor = _point(marker["anchor"])
        previous = previous_anchors.get(label["stationID"], anchor)
        if math.dist(anchor, previous) > 3:
            boxes = [box for box in reference.label_boxes(marker["name"]) if _box_distance(anchor, box) <= 110]
            if boxes:
                box = min(boxes, key=lambda b: (_box_distance(anchor, b), b))
                middle = (box[1] + box[3]) / 2
                if box[0] >= anchor[0] + 3:
                    alignment, position = "leading", (box[0], middle)
                elif box[2] <= anchor[0] - 3:
                    alignment, position = "trailing", (box[2], middle)
                else:
                    alignment, position = "centre", ((box[0] + box[2]) / 2, middle)
            else:
                alignment = label["alignment"]
                p = _point(label["position"])
                position = (p[0] + anchor[0] - previous[0], p[1] + anchor[1] - previous[1])
            if label["alignment"] != alignment or label["position"] != _rounded(position):
                label["alignment"] = alignment
                label["position"] = _rounded(position)
                changed += 1
    return changed


# ---------------------------------------------------------------- pass
# Interior stations of a re-traced run already sit on their TfL symbols; the
# run's end stations still align their other segments with the new port.
RETRACED = {(station, line_id) for line_id, stations, _, _ in RETRACE_RUNS for station in stations[1:-1]}
PROTECTED = RETRACED | FIXED_PORTS


def apply(document: dict, reference_data: dict | None = None, *, iterations: int = 4) -> int:
    """Align the document with the TfL reference; returns 1 when it changed.

    Moving one station can change which symbols a neighbouring route sees, so
    the pass runs to a fixed point: the result is unchanged by another run.
    """
    if reference_data is None:
        reference_data = json.loads(REFERENCE_PATH.read_text())
    reference = Reference(reference_data)
    before = copy.deepcopy(document)
    for _ in range(iterations):
        snapshot = copy.deepcopy(document)
        _align_once(document, reference)
        if document == snapshot:
            break
    else:
        raise ValueError("TfL reference alignment did not reach a fixed point")
    return int(document != before)


def _align_once(document: dict, reference: Reference) -> None:
    artwork = Artwork(document)
    names = {m["stationID"]: m["name"] for m in document["stationMarkers"]}
    markers = {m["stationID"]: m for m in document["stationMarkers"]}
    previous_anchors = {m["stationID"]: _point(m["anchor"]) for m in document["stationMarkers"]}

    for segment in document["segments"]:
        curves = _curves(artwork.paths[segment["pathID"]]["commands"])
        cleaned = _unhook(curves)
        if len(cleaned) != len(curves):
            start = segment["fromStationID"] if segment["pathDirection"] == "forward" else segment["toStationID"]
            artwork.write(segment, cleaned, start)
    retrace(artwork, reference)
    pairs = pair_routes(artwork, reference, names)
    targets = {
        key: value for key, value in station_targets(artwork, reference, pairs, names, markers).items()
        if key not in PROTECTED
    }
    by_line = collections.defaultdict(dict)
    for (station, line_id), (target, _, _) in sorted(targets.items()):
        if artwork.degree(line_id, station) == 2:
            by_line[line_id][station] = target
    for line_id in sorted(by_line):
        artwork.resplit(line_id, by_line[line_id])
    for (station, line_id), (target, _, _) in sorted(targets.items()):
        if artwork.degree(line_id, station) != 2:
            artwork.move(line_id, station, target)

    owners = ownership(artwork, reference, pairs, names)
    display_only = set(DISPLAY_ONLY_OWNERS)
    symbols_per_key = collections.Counter(key for own in owners.values() for key in own)
    port_targets = {}
    for i in sorted(owners):
        if reference.symbols[i]["kind"] == "pier":
            continue
        for key, point in sorted(owners[i].items()):
            # A station drawn with several TfL symbols on one line has one
            # port per platform group; those ports are kept as traced.
            if key not in display_only and key not in PROTECTED and symbols_per_key[key] == 1:
                port_targets[key] = point
    by_line = collections.defaultdict(dict)
    for (station, line_id), point in sorted(port_targets.items()):
        if artwork.degree(line_id, station) == 2:
            by_line[line_id][station] = point
    for line_id in sorted(by_line):
        artwork.resplit(line_id, by_line[line_id])
    for (station, line_id), point in sorted(port_targets.items()):
        if artwork.degree(line_id, station) != 2:
            artwork.move(line_id, station, point)

    build_markers(artwork, reference, pairs, owners, targets, tick_side_references(reference, pairs))
    place_labels(artwork, reference, previous_anchors)


def external_links(document: dict, reference_data: dict | None = None) -> list[dict]:
    """Walking links from stations to River Bus piers and cable-car terminals."""
    if reference_data is None:
        reference_data = json.loads(REFERENCE_PATH.read_text())
    reference = Reference(reference_data)
    artwork = Artwork(document)
    names = {m["stationID"]: m["name"] for m in document["stationMarkers"]}
    markers = {m["stationID"]: m for m in document["stationMarkers"]}
    pairs = pair_routes(artwork, reference, names)
    targets = station_targets(artwork, reference, pairs, names, markers)
    owners = ownership(artwork, reference, pairs, names)
    scratch = copy.deepcopy(document)
    _, external = build_markers(Artwork(scratch), reference, pairs, owners, targets,
                                tick_side_references(reference, pairs))
    return external


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--document", required=True, type=Path)
    parser.add_argument("--reference", type=Path, default=REFERENCE_PATH)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    document = json.loads(arguments.document.read_text())
    changed = apply(document, json.loads(arguments.reference.read_text()))
    arguments.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"Aligned station symbols with the TfL reference: {changed}")


if __name__ == "__main__":
    main()
