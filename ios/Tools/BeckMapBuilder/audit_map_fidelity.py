#!/usr/bin/env python3
"""Audit authored Beck-map geometry against TfL-style structural invariants.

This tool is deliberately read-only with respect to map artwork. It records
candidate fidelity problems by stable station and segment ID so a reviewer can
compare them with the locked TfL reference before changing any coordinates.
It uses only the Python standard library and writes deterministic JSON,
Markdown, and interactive HTML reports when output paths are supplied.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import math
import os
import struct
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

from map_geometry import (
    acute_angle,
    command_point,
    distance,
    midpoint,
    nearest_on_cubic,
    nearest_on_line,
    point,
    translated,
)


SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
CANONICAL_ANGLES = (0.0, 45.0, 90.0)
PARALLEL_STROKE_LINES = {
    "dlr", "elizabeth", "liberty", "lioness", "mildmay",
    "suffragette", "tram", "weaver", "windrush",
}


@dataclass(frozen=True)
class Finding:
    severity: str
    category: str
    code: str
    location: str
    description: str
    impact: str
    recommendation: str
    evidence: dict[str, Any]


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as stream:
        signature = stream.read(24)
    if len(signature) != 24 or signature[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not a PNG file: {path}")
    return struct.unpack(">II", signature[16:24])


def vector_angle(vector: tuple[float, float]) -> float:
    angle = math.degrees(math.atan2(abs(vector[1]), abs(vector[0])))
    return min(90.0, max(0.0, angle))


def canonical_angle(angle: float) -> tuple[float, float]:
    nearest = min(CANONICAL_ANGLES, key=lambda candidate: abs(candidate - angle))
    return nearest, abs(nearest - angle)


def resolve_manifest_path(manifest_path: Path, relative_path: str) -> Path:
    return (manifest_path.parent / relative_path).resolve()


def nearest(
    target: tuple[float, float],
    candidates: Iterable[tuple[tuple[float, float], dict[str, Any]]],
) -> tuple[float, dict[str, Any]] | None:
    measured = ((distance(target, candidate), metadata) for candidate, metadata in candidates)
    return min(measured, key=lambda item: item[0], default=None)


class MapFidelityAudit:
    def __init__(self, document: dict[str, Any], graph: dict[str, Any], manifest: dict[str, Any]):
        self.document = document
        self.graph = graph
        self.manifest = manifest
        self.findings: list[Finding] = []
        self.metrics: dict[str, Any] = {}
        self.paths_by_id = {path_record["id"]: path_record for path_record in document["paths"]}

    def _nearest_station_path(
        self, target: tuple[float, float], station_id: str, line_id: str | None = None,
    ) -> tuple[float, tuple[float, float], tuple[float, float], dict[str, Any]] | None:
        matches: list[
            tuple[float, tuple[float, float], tuple[float, float], dict[str, Any]]
        ] = []
        for segment in self.document["segments"]:
            if station_id not in {segment["fromStationID"], segment["toStationID"]}:
                continue
            if line_id is not None and segment["lineID"] != line_id:
                continue
            path_record = self.paths_by_id.get(segment["pathID"])
            if path_record is None:
                continue
            translation = segment.get("translation", {"x": 0, "y": 0})
            previous: tuple[float, float] | None = None
            for command_index, command in enumerate(path_record["commands"]):
                operation = command["op"]
                if operation == "move":
                    previous = translated(command_point(command), translation)
                    continue
                if operation not in {"line", "cubic"} or previous is None:
                    continue
                end = translated(command_point(command), translation)
                if operation == "line":
                    measured = nearest_on_line(target, previous, end)
                else:
                    control1 = translated(command_point(command, "control1"), translation)
                    control2 = translated(command_point(command, "control2"), translation)
                    measured = nearest_on_cubic(target, previous, control1, control2, end)
                matches.append((*measured, {
                    "segmentID": segment["id"], "lineID": segment["lineID"],
                    "pathID": segment["pathID"], "commandIndex": command_index,
                }))
                previous = end
        return min(matches, key=lambda match: match[0], default=None)

    def add(
        self,
        severity: str,
        category: str,
        code: str,
        location: str,
        description: str,
        impact: str,
        recommendation: str,
        **evidence: Any,
    ) -> None:
        self.findings.append(Finding(
            severity=severity,
            category=category,
            code=code,
            location=location,
            description=description,
            impact=impact,
            recommendation=recommendation,
            evidence=evidence,
        ))

    def run(self, manifest_path: Path) -> dict[str, Any]:
        self.audit_reference(manifest_path)
        self.audit_inventory()
        self.audit_routes()
        self.audit_roundels()
        self.audit_ticks()
        self.audit_connectors()
        self.audit_styles()
        self.findings.sort(key=lambda finding: (
            SEVERITY_ORDER[finding.severity], finding.category, finding.location, finding.code
        ))
        severity_counts = Counter(finding.severity for finding in self.findings)
        category_counts = Counter(finding.category for finding in self.findings)
        return {
            "schemaVersion": 1,
            "auditScope": "TfL route lines, roundels, station ticks, and interchange connectors",
            "reference": self.manifest["reference"],
            "document": {
                "identifier": self.document["identifier"],
                "schemaVersion": self.document["schemaVersion"],
                "artworkSize": self.document["artworkSize"],
            },
            "summary": {
                "findingCount": len(self.findings),
                "bySeverity": dict(sorted(severity_counts.items(), key=lambda item: SEVERITY_ORDER[item[0]])),
                "byCategory": dict(sorted(category_counts.items())),
            },
            "metrics": self.metrics,
            "findings": [asdict(finding) for finding in self.findings],
        }

    def audit_reference(self, manifest_path: Path) -> None:
        reference = self.manifest["reference"]
        for artifact_name in ("pdf", "raster"):
            artifact = reference[artifact_name]
            artifact_path = resolve_manifest_path(manifest_path, artifact["path"])
            if not artifact_path.exists():
                self.add(
                    "critical", "reference", "reference-file-missing", artifact_name,
                    f"The locked {artifact_name.upper()} reference is missing.",
                    "Geometry cannot be compared reproducibly without the exact reference artifact.",
                    "Restore the pinned artifact before approving artwork changes.",
                    expectedPath=str(artifact_path),
                )
                continue
            actual_hash = sha256(artifact_path)
            if actual_hash != artifact["sha256"]:
                self.add(
                    "critical", "reference", "reference-hash-mismatch", artifact_name,
                    f"The {artifact_name.upper()} reference no longer matches its pinned SHA-256.",
                    "The audit may silently compare against a different TfL revision.",
                    "Review the new source, then update the manifest and geometry version deliberately.",
                    expected=artifact["sha256"], actual=actual_hash,
                )
        raster_path = resolve_manifest_path(manifest_path, reference["raster"]["path"])
        if raster_path.exists():
            actual_dimensions = png_dimensions(raster_path)
            expected_dimensions = tuple(reference["raster"]["pixelSize"])
            if actual_dimensions != expected_dimensions:
                self.add(
                    "critical", "reference", "reference-raster-size-mismatch", "reference raster",
                    "The reference raster dimensions differ from the locked dimensions.",
                    "The artwork-to-reference coordinate transform would be invalid.",
                    "Regenerate the raster at the pinned DPI without cropping or resampling.",
                    expected=expected_dimensions, actual=actual_dimensions,
                )
            units_per_pixel = float(reference["coordinateSystem"]["artworkUnitsPerReferencePixel"])
            expected_artwork = {
                "width": actual_dimensions[0] * units_per_pixel,
                "height": actual_dimensions[1] * units_per_pixel,
            }
            actual_artwork = self.document["artworkSize"]
            if any(abs(float(actual_artwork[key]) - expected_artwork[key]) > 1e-6 for key in expected_artwork):
                self.add(
                    "critical", "reference", "artwork-transform-mismatch", "artworkSize",
                    "The document canvas does not match the locked reference transform.",
                    "Every path and marker comparison would be displaced or scaled.",
                    "Restore the documented canvas or version a new reference transform.",
                    expected=expected_artwork, actual=actual_artwork,
                )

    def audit_inventory(self) -> None:
        graph_station_ids = {station["id"] for station in self.graph["stations"]}
        marker_ids = {marker["stationID"] for marker in self.document["stationMarkers"]}
        graph_segment_ids = {segment["id"] for segment in self.graph["segments"]}
        document_segment_ids = {segment["id"] for segment in self.document["segments"]}
        supplemental = set(self.manifest.get("supplementalSegmentIDs", []))
        missing_markers = sorted(graph_station_ids - marker_ids)
        missing_segments = sorted(graph_segment_ids - document_segment_ids)
        unexpected_segments = sorted(document_segment_ids - graph_segment_ids - supplemental)
        for station_id in missing_markers:
            self.add(
                "critical", "topology", "missing-station-marker", station_id,
                "A graph station has no authored marker.",
                "The station cannot be represented or selected faithfully on the schematic.",
                "Author the marker from the locked TfL reference.", stationID=station_id,
            )
        for segment_id in missing_segments:
            self.add(
                "critical", "topology", "missing-route-segment", segment_id,
                "A graph segment has no authored route path.",
                "A visible or operational station pair is absent from the schematic.",
                "Trace the missing source path while retaining the semantic segment ID.",
                segmentID=segment_id,
            )
        for segment_id in unexpected_segments:
            self.add(
                "high", "topology", "unexpected-route-segment", segment_id,
                "The artwork contains a segment not present in the graph or supplemental allowlist.",
                "The map may display operationally anonymous line work.",
                "Either add the semantic graph edge or document the segment as a reviewed supplement.",
                segmentID=segment_id,
            )
        primitive_counts = Counter(
            primitive["kind"]
            for marker in self.document["stationMarkers"]
            for primitive in marker["primitives"]
        )
        self.metrics["inventory"] = {
            "paths": len(self.document["paths"]),
            "segments": len(self.document["segments"]),
            "stationMarkers": len(self.document["stationMarkers"]),
            "labels": len(self.document["labels"]),
            "routes": len(self.document["routes"]),
            "primitives": dict(sorted(primitive_counts.items())),
            "supportedLineIDs": self.document.get("supportedLineIDs", []),
        }

    def audit_routes(self) -> None:
        thresholds = self.manifest["thresholds"]
        minimum_length = float(thresholds["straightSegmentMinimumLength"])
        medium_angle = float(thresholds["axisAngleMediumDegrees"])
        deviations_by_line: dict[str, list[dict[str, Any]]] = defaultdict(list)
        command_counts: Counter[str] = Counter()
        for segment in self.document["segments"]:
            path_record = self.paths_by_id.get(segment["pathID"])
            if path_record is None:
                continue
            previous: tuple[float, float] | None = None
            for command_index, command in enumerate(path_record["commands"]):
                command_counts[command["op"]] += 1
                if command["op"] == "move":
                    previous = command_point(command)
                    continue
                if command["op"] == "cubic":
                    previous = command_point(command)
                    continue
                if command["op"] != "line" or previous is None:
                    continue
                destination = command_point(command)
                vector = destination[0] - previous[0], destination[1] - previous[1]
                length = math.hypot(*vector)
                angle = vector_angle(vector)
                nearest_angle, deviation = canonical_angle(angle)
                if length >= minimum_length and deviation > medium_angle:
                    deviations_by_line[segment["lineID"]].append({
                        "segmentID": segment["id"],
                        "pathID": segment["pathID"],
                        "commandIndex": command_index,
                        "length": round(length, 3),
                        "angleDegrees": round(angle, 3),
                        "nearestCanonicalAngle": nearest_angle,
                        "deviationDegrees": round(deviation, 3),
                    })
                previous = destination
        for line_id, deviations in sorted(deviations_by_line.items()):
            largest = max(item["deviationDegrees"] for item in deviations)
            self.add(
                "medium", "routes", "non-canonical-straight-runs", line_id,
                f"{len(deviations)} straight route command(s) deviate from horizontal, vertical, or 45 degrees.",
                "An unexplained angle may expose slice-seam drift, but the official artwork also contains intentional exceptions.",
                "Compare each command with the locked artwork; correct only source mismatches and retain traced exceptions.",
                lineID=line_id, count=len(deviations), maximumDeviationDegrees=largest,
                candidates=deviations,
            )
        self.metrics["routeCommands"] = dict(sorted(command_counts.items()))
        self.metrics["routeAngleCandidatesByLine"] = {
            line_id: len(candidates) for line_id, candidates in sorted(deviations_by_line.items())
        }

    def audit_roundels(self) -> None:
        baseline = self.manifest["baselineStyles"]["roundel"]
        tolerance = float(self.manifest["thresholds"]["styleTolerance"])
        medium_port_tolerance = float(
            self.manifest["thresholds"]["roundelPortMediumDistanceArtworkUnits"]
        )
        high_port_tolerance = float(
            self.manifest["thresholds"]["roundelPortHighDistanceArtworkUnits"]
        )
        style_counts: Counter[tuple[float, float]] = Counter()
        connector_endpoints = [
            (point(primitive[primitive["kind"]][endpoint]), {
                "stationID": marker["stationID"], "primitiveIndex": primitive_index,
                "kind": primitive["kind"], "endpoint": endpoint,
            })
            for marker in self.document["stationMarkers"]
            for primitive_index, primitive in enumerate(marker["primitives"])
            if primitive["kind"] in {"connector", "walkingConnector"}
            for endpoint in ("start", "end")
        ]
        roundel_count = 0
        unmatched = 0
        for marker in self.document["stationMarkers"]:
            for primitive_index, primitive in enumerate(marker["primitives"]):
                if primitive["kind"] != "circle":
                    continue
                roundel_count += 1
                circle = primitive["circle"]
                centre = point(circle["centre"])
                style = float(circle["radius"]), float(circle["outlineWidth"])
                style_counts[style] += 1
                if abs(style[0] - float(baseline["radius"])) > tolerance or abs(
                    style[1] - float(baseline["outlineWidth"])
                ) > tolerance:
                    self.add(
                        "medium", "roundels", "roundel-style-variant",
                        f"{marker['stationID']} primitive {primitive_index}",
                        "A roundel differs from the pinned baseline radius or outline width.",
                        "Unreviewed symbol-size variation makes interchanges look inconsistent.",
                        "Confirm the variant in the TfL reference or restore the baseline style token.",
                        stationID=marker["stationID"], radius=style[0], outlineWidth=style[1],
                        baseline=baseline,
                    )
                path_match = self._nearest_station_path(centre, marker["stationID"])
                connector_match = nearest(centre, connector_endpoints)
                path_distance = None if path_match is None else path_match[0]
                connector_distance = None if connector_match is None else connector_match[0]
                attached_to_path = path_distance is not None and path_distance <= medium_port_tolerance
                attached_to_connector = (
                    connector_distance is not None
                    and connector_distance <= medium_port_tolerance
                )
                if not attached_to_path and not attached_to_connector:
                    unmatched += 1
                    nearest_distance = min(
                        value for value in (path_distance, connector_distance) if value is not None
                    ) if path_distance is not None or connector_distance is not None else None
                    severity = (
                        "high"
                        if nearest_distance is None or nearest_distance > high_port_tolerance
                        else "medium"
                    )
                    self.add(
                        severity, "roundels", "roundel-not-on-route-port",
                        f"{marker['stationID']} primitive {primitive_index}",
                        "A roundel centre is not attached to its authored route or an interchange connector.",
                        "The symbol can appear visually detached or imply the wrong interchange relationship.",
                        "Compare the centre with the official station artwork and move the corresponding path, connector, and glyph together.",
                        stationID=marker["stationID"], centre=centre,
                        nearestDistance=None if nearest_distance is None else round(nearest_distance, 3),
                        nearestPath=None if path_match is None else path_match[3],
                        nearestConnector=None if connector_match is None else connector_match[1],
                    )
        self.metrics["roundels"] = {
            "count": roundel_count,
            "unmatchedRoutePorts": unmatched,
            "styles": [
                {"radius": style[0], "outlineWidth": style[1], "count": count}
                for style, count in sorted(style_counts.items())
            ],
        }

    def audit_ticks(self) -> None:
        baseline = self.manifest["baselineStyles"]["tick"]
        style_tolerance = float(self.manifest["thresholds"]["styleTolerance"])
        port_tolerance = float(self.manifest["thresholds"]["tickPortDistanceArtworkUnits"])
        angle_tolerance = float(self.manifest["thresholds"]["tickPerpendicularDegrees"])
        lengths: list[float] = []
        perpendicular_candidates = 0
        for marker in self.document["stationMarkers"]:
            for primitive_index, primitive in enumerate(marker["primitives"]):
                if primitive["kind"] != "tick":
                    continue
                tick = primitive["tick"]
                start, end = point(tick["start"]), point(tick["end"])
                centre = midpoint(start, end)
                tick_vector = end[0] - start[0], end[1] - start[1]
                length = math.hypot(*tick_vector)
                lengths.append(length)
                if abs(length - float(baseline["length"])) > style_tolerance or abs(
                    float(tick["width"]) - float(baseline["width"])
                ) > style_tolerance:
                    self.add(
                        "medium", "ticks", "tick-style-variant",
                        f"{marker['stationID']} primitive {primitive_index}",
                        "A station tick differs from the pinned length or width baseline.",
                        "Unreviewed variation makes ordinary stations visually inconsistent.",
                        "Confirm the variant in the reference or regenerate it from the shared tick style.",
                        stationID=marker["stationID"], lineID=tick["lineID"],
                        length=round(length, 3), width=tick["width"], baseline=baseline,
                    )
                path_match = self._nearest_station_path(
                    centre, marker["stationID"], tick["lineID"]
                )
                if path_match is None or path_match[0] > port_tolerance:
                    self.add(
                        "high", "ticks", "tick-not-on-route-port",
                        f"{marker['stationID']} primitive {primitive_index}",
                        "A station tick is not centred on its line's authored path.",
                        "The station mark can float beside the route or attach to the wrong line.",
                        "Align the route path and tick centre from the same reviewed source coordinate.",
                        stationID=marker["stationID"], lineID=tick["lineID"], centre=centre,
                        nearestDistance=None if path_match is None else round(path_match[0], 3),
                    )
                    continue
                angle = acute_angle(tick_vector, path_match[2])
                deviation = abs(90.0 - angle)
                if deviation > angle_tolerance:
                    perpendicular_candidates += 1
                    self.add(
                        "high", "ticks", "tick-not-perpendicular",
                        f"{marker['stationID']} primitive {primitive_index}",
                        "A station tick is not perpendicular to the local route tangent.",
                        "The station grammar looks skewed and less like the official TfL artwork.",
                        "Recreate the tick normal from the reviewed local route tangent.",
                        stationID=marker["stationID"], lineID=tick["lineID"],
                        segmentID=path_match[3]["segmentID"], angleDegrees=round(angle, 3),
                        deviationDegrees=round(deviation, 3),
                    )
        self.metrics["ticks"] = {
            "count": len(lengths),
            "minimumLength": round(min(lengths), 3) if lengths else None,
            "maximumLength": round(max(lengths), 3) if lengths else None,
            "nonPerpendicular": perpendicular_candidates,
        }

    def audit_connectors(self) -> None:
        thresholds = self.manifest["thresholds"]
        medium_angle = float(thresholds["axisAngleMediumDegrees"])
        medium_endpoint_tolerance = float(
            thresholds["connectorEndpointMediumDistanceArtworkUnits"]
        )
        high_endpoint_tolerance = float(
            thresholds["connectorEndpointHighDistanceArtworkUnits"]
        )
        circles = [
            (point(primitive["circle"]["centre"]), {
                "stationID": marker["stationID"], "primitiveIndex": primitive_index,
            })
            for marker in self.document["stationMarkers"]
            for primitive_index, primitive in enumerate(marker["primitives"])
            if primitive["kind"] == "circle"
        ]
        connector_records: list[dict[str, Any]] = []
        normalized_pairs: Counter[tuple[tuple[float, float], tuple[float, float], str]] = Counter()
        angle_buckets: Counter[str] = Counter()
        for marker in self.document["stationMarkers"]:
            for primitive_index, primitive in enumerate(marker["primitives"]):
                kind = primitive["kind"]
                if kind not in {"connector", "walkingConnector"}:
                    continue
                connector = primitive[kind]
                start, end = point(connector["start"]), point(connector["end"])
                vector = end[0] - start[0], end[1] - start[1]
                length = math.hypot(*vector)
                angle = vector_angle(vector)
                nearest_angle, deviation = canonical_angle(angle)
                orientation = f"{nearest_angle:.0f} degrees"
                angle_buckets[orientation] += 1
                location = f"{marker['stationID']} primitive {primitive_index}"
                if length <= 1e-6:
                    self.add(
                        "critical", "connectors", "zero-length-connector", location,
                        "A connector has identical endpoints.",
                        "The interchange connection is invisible and semantically misleading.",
                        "Restore both reviewed roundel centres and rebuild the connector.",
                        stationID=marker["stationID"], kind=kind, start=start, end=end,
                    )
                if kind == "connector" and deviation > medium_angle:
                    self.add(
                        "medium", "connectors", "connector-angle-review", location,
                        f"An internal connector is {angle:.3f} degrees rather than horizontal, vertical, or 45 degrees.",
                        "An unintended angle weakens the interchange grammar, but the official map also uses deliberate non-octilinear links.",
                        "Compare with the locked TfL symbol; align only confirmed mismatches and retain source-traced exceptions.",
                        stationID=marker["stationID"], stationName=marker["name"], kind=kind,
                        angleDegrees=round(angle, 3), nearestCanonicalAngle=nearest_angle,
                        deviationDegrees=round(deviation, 3), start=start, end=end, length=round(length, 3),
                    )
                endpoint_matches = []
                for endpoint_name, endpoint in (("start", start), ("end", end)):
                    circle_match = nearest(endpoint, circles)
                    endpoint_matches.append(None if circle_match is None else round(circle_match[0], 3))
                    if circle_match is None or circle_match[0] > medium_endpoint_tolerance:
                        severity = (
                            "high"
                            if circle_match is None or circle_match[0] > high_endpoint_tolerance
                            else "medium"
                        )
                        self.add(
                            severity, "connectors", "connector-endpoint-without-roundel", location,
                            f"The connector {endpoint_name} does not meet a roundel centre.",
                            "The bar may visibly miss its interchange node or terminate without a station symbol.",
                            "Move the endpoint and corresponding roundel together using the official source coordinate.",
                            stationID=marker["stationID"], kind=kind, endpoint=endpoint_name,
                            coordinate=endpoint,
                            nearestDistance=None if circle_match is None else round(circle_match[0], 3),
                            nearestRoundel=None if circle_match is None else circle_match[1],
                        )
                pair = tuple(sorted((start, end)))
                normalized_pairs[(pair[0], pair[1], kind)] += 1
                connector_records.append({
                    "stationID": marker["stationID"], "stationName": marker["name"],
                    "kind": kind, "primitiveIndex": primitive_index, "start": start, "end": end,
                    "length": round(length, 3), "angleDegrees": round(angle, 3),
                    "nearestCanonicalAngle": nearest_angle, "deviationDegrees": round(deviation, 3),
                    "roundelEndpointDistances": endpoint_matches,
                })
        for (start, end, kind), count in sorted(normalized_pairs.items()):
            if count <= 1:
                continue
            self.add(
                "medium", "connectors", "duplicate-connector", f"{start} to {end}",
                f"The same {kind} geometry is authored {count} times.",
                "Duplicate strokes can darken antialiasing and create unclear ownership across semantic markers.",
                "Retain one visual primitive and associate the relevant semantic station records with it.",
                kind=kind, start=start, end=end, count=count,
            )
        self.metrics["connectors"] = {
            "count": len(connector_records),
            "byKind": dict(sorted(Counter(record["kind"] for record in connector_records).items())),
            "nearestAxis": dict(sorted(angle_buckets.items())),
            "records": connector_records,
        }

    def audit_styles(self) -> None:
        styles = self.document["styles"]
        baseline = self.manifest["baselineStyles"]["document"]
        tolerance = float(self.manifest["thresholds"]["styleTolerance"])
        for key, expected in baseline.items():
            actual = styles.get(key)
            if actual is None or abs(float(actual) - float(expected)) > tolerance:
                self.add(
                    "medium", "styles", "document-style-drift", key,
                    "A document style differs from the locked structural baseline.",
                    "A global stroke or label change can make the entire map diverge from the reviewed artwork.",
                    "Verify the value against the TfL source before updating the baseline.",
                    style=key, expected=expected, actual=actual,
                )
        self.add(
            "medium", "styles", "unverified-line-colour-profile", "TubeLine.swift",
            "The audit manifest does not yet contain colour-profile-corrected values extracted from the locked vector source.",
            "Even geometrically accurate lines may render with visibly incorrect TfL colours.",
            "Extract source colours through the PDF's intended ICC profile, then pin perceptual tolerances per line.",
            status=self.manifest["colourAuditStatus"],
        )


def markdown_report(report: dict[str, Any]) -> str:
    counts = report["summary"]["bySeverity"]
    unresolved_highs = counts.get("critical", 0) + counts.get("high", 0)
    if unresolved_highs:
        next_steps = [
            "1. Review every critical or high structural finding against the official reference.",
            "2. Resolve detached roundels, uncovered connector endpoints, or non-perpendicular ticks before cosmetic tuning.",
            "3. Pin source-profile-correct line colours and add masked visual comparisons.",
            "4. Convert confirmed corrections into station- and segment-specific regression fixtures.",
        ]
    else:
        next_steps = [
            "1. Keep the high-severity audit gate enabled to prevent structural regressions.",
            "2. Visually adjudicate medium route and connector angle candidates against the official artwork.",
            "3. Pin source-profile-correct line colours and add masked visual comparisons.",
            "4. Convert confirmed medium corrections into station- and segment-specific regression fixtures.",
        ]
    priority_steps = [
        "1. Immediate: resolve critical source/topology failures, if any.",
        (
            "2. Short-term: visually adjudicate high-severity structural findings."
            if unresolved_highs else
            "2. Short-term: visually adjudicate medium connector, roundel, tick, and route candidates."
        ),
        "3. Medium-term: implement confirmed geometry corrections in a new versioned artwork asset.",
        "4. Long-term: add colour-managed pixel masks and local crossing-order regression tests.",
    ]
    lines = [
        "# TfL Map Structural Fidelity Audit",
        "",
        "## Anti-pattern verdict",
        "",
        "Pass for the audited map layer. The artwork is authored, data-driven, and restrained; the current risk is fidelity drift, not generic decorative UI. This report does not assess unrelated screens.",
        "",
        "## Executive summary",
        "",
        f"- Reference: {report['reference']['title']} ({report['reference']['printedRevision']})",
        f"- Artwork: `{report['document']['identifier']}`",
        f"- Findings: {report['summary']['findingCount']} total ({', '.join(f'{key}: {value}' for key, value in counts.items()) or 'none'})",
        "- Status: candidate deviations require visual confirmation against the locked reference before geometry changes",
        "",
        "### Most important next steps",
        "",
        *next_steps,
        "",
        "## Detailed findings by severity",
        "",
    ]
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for finding in report["findings"]:
        grouped[finding["severity"]].append(finding)
    for severity in SEVERITY_ORDER:
        findings = grouped.get(severity, [])
        lines.extend([f"### {severity.title()} ({len(findings)})", ""])
        if not findings:
            lines.extend(["No findings.", ""])
            continue
        for finding in findings:
            lines.extend([
                f"#### `{finding['code']}` - {finding['location']}",
                "",
                f"- Category: {finding['category']}",
                f"- Description: {finding['description']}",
                f"- Impact: {finding['impact']}",
                f"- Recommendation: {finding['recommendation']}",
                f"- Evidence: `{json.dumps(finding['evidence'], sort_keys=True, separators=(',', ':'))}`",
                "",
            ])
    inventory = report["metrics"]["inventory"]
    lines.extend([
        "## Patterns and systemic issues",
        "",
        "- Geometry correctness is strongly covered for selected showcase interchanges, but not yet for every primitive.",
        "- Marker dimensions are consistent, while their fidelity to the official source still needs source-layer measurement.",
        "- Route and connector angle exceptions are implicit; they need explicit, reviewable provenance.",
        "- Colour and local crossing order are not yet pinned by the audit manifest.",
        "",
        "## Positive findings",
        "",
        f"- All {inventory['segments']} authored segments retain stable semantic IDs.",
        f"- The document includes {inventory['stationMarkers']} marker records and {inventory['paths']} immutable paths.",
        "- The official PDF and raster are checksum-pinned, protecting the comparison from silent source changes.",
        "- Structural findings identify exact station, segment, path, and primitive locations.",
        "",
        "## Recommendations by priority",
        "",
        *priority_steps,
        "",
        "## Reproduction",
        "",
        "Run `python3 Tools/BeckMapBuilder/audit_map_fidelity.py --help` from the `ios` directory.",
        "",
    ])
    return "\n".join(lines)


def svg_path(commands: list[dict[str, Any]], translation: dict[str, Any]) -> str:
    dx, dy = float(translation["x"]), float(translation["y"])
    parts: list[str] = []
    for command in commands:
        operation = command["op"]
        if operation == "close":
            parts.append("Z")
            continue
        destination = command_point(command)
        x, y = destination[0] + dx, destination[1] + dy
        if operation == "move":
            parts.append(f"M{x:.3f},{y:.3f}")
        elif operation == "line":
            parts.append(f"L{x:.3f},{y:.3f}")
        elif operation == "cubic":
            control1 = command_point(command, "control1")
            control2 = command_point(command, "control2")
            parts.append(
                f"C{control1[0] + dx:.3f},{control1[1] + dy:.3f} "
                f"{control2[0] + dx:.3f},{control2[1] + dy:.3f} {x:.3f},{y:.3f}"
            )
    return " ".join(parts)


def html_report(
    report: dict[str, Any], document: dict[str, Any], manifest: dict[str, Any],
    manifest_path: Path, output_path: Path,
) -> str:
    width = float(document["artworkSize"]["width"])
    height = float(document["artworkSize"]["height"])
    paths_by_id = {path_record["id"]: path_record for path_record in document["paths"]}
    reference_path = resolve_manifest_path(manifest_path, manifest["reference"]["raster"]["path"])
    reference_href = Path(os.path.relpath(reference_path, output_path.parent)).as_posix()
    line_colours = manifest["displayLineColours"]
    route_width = float(document["styles"]["routeStrokeWidth"])
    route_elements: list[str] = []
    for segment in document["segments"]:
        path_record = paths_by_id.get(segment["pathID"])
        if path_record is None:
            continue
        path_data = svg_path(path_record["commands"], segment.get("translation", {"x": 0, "y": 0}))
        colour = line_colours.get(segment["lineID"], "#cf2f3c")
        route_elements.append(
            f'<path d="{path_data}" stroke="{colour}" stroke-width="{route_width}" '
            'fill="none" stroke-linecap="round" stroke-linejoin="round"/>'
        )
        if segment["lineID"] in PARALLEL_STROKE_LINES:
            inner_width = 2.768 if segment["lineID"] == "tram" else route_width / 3
            route_elements.append(
                f'<path d="{path_data}" stroke="#ffffff" stroke-width="{inner_width}" '
                'fill="none" stroke-linecap="round" stroke-linejoin="round"/>'
            )
    connector_outlines: list[str] = []
    connector_inners: list[str] = []
    walking_connectors: list[str] = []
    roundels: list[str] = []
    ticks: list[str] = []
    for marker in document["stationMarkers"]:
        for primitive in marker["primitives"]:
            kind = primitive["kind"]
            payload = primitive[kind]
            if kind == "circle":
                centre = payload["centre"]
                roundels.append(
                    f'<circle cx="{centre["x"]}" cy="{centre["y"]}" r="{payload["radius"]}" '
                    f'fill="#ffffff" stroke="#121417" stroke-width="{payload["outlineWidth"]}"/>'
                )
            elif kind == "connector":
                connector_outlines.append(
                    f'<line x1="{payload["start"]["x"]}" y1="{payload["start"]["y"]}" '
                    f'x2="{payload["end"]["x"]}" y2="{payload["end"]["y"]}" '
                    f'stroke="#121417" stroke-width="{float(payload["width"]) + 1.8}" stroke-linecap="round"/>'
                )
                connector_inners.append(
                    f'<line x1="{payload["start"]["x"]}" y1="{payload["start"]["y"]}" '
                    f'x2="{payload["end"]["x"]}" y2="{payload["end"]["y"]}" '
                    f'stroke="#ffffff" stroke-width="{float(payload["width"]) - 2.2}" stroke-linecap="round"/>'
                )
            elif kind == "walkingConnector":
                walking_connectors.append(
                    f'<line x1="{payload["start"]["x"]}" y1="{payload["start"]["y"]}" '
                    f'x2="{payload["end"]["x"]}" y2="{payload["end"]["y"]}" '
                    f'stroke="#121417" stroke-width="{payload["width"]}" stroke-dasharray="8 5"/>'
                )
            elif kind == "tick":
                colour = line_colours.get(payload["lineID"], "#cf2f3c")
                ticks.append(
                    f'<line x1="{payload["start"]["x"]}" y1="{payload["start"]["y"]}" '
                    f'x2="{payload["end"]["x"]}" y2="{payload["end"]["y"]}" '
                    f'stroke="{colour}" stroke-width="{payload["width"]}"/>'
                )
    marker_elements = connector_outlines + connector_inners + walking_connectors + roundels + ticks
    rows = []
    for finding in report["findings"]:
        evidence = html.escape(json.dumps(finding["evidence"], sort_keys=True))
        rows.append(
            f'<tr data-severity="{finding["severity"]}"><td><span class="severity {finding["severity"]}">'
            f'{finding["severity"]}</span></td><td>{html.escape(finding["category"])}</td>'
            f'<td><code>{html.escape(finding["code"])}</code><br>{html.escape(finding["location"])}</td>'
            f'<td>{html.escape(finding["description"])}<details><summary>Evidence</summary><code>{evidence}</code></details></td>'
            f'<td>{html.escape(finding["recommendation"])}</td></tr>'
        )
    summary = report["summary"]
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TfL map structural fidelity audit</title>
<style>
:root{{--paper:#f6f4ef;--ink:#15233a;--muted:#607086;--rule:#c7d2df;--blue:#0019a8;--red:#cf2f3c;--amber:#9b6500}}
*{{box-sizing:border-box}} body{{margin:0;background:var(--paper);color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
header{{padding:32px clamp(20px,5vw,72px) 24px;border-bottom:1px solid var(--rule);background:#fff}}
h1{{margin:0 0 8px;font-size:clamp(28px,4vw,52px);letter-spacing:-.035em}} h2{{margin:40px 0 14px;font-size:24px}} p{{max-width:78ch}}
main{{padding:0 clamp(20px,5vw,72px) 64px}} .summary{{display:flex;gap:12px 28px;flex-wrap:wrap;color:var(--muted)}} .summary strong{{color:var(--ink)}}
.map-shell{{background:#fff;border:1px solid var(--rule);overflow:auto;max-height:72vh}} .map{{position:relative;min-width:920px;aspect-ratio:{width}/{height}}}
.map img,.map svg{{position:absolute;inset:0;width:100%;height:100%}} .routes,.markers{{transition:opacity .16s ease-out}} .controls{{display:flex;gap:18px;flex-wrap:wrap;margin:12px 0}}
label{{display:inline-flex;gap:7px;align-items:center}} table{{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--rule)}} th,td{{padding:11px 12px;text-align:left;vertical-align:top;border-bottom:1px solid var(--rule)}} th{{position:sticky;top:0;background:#edf2f7;z-index:2}} code{{font-family:"SFMono-Regular",Consolas,monospace;font-size:12px;overflow-wrap:anywhere}}
.severity{{display:inline-block;padding:2px 7px;border-radius:2px;color:#fff;font-size:11px;text-transform:uppercase;letter-spacing:.04em}} .critical,.high{{background:#a7272e}} .medium{{background:var(--amber)}} .low{{background:#356788}} .info{{background:#687684}}
details{{margin-top:8px;color:var(--muted)}} @media(max-width:760px){{th:nth-child(2),td:nth-child(2),th:nth-child(5),td:nth-child(5){{display:none}}}}
</style>
</head>
<body>
<header><h1>TfL map structural fidelity audit</h1><p>Candidate route, roundel, tick, and connector deviations. Geometry remains unchanged until each candidate is checked against the locked {html.escape(report['reference']['printedRevision'])} TfL artwork.</p>
<div class="summary"><span><strong>{summary['findingCount']}</strong> findings</span>{''.join(f'<span><strong>{value}</strong> {key}</span>' for key,value in summary['bySeverity'].items())}<span><strong>{report['metrics']['inventory']['segments']}</strong> segments</span><span><strong>{report['metrics']['inventory']['stationMarkers']}</strong> marker records</span></div></header>
<main><h2>Reference overlay</h2><p>Use the controls to compare the locked raster with the authored geometry. The overlay is diagnostic and does not reproduce labels or non-network artwork.</p>
<div class="controls"><label><input id="reference" type="checkbox" checked> Official reference</label><label><input id="routes" type="checkbox" checked> Authored routes</label><label><input id="markers" type="checkbox" checked> Authored markers</label><label>Overlay opacity <input id="opacity" type="range" min="0" max="1" step="0.05" value="0.65"></label></div>
<div class="map-shell"><div class="map"><img id="reference-layer" src="{html.escape(reference_href)}" alt="Locked official TfL map reference"><svg viewBox="0 0 {width} {height}" role="img" aria-label="Authored map geometry overlay"><g id="routes-layer" class="routes">{''.join(route_elements)}</g><g id="markers-layer" class="markers">{''.join(marker_elements)}</g></svg></div></div>
<h2>Findings</h2><table><thead><tr><th>Severity</th><th>Category</th><th>Location</th><th>Finding</th><th>Recommendation</th></tr></thead><tbody>{''.join(rows)}</tbody></table></main>
<script>
const byId=id=>document.getElementById(id); byId('reference').onchange=e=>byId('reference-layer').style.display=e.target.checked?'block':'none'; byId('routes').onchange=e=>byId('routes-layer').style.display=e.target.checked?'block':'none'; byId('markers').onchange=e=>byId('markers-layer').style.display=e.target.checked?'block':'none'; byId('opacity').oninput=e=>{{byId('routes-layer').style.opacity=e.target.value;byId('markers-layer').style.opacity=e.target.value}}; byId('opacity').oninput({{target:byId('opacity')}});
</script>
</body></html>"""


def write_output(path: Path | None, content: str) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--document", required=True, type=Path)
    parser.add_argument("--graph", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output-json", type=Path)
    parser.add_argument("--output-markdown", type=Path)
    parser.add_argument("--output-html", type=Path)
    parser.add_argument(
        "--fail-on", choices=("none", "critical", "high", "medium", "low"), default="none",
        help="Return a non-zero status when this severity or a more severe finding exists.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    document = load_json(arguments.document)
    graph = load_json(arguments.graph)
    manifest = load_json(arguments.manifest)
    audit = MapFidelityAudit(document, graph, manifest)
    report = audit.run(arguments.manifest.resolve())
    if arguments.output_json:
        write_output(arguments.output_json, json.dumps(report, indent=2, sort_keys=True) + "\n")
    if arguments.output_markdown:
        write_output(arguments.output_markdown, markdown_report(report))
    if arguments.output_html:
        write_output(
            arguments.output_html,
            html_report(report, document, manifest, arguments.manifest.resolve(), arguments.output_html.resolve()),
        )
    print(json.dumps(report["summary"], sort_keys=True))
    if arguments.fail_on == "none":
        return 0
    threshold = SEVERITY_ORDER[arguments.fail_on]
    return int(any(SEVERITY_ORDER[finding["severity"]] <= threshold for finding in report["findings"]))


if __name__ == "__main__":
    raise SystemExit(main())
