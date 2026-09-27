#!/usr/bin/env python3
"""Extract the station grammar of the TfL standard map into a reference file.

This is an offline measurement tool. It reads page one of the official PDF
after it has been exported with Poppler:

    pdftocairo -svg -f 1 -l 1 standard-tube-map.pdf map.svg
    pdftotext -f 1 -l 1 -bbox-layout standard-tube-map.pdf words.html

and records, in artwork units (four per PDF point), every interchange roundel,
step-free disc, River Bus pier disc, ordinary station tick, interchange bar,
walking-interchange dot run, station label box and coloured line stroke. The
reference file is consumed by `reference_alignment.py`; it never changes map
geometry itself.
"""

from __future__ import annotations

import argparse
import html
import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path

SCALE = 4.0
SVG = "{http://www.w3.org/2000/svg}"
NUMBER = r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"
TOKENS = re.compile(rf"[A-Za-z]|{NUMBER}")

BLACK = (35, 31, 32)
SYMBOL_BLUE = (44, 51, 142)
WHITE = (255, 255, 255)

# Stroke colours of the TfL master artwork, keyed by TubeTrack line ID.
LINE_COLOURS = {
    "bakerloo": (174, 83, 14), "central": (224, 33, 36), "circle": (252, 203, 6),
    "district": (21, 119, 61), "hammersmith-city": (239, 133, 173),
    "jubilee": (117, 129, 137), "metropolitan": (131, 22, 81),
    "northern": (35, 31, 32), "piccadilly": (44, 51, 142),
    "victoria": (55, 162, 225), "waterloo-city": (135, 213, 180),
    "dlr": (36, 179, 169), "elizabeth": (105, 61, 161), "tram": (105, 194, 47),
    "liberty": (79, 93, 98), "lioness": (248, 156, 14), "mildmay": (36, 134, 203),
    "suffragette": (89, 195, 100), "weaver": (176, 35, 127), "windrush": (237, 25, 46),
}

ROUNDEL_RADIUS = 12.43          # outer radius of an ordinary TfL roundel ring
LINE_STROKE_WIDTHS = (7.0, 10.5)


def _matrix(text: str | None) -> tuple[float, ...]:
    values = [float(value) for value in re.findall(NUMBER, text or "")]
    return tuple(values) if len(values) == 6 else (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def _apply(matrix: tuple[float, ...], point: tuple[float, float]) -> tuple[float, float]:
    a, b, c, d, e, f = matrix
    return (
        (a * point[0] + c * point[1] + e) * SCALE,
        (b * point[0] + d * point[1] + f) * SCALE,
    )


def _colour(value: str | None) -> tuple[int, int, int] | None:
    if not value or value == "none":
        return None
    match = re.match(r"rgb\(([\d.]+)%,\s*([\d.]+)%,\s*([\d.]+)%\)", value)
    if not match:
        return None
    return tuple(round(float(component) * 2.55) for component in match.groups())


def _commands(data: str, matrix: tuple[float, ...]) -> list[tuple]:
    tokens = TOKENS.findall(data)
    index = 0
    operation = None
    commands: list[tuple] = []
    while index < len(tokens):
        if tokens[index].isalpha():
            operation = tokens[index]
            index += 1
            if operation in "Zz":
                commands.append(("Z",))
                continue
        if operation == "M":
            commands.append(("M", _apply(matrix, (float(tokens[index]), float(tokens[index + 1])))))
            index += 2
            operation = "L"
        elif operation == "L":
            commands.append(("L", _apply(matrix, (float(tokens[index]), float(tokens[index + 1])))))
            index += 2
        elif operation == "C":
            points = [
                _apply(matrix, (float(tokens[index + k]), float(tokens[index + k + 1])))
                for k in (0, 2, 4)
            ]
            commands.append(("C", *points))
            index += 6
        else:
            raise ValueError(f"Unsupported SVG path operation {operation}")
    return commands


def drawable_paths(svg_path: Path) -> list[dict]:
    """Every filled or stroked path in page order, in artwork coordinates.

    Poppler places most artwork inside compositing groups whose translations
    are cancelled by their filter wrappers, so each element's own transform
    gives page coordinates. Glyph definitions, clip paths and masks are skipped.
    """
    root = ET.parse(svg_path).getroot()
    parents = {child: parent for parent in root.iter() for child in parent}
    paths = []
    for element in root.iter():
        if element.tag != SVG + "path":
            continue
        ancestor, skip = element, False
        while ancestor in parents:
            ancestor = parents[ancestor]
            if ancestor.tag in (SVG + "clipPath", SVG + "mask") or (
                ancestor.get("id") or ""
            ).startswith("glyph"):
                skip = True
                break
        if skip or not element.get("d"):
            continue
        matrix = _matrix(element.get("transform"))
        commands = _commands(element.get("d"), matrix)
        points = [point for command in commands for point in command[1:]]
        if not points:
            continue
        stroke = _colour(element.get("stroke"))
        scale = math.sqrt(abs(matrix[0] * matrix[3] - matrix[1] * matrix[2]))
        paths.append({
            "fill": _colour(element.get("fill", "rgb(0%,0%,0%)")),
            "stroke": stroke,
            "strokeWidth": float(element.get("stroke-width", 1)) * scale * SCALE if stroke else 0.0,
            "commands": commands,
            "bbox": (
                min(point[0] for point in points), min(point[1] for point in points),
                max(point[0] for point in points), max(point[1] for point in points),
            ),
        })
    return paths


def _quadrilateral(path: dict) -> list[tuple[float, float]] | None:
    if any(command[0] == "C" for command in path["commands"]):
        return None
    points: list[tuple[float, float]] = []
    for command in path["commands"]:
        if command[0] in ("M", "L") and (not points or math.dist(command[1], points[-1]) > 0.05):
            points.append(command[1])
    if len(points) > 1 and math.dist(points[0], points[-1]) < 0.05:
        points.pop()
    # Some bars carry an extra vertex part-way along one edge (Clapham Junction).
    changed = True
    while changed and len(points) > 4:
        changed = False
        for k in range(len(points)):
            a, b, c = points[k - 1], points[k], points[(k + 1) % len(points)]
            cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
            if abs(cross) <= 0.05 * math.dist(a, b) * math.dist(b, c):
                del points[k]
                changed = True
                break
    return points if len(points) == 4 else None


def _centre(box) -> tuple[float, float]:
    return ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)


def _size(box) -> tuple[float, float]:
    return (box[2] - box[0], box[3] - box[1])


def _close(colour, reference, tolerance=30) -> bool:
    return colour is not None and sum(abs(a - b) for a, b in zip(colour, reference)) < tolerance


def extract_symbols(paths: list[dict]) -> list[dict]:
    filled = [path for path in paths if not path["stroke"]]
    symbols: list[dict] = []

    def near(point, radius):
        return [
            path for path in filled
            if abs(_centre(path["bbox"])[0] - point[0]) <= radius
            and abs(_centre(path["bbox"])[1] - point[1]) <= radius
        ]

    for path in filled:
        width, height = _size(path["bbox"])
        centre = _centre(path["bbox"])
        count = len(path["commands"])
        if path["fill"] == BLACK and count == 10 and 23.5 < width < 40 and abs(width - height) < 0.5:
            symbols.append({"kind": "roundel", "x": centre[0], "y": centre[1], "diameter": width})
        elif path["fill"] == SYMBOL_BLUE and count == 5 and 23.5 < width < 28 and abs(width - height) < 0.5:
            nearby = near(centre, 6)
            white = [p for p in nearby if p["fill"] == WHITE and len(p["commands"]) == 5 and 20 < _size(p["bbox"])[0] < 25]
            boat = [p for p in nearby if p["fill"] == SYMBOL_BLUE and len(p["commands"]) >= 40 and 18 < _size(p["bbox"])[0] < 23]
            kind = "pier" if boat and white else ("stepFreePlatform" if white else "stepFreeTrain")
            symbols.append({"kind": kind, "x": centre[0], "y": centre[1], "diameter": width})
    # Two roundels joined by a bar are sometimes drawn as one compound outline.
    for path in filled:
        width, height = _size(path["bbox"])
        if path["fill"] != BLACK or len(path["commands"]) != 22 or not (24 <= max(width, height) < 200):
            continue
        box = path["bbox"]
        r = ROUNDEL_RADIUS
        if width < 30:
            pair = ((_centre(box)[0], box[1] + r), (_centre(box)[0], box[3] - r))
        elif height < 30:
            pair = ((box[0] + r, _centre(box)[1]), (box[2] - r, _centre(box)[1]))
        else:
            pair = ((box[0] + r, box[1] + r), (box[2] - r, box[3] - r))
        for point in pair:
            if not any(math.dist(point, (s["x"], s["y"])) < 2 for s in symbols):
                symbols.append({"kind": "roundel", "x": point[0], "y": point[1], "diameter": 2 * r, "compound": True})
    symbols.sort(key=lambda s: (round(s["y"], 3), round(s["x"], 3)))
    return symbols


def extract_ticks(paths: list[dict]) -> list[dict]:
    ticks = []
    for path in paths:
        if path["stroke"] or path["fill"] in (None, WHITE):
            continue
        quad = _quadrilateral(path)
        if not quad:
            continue
        sides = [math.dist(quad[k], quad[(k + 1) % 4]) for k in range(4)]
        long_index = 0 if sides[0] >= sides[1] else 1
        length, width = sides[long_index], sides[1 - long_index]
        if not (width > 0 and length / width > 1.5 and 6 <= length <= 22 and 2.4 <= width <= 7):
            continue
        line = next((line for line, colour in LINE_COLOURS.items() if _close(path["fill"], colour)), None)
        if line is None:
            continue
        a, b = quad[long_index], quad[long_index + 1]
        ticks.append({
            "lines": sorted(line_id for line_id, colour in LINE_COLOURS.items() if _close(path["fill"], colour)),
            "x": sum(point[0] for point in quad) / 4,
            "y": sum(point[1] for point in quad) / 4,
            "length": length,
            "width": width,
            "angle": math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 180,
        })
    ticks.sort(key=lambda t: (round(t["y"], 3), round(t["x"], 3)))
    return ticks


def extract_connectors(paths: list[dict], symbols: list[dict]) -> list[dict]:
    rectangles = []
    for path in paths:
        if path["stroke"] or path["fill"] not in (BLACK, WHITE):
            continue
        quad = _quadrilateral(path)
        if not quad:
            continue
        sides = [math.dist(quad[k], quad[(k + 1) % 4]) for k in range(4)]
        k = 0 if sides[0] >= sides[1] else 1
        rectangles.append({
            "fill": path["fill"],
            "centre": (sum(p[0] for p in quad) / 4, sum(p[1] for p in quad) / 4),
            "length": sides[k], "width": sides[1 - k],
            "angle": math.degrees(math.atan2(quad[k + 1][1] - quad[k][1], quad[k + 1][0] - quad[k][0])) % 180,
        })
    bars = []
    for outer in rectangles:
        if outer["fill"] != BLACK or not (11.8 < outer["width"] < 13.4):
            continue
        if not any(
            inner["fill"] == WHITE and 3.6 < inner["width"] < 4.8
            and math.dist(inner["centre"], outer["centre"]) < 6
            and abs(((inner["angle"] - outer["angle"]) + 90) % 180 - 90) < 2
            for inner in rectangles
        ):
            continue
        bars.append({"centre": outer["centre"], "length": outer["length"], "angle": round(outer["angle"], 2)})
    for symbol in symbols:
        if symbol.get("compound"):
            partner = min(
                (other for other in symbols if other is not symbol and other.get("compound")),
                key=lambda other: math.dist((other["x"], other["y"]), (symbol["x"], symbol["y"])),
            )
            a, b = (symbol["x"], symbol["y"]), (partner["x"], partner["y"])
            if a < b:
                bars.append({
                    "centre": ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2), "length": math.dist(a, b),
                    "angle": round(math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 180, 2),
                })
    # Long bars are sometimes drawn as overlapping collinear pieces.
    merged: list[dict] = []
    for bar in sorted(bars, key=lambda b: (b["angle"], b["centre"])):
        u = (math.cos(math.radians(bar["angle"])), math.sin(math.radians(bar["angle"])))
        for existing in merged:
            if abs(((existing["angle"] - bar["angle"]) + 90) % 180 - 90) > 1:
                continue
            v = (bar["centre"][0] - existing["centre"][0], bar["centre"][1] - existing["centre"][1])
            along = v[0] * u[0] + v[1] * u[1]
            if abs(-v[0] * u[1] + v[1] * u[0]) < 2 and abs(along) <= (existing["length"] + bar["length"]) / 2 + 1:
                low = min(-existing["length"] / 2, along - bar["length"] / 2)
                high = max(existing["length"] / 2, along + bar["length"] / 2)
                existing["centre"] = (existing["centre"][0] + u[0] * (low + high) / 2, existing["centre"][1] + u[1] * (low + high) / 2)
                existing["length"] = high - low
                break
        else:
            merged.append(dict(bar))
    merged.sort(key=lambda b: (round(b["centre"][1], 3), round(b["centre"][0], 3)))
    return merged


def extract_walking_links(paths: list[dict], symbols: list[dict]) -> list[dict]:
    """Symbol pairs joined by evenly spaced black squares (TfL walking links)."""
    dots = []
    for path in paths:
        if path["stroke"] or path["fill"] != BLACK:
            continue
        width, height = _size(path["bbox"])
        quad = _quadrilateral(path)
        if not quad or width >= 10.5 or height >= 10.5:
            continue
        sides = [math.dist(quad[k], quad[(k + 1) % 4]) for k in range(4)]
        if max(sides) / max(min(sides), 1e-6) <= 1.3:
            dots.append(_centre(path["bbox"]))
    links = []
    anchors = [s for s in symbols if s["kind"] != "roundel" or s["diameter"] < 28.5]
    for i, a in enumerate(anchors):
        for b in anchors[i + 1:]:
            pa, pb = (a["x"], a["y"]), (b["x"], b["y"])
            distance = math.dist(pa, pb)
            if distance < 2 * ROUNDEL_RADIUS + 2 or distance > 170:
                continue
            u = ((pb[0] - pa[0]) / distance, (pb[1] - pa[1]) / distance)
            on = sorted(
                v[0] * u[0] + v[1] * u[1]
                for v in ((dot[0] - pa[0], dot[1] - pa[1]) for dot in dots)
                if abs(-v[0] * u[1] + v[1] * u[0]) <= 2.0
                and ROUNDEL_RADIUS - 3 <= v[0] * u[0] + v[1] * u[1] <= distance - ROUNDEL_RADIUS + 3
            )
            if not on:
                continue
            gaps = [second - first for first, second in zip(on, on[1:])]
            # A crossing line can hide a dot or two, as at Vauxhall.
            spaced = max(gaps, default=0) <= 11 or (len(on) >= 3 and max(gaps) <= 22)
            if spaced and on[0] - ROUNDEL_RADIUS <= 9 and distance - ROUNDEL_RADIUS - on[-1] <= 9:
                links.append({"a": [pa[0], pa[1]], "b": [pb[0], pb[1]], "dots": len(on)})
    return links


def extract_line_strokes(paths: list[dict]) -> dict[str, list[list[dict]]]:
    strokes: dict[str, list[list[dict]]] = {line: [] for line in LINE_COLOURS}
    for path in paths:
        if not path["stroke"] or not (LINE_STROKE_WIDTHS[0] < path["strokeWidth"] < LINE_STROKE_WIDTHS[1]):
            continue
        line = next((line for line, colour in LINE_COLOURS.items() if _close(path["stroke"], colour)), None)
        if line is None:
            continue
        commands = []
        for command in path["commands"]:
            if command[0] == "M":
                commands.append({"op": "move", "to": _point(command[1])})
            elif command[0] == "L":
                commands.append({"op": "line", "to": _point(command[1])})
            elif command[0] == "C":
                commands.append({
                    "op": "cubic", "control1": _point(command[1]),
                    "control2": _point(command[2]), "to": _point(command[3]),
                })
        if len(commands) > 1:
            strokes[line].append(commands)
    return strokes


def _point(value) -> dict[str, float]:
    return {"x": round(value[0], 3), "y": round(value[1], 3)}


def extract_labels(words_path: Path) -> list[dict]:
    source = words_path.read_text()
    labels = []
    for block_index, block in enumerate(re.finditer(r"<block[^>]*>(.*?)</block>", source, re.S)):
        for line in re.finditer(
            r'<line xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</line>',
            block.group(1), re.S,
        ):
            words = [html.unescape(word) for word in re.findall(r"<word[^>]*>([^<]*)</word>", line.group(5))]
            labels.append({
                "block": block_index,
                "box": [round(float(value) * SCALE, 3) for value in line.groups()[:4]],
                "text": " ".join(words),
            })
    return labels


def _rounded(value):
    if isinstance(value, float):
        return round(value, 3)
    if isinstance(value, (list, tuple)):
        return [_rounded(item) for item in value]
    if isinstance(value, dict):
        return {key: _rounded(item) for key, item in value.items()}
    return value


def extract(svg_path: Path, words_path: Path, revision: str) -> dict:
    paths = drawable_paths(svg_path)
    symbols = extract_symbols(paths)
    return _rounded({
        "schemaVersion": 1,
        "revision": revision,
        "artworkUnitsPerPoint": SCALE,
        "symbols": symbols,
        "ticks": extract_ticks(paths),
        "connectors": extract_connectors(paths, symbols),
        "walkingLinks": extract_walking_links(paths, symbols),
        "labels": extract_labels(words_path),
        "lineStrokes": extract_line_strokes(paths),
    })


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--svg", required=True, type=Path)
    parser.add_argument("--words", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    reference = extract(arguments.svg, arguments.words, arguments.revision)
    arguments.output.write_text(json.dumps(reference, separators=(",", ":"), sort_keys=True) + "\n")
    print(
        f"{len(reference['symbols'])} symbols, {len(reference['ticks'])} ticks, "
        f"{len(reference['connectors'])} bars, {len(reference['walkingLinks'])} walking links"
    )


if __name__ == "__main__":
    main()
