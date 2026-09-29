#!/usr/bin/env python3
"""Give National Rail segments their real track geometry from TrainTrack UK.

TfL publishes Thameslink route geometry only as station-to-station chords, and
the Underground-focused OSM filter in this folder does not carry National Rail
relations. TrainTrack UK already bundles a routed Great Britain railway graph
built from OpenStreetMap, with passenger-track anchors for every National Rail
station keyed by CRS code. This matches each of a line's stations to a CRS by
name (checked against its coordinates), routes every segment between the two
stations' anchors, and writes the result into TubeGraph.json's
`geographicPoints`. Nothing else in the graph changes.

Usage:
    route_national_rail_geography.py --train-track /path/to/train-track-uk [--lines thameslink]
"""

from __future__ import annotations

import argparse
import heapq
import json
import math
import re
import sys
from pathlib import Path

GRAPH = Path(__file__).resolve().parents[2] / "TubeTrackUK" / "Resources" / "TubeGraph.json"
ROUTING_ASSET = Path("ios/TrainTrack UK/TrainTrack UK/Resources/railway-routing-great-britain-osm.json")
STATION_CATALOGUE = Path("api/train-track-api/resources/stations.json")
# A catalogue station with the right name must also be where the graph says.
MAXIMUM_MATCH_DISTANCE_M = 1_500
# A routed segment much longer than the straight line has found a detour
# through another corridor rather than the track between adjacent stations.
MAXIMUM_DETOUR_RATIO = 2.2
# TrainTrack keeps anchors on several corridors around a station, some several
# hundred metres off; a segment must start and end at the platforms.
MAXIMUM_ANCHOR_OFFSET_M = 200


def distance_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Haversine distance between two (longitude, latitude) points."""
    lon1, lat1, lon2, lat2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


def normalised_name(name: str) -> str:
    name = name.lower().replace("&", " and ").replace("st.", "st")
    name = re.sub(r"\((london|kent|surrey|beds|herts)\)", " ", name)
    name = re.sub(r"\b(rail station|station|international|london)\b", " ", name)
    return " ".join(re.sub(r"[^a-z0-9 ]", " ", name).split())


def match_stations(stations: list[dict], catalogue: list[dict]) -> dict[str, str]:
    by_name: dict[str, list[dict]] = {}
    for entry in catalogue:
        by_name.setdefault(normalised_name(entry["name"]), []).append(entry)
    matches: dict[str, str] = {}
    missing: list[str] = []
    for station in stations:
        point = (float(station["longitude"]), float(station["latitude"]))
        candidates = [
            (distance_m(point, (float(entry["longitude"]), float(entry["latitude"]))), entry["crs"])
            for entry in by_name.get(normalised_name(station["name"]), [])
        ]
        candidates = [candidate for candidate in candidates if candidate[0] <= MAXIMUM_MATCH_DISTANCE_M]
        if candidates:
            matches[station["id"]] = min(candidates)[1]
        else:
            missing.append(f"{station['name']} ({station['id']})")
    if missing:
        raise ValueError(f"No TrainTrack station matches: {', '.join(missing)}")
    return matches


class RailwayGraph:
    def __init__(self, asset: dict):
        self.nodes = [tuple(node) for node in asset["nodes"]]
        self.edges = asset["edges"]
        self.anchors = asset["stationAnchors"]
        self.adjacency: list[list[tuple[int, int]]] = [[] for _ in self.nodes]
        for index, edge in enumerate(self.edges):
            self.adjacency[edge["s"]].append((edge["e"], index))
            self.adjacency[edge["e"]].append((edge["s"], index))

    def station_anchors(self, crs: str) -> list[dict]:
        anchors = self.anchors.get(crs, [])
        near = [anchor for anchor in anchors if anchor["d"] <= MAXIMUM_ANCHOR_OFFSET_M]
        return near or sorted(anchors, key=lambda anchor: anchor["d"])[:1]

    def route(self, from_crs: str, to_crs: str) -> list[tuple[float, float]] | None:
        """Cheapest weighted path between two stations' anchor tracks (A*)."""
        targets = {anchor["n"]: anchor["d"] for anchor in self.station_anchors(to_crs)}
        sources = self.station_anchors(from_crs)
        if not targets or not sources:
            return None
        goal = self.nodes[next(iter(targets))]
        costs: dict[int, float] = {}
        previous: dict[int, tuple[int, int] | None] = {}
        queue: list[tuple[float, float, int]] = []
        for anchor in sources:
            node, cost = anchor["n"], anchor["d"]
            if cost < costs.get(node, math.inf):
                costs[node] = cost
                previous[node] = None
                heapq.heappush(queue, (cost + distance_m(self.nodes[node], goal), cost, node))
        best_end: tuple[float, int] | None = None
        while queue:
            _, cost, node = heapq.heappop(queue)
            if cost > costs.get(node, math.inf):
                continue
            if best_end is not None and cost >= best_end[0]:
                break
            if node in targets:
                total = cost + targets[node]
                if best_end is None or total < best_end[0]:
                    best_end = (total, node)
            for neighbour, edge_index in self.adjacency[node]:
                candidate = cost + self.edges[edge_index]["c"]
                if candidate < costs.get(neighbour, math.inf):
                    costs[neighbour] = candidate
                    previous[neighbour] = (node, edge_index)
                    heapq.heappush(queue, (candidate + distance_m(self.nodes[neighbour], goal), candidate, neighbour))
        if best_end is None:
            return None

        points: list[tuple[float, float]] = []
        node = best_end[1]
        chain: list[tuple[int, int]] = []
        while previous[node] is not None:
            prior, edge_index = previous[node]
            chain.append((prior, edge_index))
            node = prior
        points.append(self.nodes[node])
        for prior, edge_index in reversed(chain):
            edge = self.edges[edge_index]
            polyline = [tuple(point) for point in edge["p"]]
            if edge["s"] != prior:
                polyline.reverse()
            points.extend(polyline[1:] if points and polyline and math.dist(points[-1], polyline[0]) < 1e-7 else polyline)
        return points


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--train-track", required=True, type=Path, help="TrainTrack UK repository root")
    parser.add_argument("--graph", type=Path, default=GRAPH)
    parser.add_argument("--lines", default="thameslink")
    arguments = parser.parse_args()

    graph = json.loads(arguments.graph.read_text())
    line_ids = set(arguments.lines.split(","))
    routing_path = arguments.train_track / ROUTING_ASSET
    print(f"Loading {routing_path}...", file=sys.stderr)
    asset = json.loads(routing_path.read_text())
    railway = RailwayGraph(asset)
    catalogue = json.loads((arguments.train_track / STATION_CATALOGUE).read_text())

    stations = {station["id"]: station for station in graph["stations"]}
    segments = [segment for segment in graph["segments"] if segment["lineID"] in line_ids]
    endpoints = {station_id for segment in segments for station_id in (segment["fromStationID"], segment["toStationID"])}
    crs_by_station = match_stations([stations[station_id] for station_id in sorted(endpoints)], catalogue)

    errors: list[str] = []
    for segment in segments:
        first, second = stations[segment["fromStationID"]], stations[segment["toStationID"]]
        route = railway.route(crs_by_station[first["id"]], crs_by_station[second["id"]])
        straight = distance_m(
            (float(first["longitude"]), float(first["latitude"])),
            (float(second["longitude"]), float(second["latitude"])),
        )
        if route is None:
            errors.append(f"{segment['id']}: no OSM route")
            continue
        length = sum(distance_m(a, b) for a, b in zip(route, route[1:]))
        if length > max(straight * MAXIMUM_DETOUR_RATIO, straight + 800):
            errors.append(f"{segment['id']}: {length:.0f} m route for a {straight:.0f} m hop")
            continue
        segment["geographicPoints"] = [
            {"latitude": round(latitude, 6), "longitude": round(longitude, 6)}
            for longitude, latitude in route
        ]
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    arguments.graph.write_text(json.dumps(graph, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(f"Routed {len(segments)} {', '.join(sorted(line_ids))} segments over OpenStreetMap track", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
