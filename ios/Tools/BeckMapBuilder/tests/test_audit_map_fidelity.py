import copy
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "audit_map_fidelity.py"
IOS_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(SCRIPT_PATH.parent))
import audit_map_fidelity as audit_module
import normalize_official_geometry as official_geometry_module
import normalize_station_markers as normalize_module


def marker(station_id, name, primitives, anchor=(10, 10), line_ids=("central",)):
    return {
        "stationID": station_id,
        "name": name,
        "lineIDs": list(line_ids),
        "anchor": {"x": anchor[0], "y": anchor[1]},
        "hitRadius": 24,
        "primitives": primitives,
    }


def circle(x, y):
    return {
        "kind": "circle",
        "circle": {"centre": {"x": x, "y": y}, "radius": 8.5, "outlineWidth": 3.5},
    }


def connector(start, end):
    return {
        "kind": "connector",
        "connector": {
            "start": {"x": start[0], "y": start[1]},
            "end": {"x": end[0], "y": end[1]},
            "width": 7.5,
        },
    }


def tick(start, end):
    return {
        "kind": "tick",
        "tick": {
            "lineID": "central",
            "start": {"x": start[0], "y": start[1]},
            "end": {"x": end[0], "y": end[1]},
            "width": 3.2,
        },
    }


class MapFidelityAuditTests(unittest.TestCase):
    def manifest(self):
        return {
            "reference": {
                "title": "Fixture",
                "printedRevision": "test",
                "pdf": {"path": "missing.pdf", "sha256": "missing"},
                "raster": {"path": "missing.png", "sha256": "missing", "pixelSize": [50, 50]},
                "coordinateSystem": {"artworkUnitsPerReferencePixel": 2},
            },
            "supplementalSegmentIDs": [],
            "baselineStyles": {
                "document": {
                    "routeStrokeWidth": 8.3,
                    "affectedOuterStrokeWidth": 19,
                    "affectedKnockoutStrokeWidth": 15,
                    "affectedRouteStrokeWidth": 10,
                    "primaryLabelFontSize": 18,
                    "secondaryLabelFontSize": 16,
                    "labelPadding": 2,
                },
                "roundel": {"radius": 8.5, "outlineWidth": 3.5},
                "tick": {"length": 14, "width": 3.2},
            },
            "thresholds": {
                "axisAngleMediumDegrees": 0.25,
                "axisAngleHighDegrees": 1,
                "straightSegmentMinimumLength": 12,
                "connectorEndpointMediumDistanceArtworkUnits": 0.01,
                "connectorEndpointHighDistanceArtworkUnits": 8.5,
                "roundelPortMediumDistanceArtworkUnits": 1,
                "roundelPortHighDistanceArtworkUnits": 8.5,
                "tickPortDistanceArtworkUnits": 1,
                "tickPerpendicularDegrees": 0.5,
                "styleTolerance": 0.01,
            },
            "colourAuditStatus": "pending",
        }

    def document(self, markers, path_end=(20, 10)):
        return {
            "identifier": "fixture",
            "schemaVersion": {"major": 1, "minor": 2},
            "artworkSize": {"width": 100, "height": 100},
            "styles": self.manifest()["baselineStyles"]["document"],
            "paths": [{
                "id": "path",
                "commands": [
                    {"op": "move", "to": {"x": 10, "y": 10}},
                    {"op": "line", "to": {"x": path_end[0], "y": path_end[1]}},
                ],
            }],
            "segments": [{
                "id": "central:a:b",
                "lineID": "central",
                "fromStationID": "a",
                "toStationID": "b",
                "fromPort": {"x": 10, "y": 10},
                "toPort": {"x": path_end[0], "y": path_end[1]},
                "pathID": "path",
                "pathDirection": "forward",
                "translation": {"x": 0, "y": 0},
            }],
            "stationMarkers": markers,
            "labels": [],
            "routes": [],
            "supportedLineIDs": ["central"],
        }

    def graph(self):
        return {
            "stations": [{"id": "a"}, {"id": "b"}],
            "segments": [{"id": "central:a:b"}],
        }

    def test_canonical_connector_is_not_flagged(self):
        markers = [
            marker("a", "A", [circle(10, 10), connector((10, 10), (20, 20)), circle(20, 20)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_connectors()
        self.assertNotIn("connector-angle-review", {finding.code for finding in audit.findings})

    def test_noncanonical_connector_is_high_with_station_id(self):
        markers = [
            marker("a", "A", [circle(10, 10), connector((10, 10), (20, 15)), circle(20, 15)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_connectors()
        finding = next(finding for finding in audit.findings if finding.code == "connector-angle-review")
        self.assertEqual(finding.severity, "high")
        self.assertEqual(finding.evidence["stationID"], "a")

    def test_perpendicular_tick_passes_and_skewed_tick_fails(self):
        passing = [
            marker("a", "A", [tick((10, 3), (10, 17))]),
            marker("b", "B", [tick((20, 3), (20, 17))], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(passing), self.graph(), self.manifest())
        audit.audit_ticks()
        self.assertNotIn("tick-not-perpendicular", {finding.code for finding in audit.findings})

        failing = [
            marker("a", "A", [tick((3, 10), (17, 10))]),
            marker("b", "B", [tick((20, 3), (20, 17))], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(failing), self.graph(), self.manifest())
        audit.audit_ticks()
        self.assertIn("tick-not-perpendicular", {finding.code for finding in audit.findings})

    def test_route_angle_candidate_is_grouped_by_line(self):
        markers = [
            marker("a", "A", [circle(10, 10)]),
            marker("b", "B", [circle(30, 20)], anchor=(30, 20)),
        ]
        audit = audit_module.MapFidelityAudit(
            self.document(markers, path_end=(30, 20)), self.graph(), self.manifest()
        )
        audit.audit_routes()
        finding = next(finding for finding in audit.findings if finding.code == "non-canonical-straight-runs")
        self.assertEqual(finding.location, "central")
        self.assertEqual(finding.severity, "medium")
        self.assertEqual(finding.evidence["count"], 1)

    def test_roundel_on_connector_endpoint_is_attached(self):
        markers = [
            marker("a", "A", [connector((10, 10), (16, 18)), circle(16, 18)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_roundels()
        self.assertNotIn("roundel-not-on-route-port", {finding.code for finding in audit.findings})

    def test_tick_on_middle_of_adjacent_path_fails_station_endpoint_check(self):
        markers = [
            marker("a", "A", [tick((15, 3), (15, 17))], anchor=(15, 10)),
            marker("b", "B", [tick((20, 3), (20, 17))], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_ticks()
        codes = {finding.code for finding in audit.findings}
        self.assertIn("tick-not-on-route-port", codes)

    def test_small_shared_corridor_roundel_offset_is_medium(self):
        markers = [
            marker("a", "A", [circle(10, 14)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), self.manifest())
        audit.audit_roundels()
        finding = next(finding for finding in audit.findings if finding.code == "roundel-not-on-route-port")
        self.assertEqual(finding.severity, "medium")

    def test_markdown_output_is_deterministic(self):
        markers = [
            marker("a", "A", [circle(10, 10)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        manifest = self.manifest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "missing.pdf").write_bytes(b"fixture")
            # Minimal valid PNG header with a 50 x 50 IHDR width/height.
            (root / "missing.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + struct.pack(">II", 50, 50))
            manifest["reference"]["pdf"]["sha256"] = audit_module.sha256(root / "missing.pdf")
            manifest["reference"]["raster"]["sha256"] = audit_module.sha256(root / "missing.png")
            audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), manifest)
            report = audit.run(root / "manifest.json")
            self.assertEqual(audit_module.markdown_report(report), audit_module.markdown_report(report))

    def test_reference_hash_drift_is_critical(self):
        markers = [
            marker("a", "A", [circle(10, 10)]),
            marker("b", "B", [circle(20, 10)], anchor=(20, 10)),
        ]
        manifest = self.manifest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "missing.pdf").write_bytes(b"unexpected")
            (root / "missing.png").write_bytes(
                b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + struct.pack(">II", 50, 50)
            )
            audit = audit_module.MapFidelityAudit(self.document(markers), self.graph(), manifest)
            report = audit.run(root / "manifest.json")
            codes = {finding["code"] for finding in report["findings"]}
            self.assertIn("reference-hash-mismatch", codes)

    def test_connector_endpoint_promotes_matching_tick_to_roundel(self):
        markers = [
            marker("a", "A", [tick((10, 3), (10, 17))]),
            marker(
                "b", "B",
                [connector((10, 10), (20, 10)), circle(20, 10)],
                anchor=(20, 10),
            ),
        ]
        document = self.document(markers)
        self.assertEqual(normalize_module._promote_connector_endpoint_ticks(document), 1)
        kinds = [primitive["kind"] for primitive in document["stationMarkers"][0]["primitives"]]
        self.assertEqual(kinds, ["circle"])

    def test_skewed_tick_is_regenerated_from_local_path_tangent(self):
        markers = [
            marker("a", "A", [tick((3, 10), (17, 10))]),
            marker("b", "B", [tick((20, 3), (20, 17))], anchor=(20, 10)),
        ]
        document = self.document(markers)
        self.assertEqual(normalize_module._normalize_tick_angles(document), 1)
        corrected = document["stationMarkers"][0]["primitives"][0]["tick"]
        self.assertEqual(corrected["start"]["x"], 10)
        self.assertEqual(corrected["end"]["x"], 10)
        self.assertEqual(abs(corrected["end"]["y"] - corrected["start"]["y"]), 14)

    def test_bundled_map_has_no_critical_fidelity_findings(self):
        document = audit_module.load_json(
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        )
        graph = audit_module.load_json(IOS_ROOT / "TubeTrackUK/Resources/TubeGraph.json")
        manifest_path = IOS_ROOT / "design_brief/beck_map/tfl-standard-map-april-2026.json"
        manifest = audit_module.load_json(manifest_path)
        report = audit_module.MapFidelityAudit(document, graph, manifest).run(manifest_path)
        self.assertNotIn("critical", report["summary"]["bySeverity"])
        self.assertFalse(any(
            finding["evidence"].get("stationID") == "940GZZLUHSC"
            for finding in report["findings"]
        ))

    def test_bundled_western_geometry_matches_source_verified_relationships(self):
        document = audit_module.load_json(
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        )
        markers = {
            marker["stationID"]: marker for marker in document["stationMarkers"]
        }

        def connector(station_id):
            return next(
                primitive for primitive in markers[station_id]["primitives"]
                if primitive["kind"] in {"connector", "walkingConnector"}
            )

        for station_id in ("910GKENOLYM", "910GWBRMPTN"):
            primitive = connector(station_id)
            payload = primitive[primitive["kind"]]
            self.assertAlmostEqual(
                payload["start"]["y"], payload["end"]["y"], places=3
            )

        hammersmith = markers["940GZZLUHSC"]
        self.assertEqual(
            [primitive["kind"] for primitive in hammersmith["primitives"]],
            ["circle"],
        )
        self.assertEqual(
            set(hammersmith["lineIDs"]), {"circle", "hammersmith-city"}
        )

        shepherds_bush = connector("910GSHPDSB")
        self.assertEqual(shepherds_bush["kind"], "walkingConnector")
        payload = shepherds_bush["walkingConnector"]
        dx = payload["end"]["x"] - payload["start"]["x"]
        dy = payload["end"]["y"] - payload["start"]["y"]
        self.assertAlmostEqual(abs(dx), abs(dy), places=3)

        def line_port(station_id, line_id):
            ports = []
            for segment in document["segments"]:
                if segment["lineID"] != line_id:
                    continue
                if segment["fromStationID"] == station_id:
                    ports.append(segment["fromPort"])
                if segment["toStationID"] == station_id:
                    ports.append(segment["toPort"])
            self.assertTrue(ports)
            return ports[0]

        for station_id in ("940GZZLUSBM", "940GZZLUGHK"):
            marker_record = markers[station_id]
            tick_centres = {
                primitive["tick"]["lineID"]: (
                    (primitive["tick"]["start"]["x"] + primitive["tick"]["end"]["x"]) / 2,
                    (primitive["tick"]["start"]["y"] + primitive["tick"]["end"]["y"]) / 2,
                )
                for primitive in marker_record["primitives"]
                if primitive["kind"] == "tick"
            }
            for line_id in ("circle", "hammersmith-city"):
                port = line_port(station_id, line_id)
                self.assertAlmostEqual(tick_centres[line_id][0], port["x"], places=3)
                self.assertAlmostEqual(tick_centres[line_id][1], port["y"], places=3)

    def test_bundled_official_geometry_normalization_is_idempotent(self):
        document = json.loads((
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        ).read_text())
        original = copy.deepcopy(document)
        self.assertEqual(official_geometry_module.apply(document), 0)
        self.assertEqual(document, original)

    def test_bundled_northwest_interchanges_follow_official_diagonal_grammar(self):
        document = json.loads((
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        ).read_text())
        markers = {
            marker["stationID"]: marker for marker in document["stationMarkers"]
        }

        for station_id in (
            "940GZZLUWYP",
            "940GZZLUWIG",
            "910GWHMDSTD",
            "940GZZLUFYR",
            "910GFNCHLYR",
        ):
            primitive = next(
                primitive for primitive in markers[station_id]["primitives"]
                if primitive["kind"] in {"connector", "walkingConnector"}
            )
            payload = primitive[primitive["kind"]]
            dx = payload["end"]["x"] - payload["start"]["x"]
            dy = payload["end"]["y"] - payload["start"]["y"]
            self.assertAlmostEqual(abs(dx), abs(dy), places=3)

        for station_id in ("910GWHMDSTD", "910GFNCHLYR"):
            walking_link = next(
                primitive for primitive in markers[station_id]["primitives"]
                if primitive["kind"] in {"connector", "walkingConnector"}
            )
            self.assertEqual(walking_link["kind"], "walkingConnector")

        walking_pairs = (
            ("940GZZLUWHP", "910GWHMDSTD"),
            ("940GZZLUFYR", "910GFNCHLYR"),
        )
        for underground_id, mildmay_id in walking_pairs:
            primitive = next(
                primitive for primitive in markers[mildmay_id]["primitives"]
                if primitive["kind"] == "walkingConnector"
            )
            payload = primitive["walkingConnector"]
            self.assertEqual(payload["start"], markers[underground_id]["anchor"])
            self.assertEqual(payload["end"], markers[mildmay_id]["anchor"])
        self.assertAlmostEqual(
            markers["910GWHMDSTD"]["anchor"]["y"],
            markers["910GFNCHLYR"]["anchor"]["y"],
            places=3,
        )

        protected_segments = {
            "jubilee:940GZZLUKBN:940GZZLUWHP",
            "jubilee:940GZZLUFYR:940GZZLUWHP",
            "jubilee:940GZZLUFYR:940GZZLUSWC",
            "jubilee:940GZZLUSJW:940GZZLUSWC",
        }
        for segment in document["segments"]:
            if segment["id"] not in protected_segments:
                continue
            dx = segment["toPort"]["x"] - segment["fromPort"]["x"]
            dy = segment["toPort"]["y"] - segment["fromPort"]["y"]
            self.assertLess(abs(abs(dx) - abs(dy)), 0.2)

    def test_bundled_marker_normalization_is_idempotent(self):
        document = json.loads((
            IOS_ROOT / "TubeTrackUK/Resources/BeckMap/v1/full-underground.json"
        ).read_text())
        graph = json.loads((IOS_ROOT / "TubeTrackUK/Resources/TubeGraph.json").read_text())
        original = copy.deepcopy(document)
        self.assertEqual(normalize_module.normalize(document, graph), 0)
        self.assertEqual(document, original)


if __name__ == "__main__":
    unittest.main()
