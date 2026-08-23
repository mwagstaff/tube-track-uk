"""Offline OpenStreetMap railway router for TubeTrack UK's bundled map asset.

This follows the same approach used by Train Track UK: parse a reproducible OSM
snapshot, retain route-relation track geometry, snap stations to candidate graph
nodes, and find the shortest continuous railway path between calling points.
"""

from __future__ import annotations

import heapq
import math
from collections import defaultdict
from pathlib import Path
from typing import Any

try:
    import osmium
except ImportError as error:  # pragma: no cover - depends on the offline build environment
    raise RuntimeError(
        "pyosmium is required for --osm-pbf builds. Install pyosmium or use "
        "Train Track UK's scripts/.osm-routing-venv Python."
    ) from error


EARTH_RADIUS_METRES = 6_371_008.8
LINE_REFS = {
    "bakerloo": "bakerloo",
    "central": "central",
    "circle": "circle",
    "district": "district",
    "hammersmith & city": "hammersmith-city",
    "hammersmith and city": "hammersmith-city",
    "jubilee": "jubilee",
    "metropolitan": "metropolitan",
    "northern": "northern",
    "piccadilly": "piccadilly",
    "victoria": "victoria",
    "waterloo & city": "waterloo-city",
    "waterloo and city": "waterloo-city",
    "dlr": "dlr",
    "docklands light railway": "dlr",
    "elizabeth line": "elizabeth",
    "elizabeth": "elizabeth",
    "liberty": "liberty",
    "liberty line": "liberty",
    "lioness": "lioness",
    "lioness line": "lioness",
    "mildmay": "mildmay",
    "mildmay line": "mildmay",
    "suffragette": "suffragette",
    "suffragette line": "suffragette",
    "weaver": "weaver",
    "weaver line": "weaver",
    "windrush": "windrush",
    "windrush line": "windrush",
}

OVERGROUND_LINE_IDS = {"liberty", "lioness", "mildmay", "suffragette", "weaver", "windrush"}

Coordinate = tuple[float, float]  # longitude, latitude


def distance_metres(first: Coordinate, second: Coordinate) -> float:
    longitude1, latitude1 = map(math.radians, first)
    longitude2, latitude2 = map(math.radians, second)
    latitude_delta = latitude2 - latitude1
    longitude_delta = longitude2 - longitude1
    haversine = (
        math.sin(latitude_delta / 2) ** 2
        + math.cos(latitude1) * math.cos(latitude2) * math.sin(longitude_delta / 2) ** 2
    )
    return 2 * EARTH_RADIUS_METRES * math.asin(math.sqrt(haversine))


class _TubeRailwayHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.nodes: dict[int, Coordinate] = {}
        self.ways: dict[int, tuple[int, ...]] = {}
        self.line_way_ids: dict[str, set[int]] = defaultdict(set)

    def node(self, node: Any) -> None:
        if node.location.valid():
            self.nodes[node.id] = (node.location.lon, node.location.lat)

    def way(self, way: Any) -> None:
        tags = dict(way.tags)
        if tags.get("railway") not in {"subway", "rail", "light_rail"}:
            return
        node_ids = tuple(reference.ref for reference in way.nodes)
        if len(node_ids) >= 2:
            self.ways[way.id] = node_ids

    def relation(self, relation: Any) -> None:
        tags = dict(relation.tags)
        if tags.get("type") != "route" or tags.get("route") not in {"subway", "light_rail", "train"}:
            return
        network = tags.get("network", "").lower()
        metro_network = tags.get("network:metro", "").lower()
        name = tags.get("name", "").lower()
        reference = (tags.get("ref") or tags.get("line") or "").strip().lower()
        is_tfl_rail = (
            "london underground" in network
            or "docklands light railway" in network
            or "elizabeth" in network
            or "london overground" in network
            or "london overground" in metro_network
            or "dlr" in reference
            or "elizabeth" in reference
            or "dlr" in name
            or "elizabeth line" in name
        )
        if not is_tfl_rail:
            return
        line_id = LINE_REFS.get(reference)
        if line_id is None:
            line_id = next((value for key, value in LINE_REFS.items() if key in name), None)
        if line_id is None:
            return
        if line_id in OVERGROUND_LINE_IDS and not (
            "london overground" in network or "london overground" in metro_network
        ):
            return
        self.line_way_ids[line_id].update(
            member.ref for member in relation.members if member.type == "w"
        )


class OSMTubeRailwayRouter:
    def __init__(self, source: Path) -> None:
        handler = _TubeRailwayHandler()
        handler.apply_file(str(source), locations=False)
        self.coordinates = handler.nodes
        self.adjacency_by_line: dict[str, dict[int, list[tuple[int, float]]]] = {}
        self.nodes_by_line: dict[str, tuple[int, ...]] = {}

        for line_id, way_ids in handler.line_way_ids.items():
            adjacency: dict[int, list[tuple[int, float]]] = defaultdict(list)
            for way_id in way_ids:
                node_ids = handler.ways.get(way_id, ())
                for start, end in zip(node_ids, node_ids[1:]):
                    if start not in self.coordinates or end not in self.coordinates:
                        continue
                    length = distance_metres(self.coordinates[start], self.coordinates[end])
                    if length <= 0:
                        continue
                    adjacency[start].append((end, length))
                    adjacency[end].append((start, length))
            self.adjacency_by_line[line_id] = dict(adjacency)
            self.nodes_by_line[line_id] = tuple(adjacency)

        missing = sorted(set(LINE_REFS.values()) - set(self.adjacency_by_line))
        if missing:
            raise RuntimeError(f"OSM snapshot has no TfL rail route geometry for: {', '.join(missing)}")

    def path(
        self,
        line_id: str,
        start: Coordinate,
        end: Coordinate,
    ) -> list[dict[str, float]] | None:
        adjacency = self.adjacency_by_line.get(line_id)
        node_ids = self.nodes_by_line.get(line_id)
        if not adjacency or not node_ids:
            return None

        direct = distance_metres(start, end)
        route = self._route_node_ids(
            adjacency,
            node_ids,
            start,
            end,
            direct,
            candidate_count=16,
        )
        if route is None:
            # Interchange coordinates can sit closer to another branch than to
            # their own platform (notably DLR Stratford). Widen the snap search
            # only after the normal search fails so established routes remain
            # unchanged. Limit that retry to plausible nearby rails and make a
            # distant endpoint snap more expensive than following the track.
            route = self._route_node_ids(
                adjacency,
                node_ids,
                start,
                end,
                direct,
                candidate_count=64,
                maximum_extra_snap=100.0,
                snap_weight=5.0,
            )
        if route is None:
            return None

        coordinates = [self.coordinates[node_id] for node_id in route]
        return [
            {"latitude": round(latitude, 6), "longitude": round(longitude, 6)}
            for longitude, latitude in coordinates
        ]

    def _route_node_ids(
        self,
        adjacency: dict[int, list[tuple[int, float]]],
        node_ids: tuple[int, ...],
        start: Coordinate,
        end: Coordinate,
        direct: float,
        candidate_count: int,
        maximum_extra_snap: float | None = None,
        snap_weight: float = 1.0,
    ) -> list[int] | None:
        start_candidates = self._nearest_nodes(node_ids, start, count=candidate_count)
        end_candidates = self._nearest_nodes(node_ids, end, count=candidate_count)
        if maximum_extra_snap is not None:
            start_limit = start_candidates[0][1] + maximum_extra_snap
            end_limit = end_candidates[0][1] + maximum_extra_snap
            start_candidates = [candidate for candidate in start_candidates if candidate[1] <= start_limit]
            end_candidates = [candidate for candidate in end_candidates if candidate[1] <= end_limit]
        start_nodes = {node_id for node_id, _ in start_candidates}
        targets = {
            node_id: snap * snap_weight
            for node_id, snap in end_candidates
            if direct < 100 or node_id not in start_nodes
        }
        maximum_cost = max(2_500.0, direct * 4.0 + 1_500.0)

        distances: dict[int, float] = {}
        previous: dict[int, int] = {}
        queue: list[tuple[float, int]] = []
        for node_id, snap in start_candidates:
            weighted_snap = snap * snap_weight
            distances[node_id] = weighted_snap
            heapq.heappush(queue, (weighted_snap, node_id))

        best_target: int | None = None
        best_score = math.inf
        while queue:
            cost, node_id = heapq.heappop(queue)
            if cost != distances.get(node_id) or cost > min(maximum_cost, best_score):
                continue
            if node_id in targets and cost + targets[node_id] < best_score:
                best_target = node_id
                best_score = cost + targets[node_id]
            for neighbour, length in adjacency.get(node_id, ()):
                next_cost = cost + length
                if next_cost >= distances.get(neighbour, math.inf) or next_cost > maximum_cost:
                    continue
                distances[neighbour] = next_cost
                previous[neighbour] = node_id
                heapq.heappush(queue, (next_cost, neighbour))

        if best_target is None:
            return None
        route = [best_target]
        while route[-1] in previous:
            route.append(previous[route[-1]])
        route.reverse()
        if len(route) < 2:
            return None
        return route

    def _nearest_nodes(
        self,
        node_ids: tuple[int, ...],
        coordinate: Coordinate,
        count: int,
    ) -> list[tuple[int, float]]:
        # Route graphs are small enough for deterministic build-time scanning.
        return heapq.nsmallest(
            count,
            ((node_id, distance_metres(coordinate, self.coordinates[node_id])) for node_id in node_ids),
            key=lambda value: value[1],
        )
